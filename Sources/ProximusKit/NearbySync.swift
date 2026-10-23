import Foundation
import CryptoKit
import Network
import Combine

/// Rotating discovery identifiers reveal neither a vault identifier nor device names.
struct NearbyAdvertisement: Codable {
    var session: UUID
    var publicKey: Data
    var expires: Int64
    var service: String { "px-" + session.uuidString.lowercased() }
    var context: Data { Data("proximus/v1/nearby/discovery/\(session.uuidString)/\(expires)/".utf8) + publicKey }
    func authentication(key: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: context, using: SymmetricKey(data: key))) }
    func validate(tag: Data, key: Data, now: Date = Date()) throws {
        guard key.count == 32, publicKey.count == 65, expires > Int64(now.timeIntervalSince1970), expires <= Int64(now.timeIntervalSince1970) + 180,
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: context, using: SymmetricKey(data: key)) else { throw ProximusError.authentication }
        _ = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
    }
    var record: NWTXTRecord {
        var value = NWTXTRecord()
        value["id"] = session.uuidString; value["key"] = publicKey.base64URLEncoded; value["expires"] = String(expires)
        return value
    }
    init(session: UUID = UUID(), publicKey: Data, expires: Int64) { self.session = session; self.publicKey = publicKey; self.expires = expires }
    init(record: NWTXTRecord) throws {
        guard let id = record["id"], let session = UUID(uuidString: id), let encoded = record["key"], let publicKey = Data(base64URL: encoded),
              let expiry = record["expires"], let expires = Int64(expiry) else { throw ProximusError.authentication }
        self.init(session: session, publicKey: publicKey, expires: expires)
    }
}

enum NearbyCrypto {
    static func key(privateKey: P256.KeyAgreement.PrivateKey, peer: Data, advertisement: NearbyAdvertisement, clientPublicKey: Data, vaultKey: Data) throws -> Data {
        guard vaultKey.count == 32, clientPublicKey.count == 65 else { throw ProximusError.authentication }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer))
        let transcript = advertisement.context + clientPublicKey
        let salt = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: vaultKey)))
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("proximus/v1/nearby/session".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }
    static func context(direction: String, sequence: UInt64) -> Data { Data("proximus/v1/nearby/\(direction)/\(sequence)".utf8) }
}

/// Directional, ordered encrypted records. Large objects are split into bounded records.
final class NearbyChannel {
    private let wire: FramedConnection
    private let key: SecretBytes
    private let sending: String
    private let receiving: String
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var remaining = 64 * 1024 * 1024
    init(wire: FramedConnection, key: Data, client: Bool) throws {
        self.wire = wire; self.key = try SecretBytes(key)
        sending = client ? "client" : "host"; receiving = client ? "host" : "client"
    }
    func send(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= VaultCrypto.maximumPayload * 2, data.count <= remaining else { throw ProximusError.invalid("Nearby transfer exceeds the session limit. Sync smaller batches.") }
        remaining -= data.count
        let n = UInt32(data.count)
        try await sendRecord(Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]))
        for offset in stride(from: 0, to: data.count, by: 65536) { try await sendRecord(data.subdata(in: offset..<min(offset + 65536, data.count))) }
    }
    func receive() async throws -> Data {
        let prefix = try await receiveRecord()
        guard prefix.count == 4 else { throw ProximusError.authentication }
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...VaultCrypto.maximumPayload * 2).contains(length), length <= remaining else { throw ProximusError.authentication }
        remaining -= length
        var data = Data()
        while data.count < length {
            let part = try await receiveRecord()
            guard !part.isEmpty, part.count <= length - data.count else { throw ProximusError.authentication }
            data.append(part)
        }
        return data
    }
    private func sendRecord(_ data: Data) async throws {
        try Task.checkCancellation()
        guard sent < UInt64.max else { throw ProximusError.authentication }
        let sealed = try key.withData { try VaultCrypto.seal(data, key: $0, context: NearbyCrypto.context(direction: sending, sequence: sent)) }
        sent += 1; try await wire.send(sealed)
    }
    private func receiveRecord() async throws -> Data {
        try Task.checkCancellation()
        guard received < UInt64.max else { throw ProximusError.authentication }
        let sealed = try await wire.receive(maximumBytes: 65536 + 28)
        let data = try key.withData { try VaultCrypto.open(sealed, key: $0, context: NearbyCrypto.context(direction: receiving, sequence: received)) }
        received += 1; return data
    }
}

