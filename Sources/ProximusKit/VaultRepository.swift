import Foundation
import Darwin

public struct VaultState: Codable, Equatable {
    public var header: VaultHeader
    public var head: String
}

/// Atomic head updates and an interprocess lock coordinate the app and AutoFill extension.
/// All records, including titles and URLs, live inside authenticated encrypted snapshots.
public final class VaultRepository {
    public let directory: URL
    private let manager = FileManager.default
    public init(directory: URL) throws {
        self.directory = directory
        try manager.createDirectory(at: directory.appendingPathComponent("objects"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    public var exists: Bool { manager.fileExists(atPath: directory.appendingPathComponent("state.json").path) }
    public func state() throws -> VaultState {
        let value = try Encoding.decode(VaultState.self, from: boundedRead(directory.appendingPathComponent("state.json")))
        try value.header.validate()
        guard EncryptedSnapshot.validHash(value.head) else { throw ProximusError.authentication }
        return value
    }
    public func object(_ hash: String) throws -> Data {
        guard EncryptedSnapshot.validHash(hash) else { throw ProximusError.authentication }
        let data = try boundedRead(directory.appendingPathComponent("objects/" + hash))
        guard VaultCrypto.digest(data) == hash else { throw ProximusError.authentication }
        return data
    }
    @discardableResult public func storeObject(_ data: Data) throws -> String {
        _ = try Encoding.decode(EncryptedSnapshot.self, from: data)
        let hash = VaultCrypto.digest(data)
        let path = directory.appendingPathComponent("objects/" + hash)
        if !manager.fileExists(atPath: path.path) { try write(data, to: path) }
        return hash
    }
    public func create(passphrase: String, recovery: Data, contents: VaultContents) throws -> (VaultState, Data) {
        try contents.validate()
        let key = try VaultCrypto.random(32)
        var header = VaultHeader(vaultID: UUID(), salt: try VaultCrypto.random(16), wrappedKey: Data())
        let wrapping = try VaultCrypto.derive(passphrase: passphrase, recovery: recovery, salt: header.salt)
        header.wrappedKey = try VaultCrypto.seal(key, key: wrapping, context: header.context)
        let snapshot = try makeSnapshot(contents, key: key, vaultID: header.vaultID, revision: 0, parents: [])
        return try locked {
            guard !exists else { throw ProximusError.conflict }
            let state = VaultState(header: header, head: try storeObject(snapshot))
            try writeState(state)
            return (state, key)
        }
    }
    public func unlock(passphrase: String, recovery: Data) throws -> (VaultState, VaultContents, Data) {
        let current = try state()
        let wrapping = try VaultCrypto.derive(passphrase: passphrase, recovery: recovery, salt: current.header.salt)
        let key = try VaultCrypto.open(current.header.wrappedKey, key: wrapping, context: current.header.context)
        return (current, try contents(state: current, key: key), key)
    }
    public func contents(state: VaultState, key: Data) throws -> VaultContents {
        try Encoding.decode(EncryptedSnapshot.self, from: object(state.head)).decrypt(key: key, vaultID: state.header.vaultID)
    }
    @discardableResult public func save(_ contents: VaultContents, key: Data, expected: VaultState) throws -> VaultState {
        try contents.validate()
        return try locked {
            guard try state() == expected else { throw ProximusError.conflict }
            let previous = try Encoding.decode(EncryptedSnapshot.self, from: object(expected.head))
            _ = try previous.decrypt(key: key, vaultID: expected.header.vaultID)
            let snapshot = try makeSnapshot(contents, key: key, vaultID: expected.header.vaultID, revision: previous.header.revision + 1, parents: [expected.head])
            let next = VaultState(header: expected.header, head: try storeObject(snapshot))
            try writeState(next)
            return next
        }
    }
    public func backup() throws -> Data {
        let current = try state()
        return try Encoding.encode(VaultBackup(header: current.header, snapshot: object(current.head)))
    }
    public func restore(_ data: Data, passphrase: String, recovery: Data) throws -> Data {
        let backup = try Encoding.decode(VaultBackup.self, from: data)
        guard backup.format == 1 else { throw ProximusError.invalid("Unsupported backup version.") }
        try backup.header.validate()
        let wrapping = try VaultCrypto.derive(passphrase: passphrase, recovery: recovery, salt: backup.header.salt)
        let key = try VaultCrypto.open(backup.header.wrappedKey, key: wrapping, context: backup.header.context)
        try install(header: backup.header, snapshot: backup.snapshot, key: key)
        return key
    }
    /// Used only after recovery authentication or an explicitly approved pairing session.
    public func install(header: VaultHeader, snapshot: Data, key: Data) throws {
        try header.validate()
        _ = try Encoding.decode(EncryptedSnapshot.self, from: snapshot).decrypt(key: key, vaultID: header.vaultID)
        try locked {
            guard !exists else { throw ProximusError.invalid("A vault already exists on this device. Export it before using another vault.") }
            try writeState(VaultState(header: header, head: storeObject(snapshot)))
        }
    }
    public func adopt(head: String, key: Data, expected: VaultState) throws -> VaultState {
        let snapshot = try Encoding.decode(EncryptedSnapshot.self, from: object(head))
        _ = try snapshot.decrypt(key: key, vaultID: expected.header.vaultID)
        return try locked {
            guard try state() == expected else { throw ProximusError.conflict }
            let next = VaultState(header: expected.header, head: head)
            try writeState(next)
            return next
        }
    }
    public func merge(local: VaultState, remote: String, key: Data) throws -> VaultState {
        let a = try Encoding.decode(EncryptedSnapshot.self, from: object(local.head))
        let b = try Encoding.decode(EncryptedSnapshot.self, from: object(remote))
        var contents = try a.decrypt(key: key, vaultID: local.header.vaultID)
        let other = try b.decrypt(key: key, vaultID: local.header.vaultID)
        // Explicit keep-both merge never chooses a secret based on an untrusted timestamp.
        for item in other.items {
            if let existing = contents.items.first(where: { $0.id == item.id }) {
                if existing != item {
                    var copy = item; copy.id = UUID(); copy.title = String((item.title + " (other device)").prefix(128))
                    contents.items.append(copy)
                }
            } else { contents.items.append(item) }
        }
        for device in other.devices where !contents.devices.contains(where: { $0.id == device.id }) { contents.devices.append(device) }
        try contents.validate()
        let data = try makeSnapshot(contents, key: key, vaultID: local.header.vaultID, revision: max(a.header.revision, b.header.revision) + 1, parents: [local.head, remote])
        return try locked {
            guard try state() == local else { throw ProximusError.conflict }
            let next = VaultState(header: local.header, head: try storeObject(data))
            try writeState(next)
            return next
        }
    }
    private func makeSnapshot(_ contents: VaultContents, key: Data, vaultID: UUID, revision: UInt64, parents: [String]) throws -> Data {
        let header = SnapshotHeader(vaultID: vaultID, revision: revision, parents: parents)
        return try Encoding.encode(EncryptedSnapshot(header: header, ciphertext: VaultCrypto.seal(Encoding.encode(contents), key: key, context: Encoding.encode(header))))
    }
    private func boundedRead(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= VaultCrypto.maximumPayload * 2 else { throw ProximusError.invalid("This file exceeds the vault size limit.") }
        return try Data(contentsOf: url)
    }
    private func writeState(_ state: VaultState) throws { try write(Encoding.encode(state), to: directory.appendingPathComponent("state.json")) }
    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = Darwin.open(directory.appendingPathComponent("vault.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProximusError.unavailable("Cannot open the vault lock.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ProximusError.unavailable("Cannot lock the vault file.") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
