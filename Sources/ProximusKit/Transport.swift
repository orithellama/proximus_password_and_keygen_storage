import Foundation

/// Ephemeral requests: no cookies, no HTTP cache, no redirects, bounded response memory.
public final class BoundedHTTP: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private let limit: Int
    private let digestCredential: URLCredential?
    private let origin: URL?
    private init(limit: Int, origin: URL?, digestCredential: URLCredential?) { self.limit = limit; self.origin = origin; self.digestCredential = digestCredential }
    public static func send(_ request: URLRequest, limit: Int = VaultCrypto.maximumPayload * 2, digestCredential: URLCredential? = nil) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let delegate = BoundedHTTP(limit: limit, origin: request.url, digestCredential: digestCredential)
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil
            config.urlCredentialStorage = nil
            // A local wallet companion must not be routed through a configured proxy.
            if digestCredential != nil { config.connectionProxyDictionary = [:] }
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.dataTask(with: request).resume()
        }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest,
           challenge.previousFailureCount == 0, let credential = digestCredential, let origin,
           space.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == origin.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
           space.protocol == origin.scheme, space.port == (origin.port ?? (origin.scheme == "https" ? 443 : 80)) {
            completionHandler(.useCredential, credential)
        } else { completionHandler(.performDefaultHandling, nil) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else { completionHandler(.cancel); return }
        self.response = response; completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= limit - buffer.count else { dataTask.cancel(); return }
        buffer.append(data)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { self.continuation = nil; session.invalidateAndCancel(); self.session = nil }
        if let error { continuation?.resume(throwing: error) }
        else if let response { continuation?.resume(returning: (buffer, response)) }
        else { continuation?.resume(throwing: ProximusError.transport("The server returned an invalid response.")) }
    }
}

public protocol VaultTransport {
    func head() async throws -> String?
    func get(_ hash: String) async throws -> Data
    func put(_ hash: String, data: Data) async throws
    func setHead(_ hash: String, expected: String?) async throws
}

public struct RelayClient: VaultTransport {
    public let configuration: RelayConfiguration
    public let vaultID: UUID
    public init(configuration: RelayConfiguration, vaultID: UUID) throws { self.configuration = try configuration.validated(); self.vaultID = vaultID }
    private func request(_ method: String, suffix: String = "", data: Data? = nil, match: String? = nil, enrollment: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let url = configuration.endpoint.appendingPathComponent("v1/vaults/" + vaultID.uuidString.lowercased() + suffix)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = data
        request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let enrollment { request.setValue(enrollment, forHTTPHeaderField: "X-Enrollment-Key") }
        if let match { request.setValue(match.isEmpty ? "\"\"" : "\"" + match + "\"", forHTTPHeaderField: "If-Match") }
        return try await BoundedHTTP.send(request)
    }
    public func create(enrollment: String) async throws {
        let (_, response) = try await request("PUT", enrollment: enrollment)
        guard response.statusCode == 201 || response.statusCode == 204 else { throw failure(response) }
    }
    public func head() async throws -> String? {
        let (data, response) = try await request("GET", suffix: "/head")
        guard response.statusCode == 200, let hash = String(data: data, encoding: .utf8), hash.isEmpty || EncryptedSnapshot.validHash(hash) else { throw failure(response) }
        return hash.isEmpty ? nil : hash
    }
    public func get(_ hash: String) async throws -> Data {
        guard EncryptedSnapshot.validHash(hash) else { throw ProximusError.authentication }
        let (data, response) = try await request("GET", suffix: "/objects/" + hash)
        guard response.statusCode == 200 else { throw failure(response) }
        guard VaultCrypto.digest(data) == hash else { throw ProximusError.authentication }
        return data
    }
    public func put(_ hash: String, data: Data) async throws {
        guard VaultCrypto.digest(data) == hash else { throw ProximusError.authentication }
        let (_, response) = try await request("PUT", suffix: "/objects/" + hash, data: data)
        guard response.statusCode == 201 || response.statusCode == 204 else { throw failure(response) }
    }
    public func setHead(_ hash: String, expected: String?) async throws {
        let (_, response) = try await request("PUT", suffix: "/head", data: Data(hash.utf8), match: expected ?? "")
        if response.statusCode == 409 { throw ProximusError.conflict }
        guard response.statusCode == 204 else { throw failure(response) }
    }
    private func failure(_ response: HTTPURLResponse) -> ProximusError { .transport("The relay could not complete this request (HTTP \(response.statusCode)). No plaintext was sent.") }
}

public enum SyncResult { case unchanged, updated(VaultState), conflict(remote: String) }

public struct VaultSync {
    public let repository: VaultRepository
    public let client: any VaultTransport
    public init(repository: VaultRepository, client: any VaultTransport) { self.repository = repository; self.client = client }
    public func synchronize(key: Data, expected: VaultState) async throws -> SyncResult {
        guard try repository.state() == expected else { throw ProximusError.conflict }
        let remote = try await client.head()
        if remote == expected.head { return .unchanged }
        let localHistory = try await history(head: expected.head, key: key, vaultID: expected.header.vaultID, fetch: false, stopAt: Set(remote.map { [$0] } ?? []))
        if let remote {
            if localHistory.contains(remote) {
                try await upload(localHistory)
                guard try repository.state() == expected else { throw ProximusError.conflict }
                try await client.setHead(expected.head, expected: remote)
                return .unchanged
            }
            let remoteHistory = try await history(head: remote, key: key, vaultID: expected.header.vaultID, fetch: true, stopAt: localHistory)
            if remoteHistory.contains(expected.head) {
                return .updated(try repository.adopt(head: remote, key: key, expected: expected))
            }
            return .conflict(remote: remote)
        }
        try await upload(localHistory)
        guard try repository.state() == expected else { throw ProximusError.conflict }
        try await client.setHead(expected.head, expected: nil)
        return .unchanged
    }
    private func upload(_ hashes: Set<String>) async throws {
        for hash in hashes { try await client.put(hash, data: repository.object(hash)) }
    }
    private func history(head: String, key: Data, vaultID: UUID, fetch: Bool, stopAt: Set<String>) async throws -> Set<String> {
        var seen = Set<String>(), pending = [head]
        while let hash = pending.popLast() {
            if seen.contains(hash) { continue }
            guard seen.count < 10000 else { throw ProximusError.unavailable("The relay history limit has been reached. Move to a fresh vault to start a new history.") }
            let data: Data
            if let local = try? repository.object(hash) { data = local }
            else if fetch {
                data = try await client.get(hash)
            } else {
                // A backup or pairing imports an authenticated checkpoint, not the entire history.
                continue
            }
            let snapshot = try Encoding.decode(EncryptedSnapshot.self, from: data)
            _ = try snapshot.decrypt(key: key, vaultID: vaultID)
            guard snapshot.header.parents.allSatisfy({ $0 != hash }) else { throw ProximusError.authentication }
            _ = try repository.storeObject(data)
            seen.insert(hash)
            if !stopAt.contains(hash) { pending.append(contentsOf: snapshot.header.parents) }
        }
        return seen
    }
}