/// The nearby peer may advance a verified history, but may not roll it back or silently merge it.
final class NearbyRepositoryTransport: VaultTransport {
    let repository: VaultRepository
    private let key: SecretBytes
    private var state: VaultState
    private var remaining = 64 * 1024 * 1024
    init(repository: VaultRepository, key: Data) throws { self.repository = repository; self.key = try SecretBytes(key); state = try repository.state() }
    private func check() throws { guard try repository.state() == state else { throw ProximusError.conflict } }
    func head() async throws -> String? { try check(); return state.head }
    func get(_ hash: String) async throws -> Data {
        try check(); let data = try repository.object(hash)
        _ = try key.withData { try Encoding.decode(EncryptedSnapshot.self, from: data).decrypt(key: $0, vaultID: state.header.vaultID) }
        return data
    }
    func put(_ hash: String, data: Data) async throws {
        try check()
        guard VaultCrypto.digest(data) == hash, data.count <= remaining else { throw ProximusError.authentication }
        _ = try key.withData { try Encoding.decode(EncryptedSnapshot.self, from: data).decrypt(key: $0, vaultID: state.header.vaultID) }
        remaining -= data.count; _ = try repository.storeObject(data)
    }
    func setHead(_ hash: String, expected: String?) async throws {
        try check()
        guard expected == state.head else { throw ProximusError.conflict }
        var pending = [hash], seen = Set<String>(), descends = false
        while let next = pending.popLast() {
            if next == state.head { descends = true; break }
            if seen.contains(next) { continue }
            guard seen.count < 10000 else { throw ProximusError.authentication }
            seen.insert(next)
            // Pairing imports an authenticated checkpoint without its older objects.
            guard let data = try? repository.object(next) else { continue }
            let snapshot = try Encoding.decode(EncryptedSnapshot.self, from: data)
            _ = try key.withData { try snapshot.decrypt(key: $0, vaultID: state.header.vaultID) }
            pending.append(contentsOf: snapshot.header.parents.filter { !seen.contains($0) })
        }
        guard descends else { throw ProximusError.conflict }
        state = try key.withData { try repository.adopt(head: hash, key: $0, expected: state) }
    }
}

private struct NearbyHello: Codable { var publicKey: Data; var proof: Data }
private struct NearbyIdentity: Codable { var vault: UUID; var device: UUID }
private struct NearbyRequest: Codable { var operation: String; var hash: String?; var expected: String?; var data: Data? }
private struct NearbyResponse: Codable { var head: String?; var data: Data? }
private final class NearbyClient: VaultTransport {
    let channel: NearbyChannel
    init(_ channel: NearbyChannel) { self.channel = channel }
    private func request(_ operation: String, hash: String? = nil, expected: String? = nil, data: Data? = nil) async throws -> NearbyResponse {
        try await channel.send(Encoding.encode(NearbyRequest(operation: operation, hash: hash, expected: expected, data: data)))
        return try Encoding.decode(NearbyResponse.self, from: await channel.receive())
    }
    func head() async throws -> String? { let head = try await request("head").head; guard let head, EncryptedSnapshot.validHash(head) else { throw ProximusError.authentication }; return head }
    func get(_ hash: String) async throws -> Data { guard let data = try await request("get", hash: hash).data, VaultCrypto.digest(data) == hash else { throw ProximusError.authentication }; return data }
    func put(_ hash: String, data: Data) async throws { _ = try await request("put", hash: hash, data: data) }
    func setHead(_ hash: String, expected: String?) async throws { _ = try await request("advance", hash: hash, expected: expected) }
    func finish(conflict: Bool) async throws { _ = try await request(conflict ? "conflict" : "done") }
}

