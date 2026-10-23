import Foundation
import ProximusCrypto

public enum WalletNetwork: String, Codable, CaseIterable, Identifiable, Sendable {
    case solana, evm, bitcoin, monero
    public var id: String { rawValue }
    public var label: String { switch self { case .solana: return "Solana"; case .evm: return "Ethereum / EVM"; case .bitcoin: return "Bitcoin"; case .monero: return "Monero" } }
    var code: UInt32 { switch self { case .solana: return 1; case .evm: return 2; case .bitcoin: return 3; case .monero: return 4 } }
    public var recoveryLabel: String { self == .monero ? "Private spend key (64 hex characters)" : "BIP-39 recovery phrase" }
    public var privateKeyLabel: String { switch self { case .solana: return "Private keypair (Base58, 64 bytes)"; case .evm: return "Private key (hex)"; case .bitcoin: return "Private key (compressed WIF)"; case .monero: return "Private spend key (hex)" } }
}

/// Only public data enters vault snapshots, pairing bundles, and relay sync.
public struct WalletMetadata: Codable, Equatable, Sendable {
    public var id: UUID
    public var ownerDeviceID: UUID
    public var network: WalletNetwork
    public var address: String
    public var publicKey: String
    public var derivationPath: String
    public init(id: UUID = UUID(), ownerDeviceID: UUID, network: WalletNetwork, address: String, publicKey: String, derivationPath: String) {
        self.id = id; self.ownerDeviceID = ownerDeviceID; self.network = network; self.address = address; self.publicKey = publicKey; self.derivationPath = derivationPath
    }
    func validate() throws {
        guard !address.isEmpty, address.utf8.count <= 128, !publicKey.isEmpty, publicKey.utf8.count <= 256, !derivationPath.isEmpty, derivationPath.utf8.count <= 128 else { throw ProximusError.invalid("Invalid wallet address record.") }
    }
    var context: Data { get throws { var data = Data("proximus/v1/local-wallet/".utf8); data.append(try Encoding.encode(self)); return data } }
}

/// Secret material is never a field of VaultItem or VaultContents.
public struct WalletMaterial: Codable, Sendable {
    public var address: String
    public var publicKey: String
    public var derivationPath: String
    public var recovery: String
    public var privateKey: String
    public var secondaryPrivateKey: String
    public func metadata(network: WalletNetwork, deviceID: UUID) -> WalletMetadata {
        WalletMetadata(ownerDeviceID: deviceID, network: network, address: address, publicKey: publicKey, derivationPath: derivationPath)
    }
    func matches(_ metadata: WalletMetadata) -> Bool {
        address == metadata.address && publicKey == metadata.publicKey && derivationPath == metadata.derivationPath
    }
}

public enum WalletCrypto {
    public static func mnemonic() throws -> String {
        var buffer = Data(count: 1024), length = 0
        defer { buffer.resetBytes(in: 0..<buffer.count) }
        let result = buffer.withUnsafeMutableBytes { px_mnemonic($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &length) }
        guard result == 0, (1...buffer.count).contains(length), let words = String(data: buffer.prefix(length), encoding: .utf8) else { throw ProximusError.unavailable("Could not generate a recovery phrase.") }
        return words
    }
    public static func derive(network: WalletNetwork, recovery: String = "") throws -> WalletMaterial {
        let normalized = recovery.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard normalized.utf8.count <= 1024 else { throw ProximusError.invalid("Recovery input is too long.") }
        var input = Data(normalized.utf8), buffer = Data(count: 8192), length = 0
        defer { input.resetBytes(in: 0..<input.count); buffer.resetBytes(in: 0..<buffer.count) }
        let result = input.withUnsafeBytes { i in buffer.withUnsafeMutableBytes { o in
            px_wallet(network.code, i.bindMemory(to: UInt8.self).baseAddress, i.count, o.bindMemory(to: UInt8.self).baseAddress, o.count, &length)
        } }
        guard result == 0, (1...buffer.count).contains(length) else { throw ProximusError.invalid(network == .monero ? "Enter a valid, nonzero Monero private spend key in hexadecimal." : "Enter a valid English BIP-39 phrase, including its checksum. Extra BIP-39 passphrases are not supported.") }
        return try Encoding.decode(WalletMaterial.self, from: buffer.prefix(length))
    }
}

