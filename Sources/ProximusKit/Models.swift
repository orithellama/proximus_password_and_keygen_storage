import Foundation

public enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case password, passkey, note, wallet
    public var id: String { rawValue }
    public var label: String { switch self { case .password: return "Password"; case .passkey: return "Passkey"; case .note: return "Secure note"; case .wallet: return "Wallet" } }
    public var symbol: String { switch self { case .password: return "key.horizontal"; case .passkey: return "person.badge.key"; case .note: return "note.text"; case .wallet: return "wallet.bifold" } }
}

public struct PasskeyMetadata: Codable, Equatable {
    public var credentialID: Data
    public var userHandle: Data
    public var relyingParty: String
    public var deviceID: UUID
    public init(credentialID: Data, userHandle: Data, relyingParty: String, deviceID: UUID) { self.credentialID = credentialID; self.userHandle = userHandle; self.relyingParty = relyingParty; self.deviceID = deviceID }
}

public struct VaultItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String
    public var username: String
    public var website: String
    public var password: String
    public var notes: String
    public var collection: String
    public var favorite: Bool
    public var modifiedAt: Date
    public var passkey: PasskeyMetadata?
    public var wallet: WalletMetadata?
    public init(id: UUID = UUID(), kind: ItemKind = .password, title: String = "", username: String = "", website: String = "", password: String = "", notes: String = "", collection: String = "", favorite: Bool = false, modifiedAt: Date = Date(), passkey: PasskeyMetadata? = nil, wallet: WalletMetadata? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.username = username; self.website = website; self.password = password; self.notes = notes; self.collection = collection; self.favorite = favorite; self.modifiedAt = modifiedAt; self.passkey = passkey; self.wallet = wallet
    }
    public func validated() throws -> VaultItem {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 256, username.utf8.count <= 2048, password.utf8.count <= 4096, notes.utf8.count <= 65536, collection.utf8.count <= 128 else { throw ProximusError.invalid("Add a title and keep this item within its size limits.") }
        if !website.isEmpty { _ = try DomainPolicy.origin(website) }
        if kind == .passkey { guard let passkey, !passkey.credentialID.isEmpty, (1...64).contains(passkey.userHandle.count) else { throw ProximusError.invalid("Invalid passkey metadata.") } }
        if kind == .wallet {
            guard let wallet, password.isEmpty, passkey == nil else { throw ProximusError.invalid("Wallet records contain public addresses only.") }
            try wallet.validate()
        } else if wallet != nil { throw ProximusError.invalid("Unexpected wallet metadata.") }
        return self
    }
}

public struct PairedDevice: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var addedAt: Date
    public init(id: UUID, name: String, addedAt: Date = Date()) { self.id = id; self.name = name; self.addedAt = addedAt }
}

public struct VaultContents: Codable, Equatable {
    public var name: String
    public var items: [VaultItem]
    public var devices: [PairedDevice]
    public var createdAt: Date
    public init(name: String = "Personal", items: [VaultItem] = [], devices: [PairedDevice] = [], createdAt: Date = Date()) { self.name = name; self.items = items; self.devices = devices; self.createdAt = createdAt }
    public func validate() throws {
        guard items.count <= 10000, devices.count <= 100, Set(items.map(\.id)).count == items.count, name.utf8.count <= 128 else { throw ProximusError.invalid("Invalid vault contents.") }
        for item in items { _ = try item.validated() }
    }
}

public struct VaultHeader: Codable, Equatable {
    public var format: Int = 1
    public var vaultID: UUID
    public var kdf: String = "argon2id-v19-m65536-t3-p1-secret32"
    public var salt: Data
    public var wrappedKey: Data
    public var context: Data { Data("proximus/v1/recovery/\(vaultID.uuidString.lowercased())/\(kdf)".utf8) }
    public func validate() throws {
        guard format == 1, kdf == "argon2id-v19-m65536-t3-p1-secret32", salt.count == 16, wrappedKey.count == 60 else { throw ProximusError.invalid("Unsupported or damaged vault format.") }
    }
}

public struct SnapshotHeader: Codable, Equatable {
    public var format: Int = 1
    public var vaultID: UUID
    public var revision: UInt64
    public var parents: [String]
}

public struct EncryptedSnapshot: Codable, Equatable {
    public var header: SnapshotHeader
    public var ciphertext: Data
    public func decrypt(key: Data, vaultID: UUID) throws -> VaultContents {
        guard header.format == 1, header.vaultID == vaultID, header.parents.count <= 2, Set(header.parents).count == header.parents.count, header.parents.allSatisfy(Self.validHash), header.revision <= 1_000_000_000 else { throw ProximusError.authentication }
        let contents = try Encoding.decode(VaultContents.self, from: VaultCrypto.open(ciphertext, key: key, context: Encoding.encode(header)))
        try contents.validate()
        return contents
    }
    public static func validHash(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

public struct VaultBackup: Codable {
    public var format: Int = 1
    public var header: VaultHeader
    public var snapshot: Data
}

public struct RelayConfiguration: Codable, Equatable {
    public var endpoint: URL
    public var token: String
    public init(endpoint: URL, token: String) throws {
        guard endpoint.scheme == "https" || (["localhost", "127.0.0.1", "::1"].contains(endpoint.host ?? "") && endpoint.scheme == "http"), endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil, let bytes = Data(base64URL: token), bytes.count == 32 else { throw ProximusError.invalid("Use an HTTPS relay URL and a valid pairing token. Localhost may use HTTP for development.") }
        self.endpoint = endpoint; self.token = token
    }
    public func validated() throws -> RelayConfiguration { try RelayConfiguration(endpoint: endpoint, token: token) }
}

public enum DomainPolicy {
    public static func origin(_ value: String) throws -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 2048, !raw.contains("\\"), !raw.contains(where: { $0.isWhitespace }) else { throw ProximusError.invalid("Enter a valid HTTPS website.") }
        guard let url = URL(string: raw.contains("://") ? raw : "https://" + raw), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty, !host.hasSuffix("."), !host.contains("%") else { throw ProximusError.invalid("Only HTTPS websites without embedded credentials are supported.") }
        return "https://" + host + ((url.port == nil || url.port == 443) ? "" : ":\(url.port!)")
    }
    public static func matches(saved: String, requested: String) -> Bool {
        guard let a = try? origin(saved), let b = try? origin(requested) else { return false }
        return a == b
    }
    public static func relyingParty(_ value: String) throws -> String {
        guard !value.contains("/"), !value.contains(":"), let url = URL(string: try origin(value)), let host = url.host, host.contains("."), host == value.lowercased() else { throw ProximusError.invalid("Invalid relying party identifier.") }
        return host
    }
    public static func passwordNotice(destination: String?) -> String {
        if let destination { return "Your password will be shared with \(destination). Proximus cannot guarantee this website's safety. A compromised website or device may capture your password. Use a passkey when available." }
        return "The destination cannot be verified. Other software may read a copied password. Proximus cannot guarantee the safety of the website or device where you use it."
    }
}
