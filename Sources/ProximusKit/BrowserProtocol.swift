import Foundation

public enum BrowserProtocol {
    public static let version = 1
    public static let extensionID = "ggbcckdjjdkabfcionkinepdlcddgcfm"
    public static let extensionOrigin = "chrome-extension://" + extensionID + "/"
    public static let maximumMessage = 32 * 1024
    public static let lifetime: TimeInterval = 120

    public static func origin(_ value: String) throws -> String {
        guard value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              let url = URLComponents(string: value), url.path.isEmpty, url.query == nil, url.fragment == nil,
              try DomainPolicy.origin(value) == value else {
            throw ProximusError.invalid("Use an exact HTTPS website address.")
        }
        return value
    }
}

public struct BrowserLogin: Codable, Equatable {
    public var username: String
    public var password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
}

public struct BrowserSaveLogin: Codable, Equatable {
    public var title: String
    public var username: String
    public var password: String
    public init(title: String, username: String, password: String) { self.title = title; self.username = username; self.password = password }
}

public struct BrowserRequest: Codable, Equatable {
    public enum Action: String, Codable { case fill, save }
    public let version: Int
    public let id: String
    public let action: Action
    public let origin: String
    public let login: BrowserSaveLogin?

    public init(id: String = UUID().uuidString.lowercased(), action: Action, origin: String, login: BrowserSaveLogin? = nil) throws {
        self.version = BrowserProtocol.version; self.id = id; self.action = action; self.origin = origin; self.login = login
        try validate()
    }
    public static func decode(_ data: Data) throws -> BrowserRequest {
        guard data.count <= BrowserProtocol.maximumMessage,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "id", "action", "origin", "login"]) else { throw ProximusError.invalid("Unsupported browser request.") }
        if let login = object["login"] as? [String: Any], Set(login.keys) != Set(["title", "username", "password"]) {
            throw ProximusError.invalid("Unsupported login fields.")
        }
        let request = try JSONDecoder().decode(BrowserRequest.self, from: data)
        try request.validate()
        return request
    }
    public func validate() throws {
        guard version == BrowserProtocol.version, let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id,
              (action == .save) == (login != nil) else { throw ProximusError.invalid("Unsupported browser request.") }
        _ = try BrowserProtocol.origin(origin)
        if let login { _ = try savedItem(login) }
    }
    public func matches(_ item: VaultItem) -> Bool {
        item.kind == .password && !item.password.isEmpty && DomainPolicy.matches(saved: item.website, requested: origin)
    }
    public func savedItem(_ login: BrowserSaveLogin, replacing item: VaultItem? = nil) throws -> VaultItem {
        guard action == .save, !login.password.isEmpty else { throw ProximusError.invalid("Enter a password to save.") }
        if let item, !matches(item) { throw ProximusError.authentication }
        var result = item ?? VaultItem()
        result.title = login.title; result.username = login.username; result.password = login.password; result.website = origin
        return try result.validated()
    }
}

public struct BrowserResponse: Encodable {
    public let version = BrowserProtocol.version
    public let id: String
    public let origin: String
    public let status: String
    public let login: BrowserLogin?
    public init(request: BrowserRequest, status: String, login: BrowserLogin? = nil) {
        self.id = request.id; self.origin = request.origin; self.status = status; self.login = login
    }
}

extension VaultSession {
    /// An exact-site, single-use release; it never exposes notes, keys, or other records.
    public func browserCredential(for request: BrowserRequest, item: VaultItem, using authorization: CredentialAuthorization = .device) async throws -> BrowserLogin {
        try request.validate()
        guard request.action == .fill, request.matches(item) else { throw ProximusError.authentication }
        let grant = try await authorizeCredentialAccess(item, reason: "Fill your login on " + request.origin, using: authorization)
        // Another app window may have edited the encrypted snapshot during authentication.
        guard try repository.state() == state else { try reload(); throw ProximusError.conflict }
        let approved = try consumeCredentialAccess(grant)
        guard request.matches(approved) else { throw ProximusError.authentication }
        return BrowserLogin(username: approved.username, password: approved.password)
    }
}

public enum BrowserMessageFrame {
    public static func length(_ prefix: Data) throws -> Int {
        guard prefix.count == 4 else { throw ProximusError.invalid("Incomplete browser message.") }
        let value = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard value > 0, value <= BrowserProtocol.maximumMessage else { throw ProximusError.invalid("Browser message exceeds its size limit.") }
        return Int(value)
    }
    public static func encode(_ response: BrowserResponse) throws -> Data {
        let body = try JSONEncoder().encode(response)
        guard !body.isEmpty, body.count <= BrowserProtocol.maximumMessage else { throw ProximusError.invalid("Browser response exceeds its size limit.") }
        var size = UInt32(body.count)
        var result = withUnsafeBytes(of: &size) { Data($0) }
        result.append(body)
        return result
    }
}