/// App-private files, excluded from backup. Secure Enclave key references cannot
/// be used on another device. No vault-key fallback exists.
public struct LocalWalletStore {
    private let directory: URL
    private let deviceID: UUID
    private let protect: (Data, Data) throws -> Data
    private let unprotect: (Data, Data) throws -> Data
    private struct Stored: Codable { var format = 1; var metadata: WalletMetadata; var envelope: Data }
    public init(deviceID: UUID, authenticationReason: String = "Show this wallet’s recovery phrase and private keys") throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try self.init(directory: root.appendingPathComponent((Bundle.main.bundleIdentifier ?? "org.proximus.passwords") + ".device-wallets", isDirectory: true), deviceID: deviceID, protect: WalletProtection.seal, unprotect: { try WalletProtection.open($0, context: $1, reason: authenticationReason) })
    }
    init(directory: URL, deviceID: UUID, protect: @escaping (Data, Data) throws -> Data, unprotect: @escaping (Data, Data) throws -> Data) throws {
        self.directory = directory; self.deviceID = deviceID; self.protect = protect; self.unprotect = unprotect
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = directory, values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
    }
    private func file(_ metadata: WalletMetadata) -> URL { directory.appendingPathComponent(metadata.id.uuidString + ".wallet") }
    public func contains(_ metadata: WalletMetadata) -> Bool { metadata.ownerDeviceID == deviceID && FileManager.default.fileExists(atPath: file(metadata).path) }
    public func save(_ material: WalletMaterial, metadata: WalletMetadata) throws {
        try metadata.validate()
        guard metadata.ownerDeviceID == deviceID, material.matches(metadata), !FileManager.default.fileExists(atPath: file(metadata).path) else { throw ProximusError.invalid("Wallet ownership or address does not match, or the wallet already exists.") }
        var plain = try Encoding.encode(material)
        defer { plain.resetBytes(in: 0..<plain.count) }
        let stored = Stored(metadata: metadata, envelope: try protect(plain, metadata.context))
        let bytes = try Encoding.encode(stored)
        var url = file(metadata)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
    }
    private func stored(_ metadata: WalletMetadata) throws -> Stored {
        guard metadata.ownerDeviceID == deviceID else { throw ProximusError.unavailable("Open this wallet on the device that holds its keys.") }
        let url = file(metadata)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32768 else { throw ProximusError.authentication }
        let stored = try Encoding.decode(Stored.self, from: BoundedFile.read(url, limit: 32768))
        guard stored.format == 1, stored.metadata == metadata else { throw ProximusError.authentication }
        return stored
    }
    /// Public synced metadata alone never grants access to a local signing path.
    func verifyRecord(_ metadata: WalletMetadata) throws { _ = try stored(metadata) }
    public func reveal(_ metadata: WalletMetadata) throws -> WalletMaterial {
        let stored = try stored(metadata)
        var plain = try unprotect(stored.envelope, metadata.context)
        defer { plain.resetBytes(in: 0..<plain.count) }
        let material = try Encoding.decode(WalletMaterial.self, from: plain)
        guard material.matches(metadata) else { throw ProximusError.authentication }
        return material
    }
    public func remove(_ metadata: WalletMetadata) throws {
        guard metadata.ownerDeviceID == deviceID else { return }
        let url = file(metadata)
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32768 else { throw ProximusError.authentication }
            let stored = try Encoding.decode(Stored.self, from: BoundedFile.read(url, limit: 32768))
            guard stored.format == 1, stored.metadata == metadata else { throw ProximusError.authentication }
            try FileManager.default.removeItem(at: url)
        }
    }
}
