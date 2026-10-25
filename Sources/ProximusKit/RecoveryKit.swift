import Foundation
import ProximusCrypto

public struct RecoverySetup {
    public var password: String
    public var folder: Data
    public init(password: String, folder: Data) { self.password = password; self.folder = folder }
}

public struct WalletRecoveryRecord: Codable {
    public var metadata: WalletMetadata
    public var material: WalletMaterial
    public init(metadata: WalletMetadata, material: WalletMaterial) { self.metadata = metadata; self.material = material }
}
public struct RecoveryPayload: Codable {
    public var createdAt: Date
    public var contents: VaultContents
    public var wallets: [WalletRecoveryRecord]
    public init(contents: VaultContents, wallets: [WalletRecoveryRecord], createdAt: Date = Date()) { self.contents = contents; self.wallets = wallets; self.createdAt = createdAt }
    public func validate() throws {
        try contents.validate()
        guard wallets.count <= 10000, Set(wallets.map { $0.metadata.id }).count == wallets.count else { throw ProximusError.authentication }
        for record in wallets {
            try record.metadata.validate()
            guard record.material.matches(record.metadata), contents.items.contains(where: { $0.wallet == record.metadata }) else { throw ProximusError.authentication }
            let derived = try WalletCrypto.derive(network: record.metadata.network, recovery: record.material.recovery)
            guard derived.matches(record.metadata), derived.privateKey == record.material.privateKey, derived.secondaryPrivateKey == record.material.secondaryPrivateKey else { throw ProximusError.authentication }
        }
    }
}
public struct RecoveryKit: Codable {
    public var format = 1
    public var kdf = "argon2id-v19-m65536-t3-p1"
    public var salt: Data
    public var ciphertext: Data
    private var context: Data { Data("proximus/v1/recovery-kit/\(format)/\(kdf)/\(salt.base64URLEncoded)".utf8) }
    public static func key(password: String, salt: Data) throws -> Data {
        var input = Data(password.utf8), output = Data(count: 32)
        defer { input.resetBytes(in: 0..<input.count) }
        guard (16...1024).contains(input.count), salt.count == 16 else { throw ProximusError.invalid("Use a separate backup password of at least 16 characters.") }
        let status = input.withUnsafeBytes { p in salt.withUnsafeBytes { s in output.withUnsafeMutableBytes { o in
            px_backup_key(p.bindMemory(to: UInt8.self).baseAddress, p.count, s.bindMemory(to: UInt8.self).baseAddress, o.bindMemory(to: UInt8.self).baseAddress)
        } } }
        guard status == 0 else { throw ProximusError.authentication }
        return output
    }
    public static func seal(_ payload: RecoveryPayload, key: Data, salt: Data) throws -> Data {
        guard salt.count == 16, key.count == 32 else { throw ProximusError.authentication }
        try payload.validate()
        var plain = try Encoding.encode(payload)
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard plain.count <= VaultCrypto.maximumPayload else { throw ProximusError.invalid("The recovery kit exceeds the 8 MiB plaintext limit.") }
        var kit = RecoveryKit(salt: salt, ciphertext: Data())
        kit.ciphertext = try VaultCrypto.seal(plain, key: key, context: kit.context)
        return try Encoding.encode(kit)
    }
    public static func open(_ data: Data, password: String) throws -> RecoveryPayload {
        let kit = try validated(data)
        var key = try key(password: password, salt: kit.salt)
        defer { key.resetBytes(in: 0..<key.count) }
        return try open(data, key: key)
    }
    static func open(_ data: Data, key: Data) throws -> RecoveryPayload {
        let kit = try validated(data)
        var plain = try VaultCrypto.open(kit.ciphertext, key: key, context: kit.context)
        defer { plain.resetBytes(in: 0..<plain.count) }
        let payload = try Encoding.decode(RecoveryPayload.self, from: plain)
        try payload.validate(); return payload
    }
    private static func validated(_ data: Data) throws -> RecoveryKit {
        let kit = try Encoding.decode(RecoveryKit.self, from: data)
        guard kit.format == 1, kit.kdf == "argon2id-v19-m65536-t3-p1", kit.salt.count == 16, kit.ciphertext.count <= VaultCrypto.maximumPayload + 28 else { throw ProximusError.authentication }
        return kit
    }
}

public enum RecoveryFolder {
    public static func bookmark(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ProximusError.invalid("Choose a folder in iCloud Drive or on this device.") }
        #if os(macOS)
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
    static func write(_ data: Data, bookmark: Data, name: String) throws {
        var stale = false
        #if os(macOS)
        let folder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw ProximusError.unavailable("Choose your backup folder again to renew access.") }
        let scoped = folder.startAccessingSecurityScopedResource(); defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let url = folder.appendingPathComponent(name)
        var coordinationError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do { try data.write(to: destination, options: [.atomic, .completeFileProtection]) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }
}