@MainActor public final class NearbySyncSession: ObservableObject {
    @Published public private(set) var status = ""
    @Published public private(set) var failure: String?
    @Published public private(set) var complete = false
    private static let service = "_proximus-sync._tcp"
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var wire: FramedConnection?
    private var worker: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var vaultKey: SecretBytes?
    private var running = false
    public init() {}
    public func cancel() {
        running = false
        browser?.cancel(); browser = nil; listener?.cancel(); listener = nil
        wire?.connection.cancel(); wire = nil
        worker?.cancel(); worker = nil; timeout?.cancel(); timeout = nil
        vaultKey?.erase(); vaultKey = nil
    }
    private func fail(_ error: Error) { guard running else { return }; failure = error.localizedDescription; status = "Nearby sync stopped"; cancel() }
    private func finish(_ status: String) { complete = true; self.status = status; cancel() }
    private func parameters() -> NWParameters { let parameters = NWParameters.tcp; parameters.includePeerToPeer = true; return parameters }
    public func start(session: VaultSession) throws {
        guard !running, let state = session.state, session.isUnlocked else { throw ProximusError.locked }
        let vaultKey = try SecretBytes(session.nearbyKey()); self.vaultKey = vaultKey
        let privateKey = P256.KeyAgreement.PrivateKey()
        let advertisement = NearbyAdvertisement(publicKey: privateKey.publicKey.x963Representation, expires: Int64(Date().timeIntervalSince1970) + 120)
        var record = advertisement.record; record["tag"] = vaultKey.withData { advertisement.authentication(key: $0).base64URLEncoded }
        let listener = try NWListener(using: parameters()); self.listener = listener
        listener.service = NWListener.Service(name: advertisement.service, type: Self.service, txtRecord: record.data)
        running = true; complete = false; failure = nil; status = "Looking for another device with this vault…"
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.fail(ProximusError.transport("No sync completed. Keep both apps open, unlock both vaults, and turn on Wi-Fi. Try Nearby sync again."))
        }
        listener.stateUpdateHandler = { [weak self] state in if case .failed(let error) = state { Task { @MainActor in self?.fail(error) } } }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.running, self.wire == nil, session.isUnlocked else { connection.cancel(); return }
                let wire = FramedConnection(connection); self.wire = wire
                connection.start(queue: .global(qos: .userInitiated))
                self.worker = Task {
                    do {
                        let hello = try Encoding.decode(NearbyHello.self, from: await wire.receive(maximumBytes: 4096))
                        guard advertisement.expires > Int64(Date().timeIntervalSince1970) else { throw ProximusError.authentication }
                        let key = try vaultKey.withData { try NearbyCrypto.key(privateKey: privateKey, peer: hello.publicKey, advertisement: advertisement, clientPublicKey: hello.publicKey, vaultKey: $0) }
                        let identity = try Encoding.decode(NearbyIdentity.self, from: VaultCrypto.open(hello.proof, key: key, context: Data("proximus/v1/nearby/hello".utf8)))
                        guard identity.vault == state.header.vaultID, identity.device != session.deviceID, session.isUnlocked else { throw ProximusError.authentication }
                        let channel = try NearbyChannel(wire: wire, key: key, client: false)
                        try await channel.send(Data("ready".utf8)); self.status = "Syncing encrypted changes with your nearby device…"
                        let store = try vaultKey.withData { try NearbyRepositoryTransport(repository: session.repository, key: $0) }
                        for _ in 0..<20004 {
                            let request = try Encoding.decode(NearbyRequest.self, from: await channel.receive())
                            guard self.running, session.isUnlocked else { throw ProximusError.locked }
                            var response = NearbyResponse()
                            switch request.operation {
                            case "head": response.head = try await store.head()
                            case "get": guard let hash = request.hash else { throw ProximusError.authentication }; response.data = try await store.get(hash)
                            case "put": guard let hash = request.hash, let data = request.data else { throw ProximusError.authentication }; try await store.put(hash, data: data)
                            case "advance": guard let hash = request.hash else { throw ProximusError.authentication }; try await store.setHead(hash, expected: request.expected)
                            case "done", "conflict":
                                try await channel.send(Encoding.encode(response))
                                try await session.finishNearby(.unchanged)
                                self.finish(request.operation == "conflict" ? "Review conflicting changes on your other device, then sync again." : "Both devices are up to date.")
                                return
                            default: throw ProximusError.authentication
                            }
                            try await channel.send(Encoding.encode(response))
                        }
                        throw ProximusError.authentication
                    } catch { self.fail(error) }
                }
            }
        }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.service, domain: "local."), using: parameters()); self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in if case .failed(let error) = state { Task { @MainActor in self?.fail(error) } } }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.running, self.wire == nil, session.isUnlocked else { return }
                for result in results {
                    guard case .bonjour(let record) = result.metadata, let remote = try? NearbyAdvertisement(record: record), advertisement.service < remote.service,
                          let encoded = record["tag"], let tag = Data(base64URL: encoded), (try? vaultKey.withData { try remote.validate(tag: tag, key: $0) }) != nil,
                          case .service(let name, _, _, _) = result.endpoint, name == remote.service else { continue }
                    let connection = NWConnection(to: result.endpoint, using: self.parameters())
                    let wire = FramedConnection(connection); self.wire = wire
                    connection.start(queue: .global(qos: .userInitiated))
                    self.worker = Task {
                        do {
                            let clientKey = P256.KeyAgreement.PrivateKey()
                            let key = try vaultKey.withData { try NearbyCrypto.key(privateKey: clientKey, peer: remote.publicKey, advertisement: remote, clientPublicKey: clientKey.publicKey.x963Representation, vaultKey: $0) }
                            let identity = NearbyIdentity(vault: state.header.vaultID, device: session.deviceID)
                            let hello = NearbyHello(publicKey: clientKey.publicKey.x963Representation, proof: try VaultCrypto.seal(Encoding.encode(identity), key: key, context: Data("proximus/v1/nearby/hello".utf8)))
                            try await wire.send(Encoding.encode(hello))
                            let channel = try NearbyChannel(wire: wire, key: key, client: true)
                            guard try await channel.receive() == Data("ready".utf8), self.running, session.isUnlocked else { throw ProximusError.authentication }
                            self.status = "Syncing encrypted changes with your nearby device…"
                            let client = NearbyClient(channel)
                            let result = try await VaultSync(repository: session.repository, client: client).synchronize(key: vaultKey.withData { $0 }, expected: state)
                            let conflict: Bool; if case .conflict = result { conflict = true } else { conflict = false }
                            try await client.finish(conflict: conflict)
                            try await session.finishNearby(result)
                            self.finish(conflict ? "Review conflicting changes on this device, then sync again." : "Both devices are up to date.")
                        } catch { self.fail(error) }
                    }
                    return
                }
            }
        }
        listener.start(queue: .global(qos: .userInitiated)); browser.start(queue: .global(qos: .userInitiated))
    }
}