/// Backup keys stay device-bound at rest. Plaintext and the active key exist only
/// during an authorized unlocked session. Only encrypted kits reach Files/iCloud.
public actor RecoveryBackupSession {
    private struct Configuration: Codable { var salt: Data; var protectedKey: Data; var folder: Data; var name: String }
    private var key: SecretBytes?
    private let configuration: Configuration
    private var encryptedKit: Data
    private let vaultID: UUID
    private static func account(_ id: UUID) -> String { "recovery-backup/" + id.uuidString }
    private static func context(_ id: UUID) -> Data { Data("proximus/v1/recovery-backup-key/\(id)".utf8) }
    private static func cache(_ id: UUID) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent((Bundle.main.bundleIdentifier ?? "org.proximus.passwords") + ".recovery-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = root, values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
        return root.appendingPathComponent(id.uuidString + ".proximusrecovery")
    }
    public static func isConfigured(_ vault: UUID) -> Bool { DeviceKeychain.contains(account(vault)) }
    private init(vaultID: UUID, configuration: Configuration, key: Data, encryptedKit: Data) throws {
        self.vaultID = vaultID; self.configuration = configuration; self.key = try SecretBytes(key); self.encryptedKit = encryptedKit
    }
    public static func configure(vaultID: UUID, payload: RecoveryPayload, password: String, folder: Data) throws -> RecoveryBackupSession {
        let salt = try VaultCrypto.random(16)
        var key = try RecoveryKit.key(password: password, salt: salt)
        defer { key.resetBytes(in: 0..<key.count) }
        let encrypted = try RecoveryKit.seal(payload, key: key, salt: salt)
        let config = Configuration(salt: salt, protectedKey: try WalletProtection.seal(key, context: context(vaultID)), folder: folder, name: "Proximus-\(vaultID.uuidString.lowercased()).proximusrecovery")
        try RecoveryFolder.write(encrypted, bookmark: folder, name: config.name)
        try encrypted.write(to: cache(vaultID), options: [.atomic, .completeFileProtection])
        try DeviceKeychain.write(Encoding.encode(config), account: account(vaultID))
        return try RecoveryBackupSession(vaultID: vaultID, configuration: config, key: key, encryptedKit: encrypted)
    }
    public static func resume(vaultID: UUID) throws -> RecoveryBackupSession? {
        guard let stored = try DeviceKeychain.read(account(vaultID)) else { return nil }
        let config = try Encoding.decode(Configuration.self, from: stored)
        var key = try WalletProtection.open(config.protectedKey, context: context(vaultID), reason: "Resume encrypted recovery backups, including wallet recovery phrases")
        defer { key.resetBytes(in: 0..<key.count) }
        let data = try BoundedFile.read(cache(vaultID), limit: VaultCrypto.maximumPayload * 2)
        _ = try RecoveryKit.open(data, key: key)
        return try RecoveryBackupSession(vaultID: vaultID, configuration: config, key: key, encryptedKit: data)
    }
    public func update(contents: VaultContents, newWallet: WalletRecoveryRecord? = nil) throws {
        guard let key else { throw ProximusError.locked }
        let previous = try key.withData { try RecoveryKit.open(encryptedKit, key: $0) }
        var records = previous.wallets.filter { record in contents.items.contains { $0.wallet == record.metadata } }
        if let newWallet { records.removeAll { $0.metadata.id == newWallet.metadata.id }; records.append(newWallet) }
        let payload = RecoveryPayload(contents: contents, wallets: records)
        let data = try key.withData { try RecoveryKit.seal(payload, key: $0, salt: configuration.salt) }
        // Retain the newest encrypted state even if the chosen cloud folder is offline.
        try data.write(to: Self.cache(vaultID), options: [.atomic, .completeFileProtection]); encryptedKit = data
        try RecoveryFolder.write(data, bookmark: configuration.folder, name: configuration.name)
    }
    public func missingWallets(contents: VaultContents, deviceID: UUID) throws -> [WalletMetadata] {
        guard let key else { throw ProximusError.locked }
        let payload = try key.withData { try RecoveryKit.open(encryptedKit, key: $0) }
        let present = Set(payload.wallets.map { $0.metadata.id })
        return Dictionary(grouping: contents.items.compactMap(\.wallet).filter { $0.ownerDeviceID == deviceID && !present.contains($0.id) }, by: \.id).compactMap { $0.value.first }
    }
    public func lock() { key?.erase(); key = nil }
    public static func disable(vaultID: UUID) throws { try DeviceKeychain.delete(account(vaultID)) }
}

public enum BoundedFile {
    public static func read(_ url: URL, limit: Int) throws -> Data {
        guard limit > 0, limit <= 32 * 1024 * 1024 else { throw ProximusError.invalid("Invalid file limit.") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ProximusError.invalid("This file exceeds the size limit.") }
        return data
    }
}
