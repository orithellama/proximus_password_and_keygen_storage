import XCTest
import CryptoKit
import Network
@testable import ProximusKit

final class NearbyTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testDiscoveryAndHandshakeRequireTheSameVaultAndFreshTranscript() throws {
        let vaultKey = try VaultCrypto.random(32), host = P256.KeyAgreement.PrivateKey(), client = P256.KeyAgreement.PrivateKey()
        let advertisement = NearbyAdvertisement(publicKey: host.publicKey.x963Representation, expires: Int64(Date().timeIntervalSince1970) + 120)
        let tag = advertisement.authentication(key: vaultKey)
        try advertisement.validate(tag: tag, key: vaultKey)
        let parsed = try NearbyAdvertisement(record: advertisement.record)
        try parsed.validate(tag: tag, key: vaultKey)
        XCTAssertThrowsError(try advertisement.validate(tag: tag, key: VaultCrypto.random(32)))
        XCTAssertThrowsError(try advertisement.validate(tag: tag, key: vaultKey, now: Date().addingTimeInterval(181)))
        var changed = advertisement; changed.session = UUID()
        XCTAssertThrowsError(try changed.validate(tag: tag, key: vaultKey))
        let a = try NearbyCrypto.key(privateKey: host, peer: client.publicKey.x963Representation, advertisement: advertisement, clientPublicKey: client.publicKey.x963Representation, vaultKey: vaultKey)
        let b = try NearbyCrypto.key(privateKey: client, peer: host.publicKey.x963Representation, advertisement: advertisement, clientPublicKey: client.publicKey.x963Representation, vaultKey: vaultKey)
        XCTAssertEqual(a, b)
        let message = try VaultCrypto.seal(Data("secret".utf8), key: a, context: NearbyCrypto.context(direction: "client", sequence: 0))
        XCTAssertThrowsError(try VaultCrypto.open(message, key: b, context: NearbyCrypto.context(direction: "host", sequence: 0)))
        XCTAssertThrowsError(try VaultCrypto.open(message, key: b, context: NearbyCrypto.context(direction: "client", sequence: 1)))
        let outsider = try NearbyCrypto.key(privateKey: client, peer: host.publicKey.x963Representation, advertisement: advertisement, clientPublicKey: client.publicKey.x963Representation, vaultKey: VaultCrypto.random(32))
        XCTAssertThrowsError(try VaultCrypto.open(message, key: outsider, context: NearbyCrypto.context(direction: "client", sequence: 0)))
    }

    func testNearbySyncPushPullConflictAndRollbackRejection() async throws {
        let a = try VaultRepository(directory: directory.appendingPathComponent("a")), b = try VaultRepository(directory: directory.appendingPathComponent("b"))
        let (initial, key) = try a.create(passphrase: "a long test passphrase", recovery: VaultCrypto.random(32), contents: VaultContents(items: [VaultItem(title: "Account", password: "initial")]))
        try b.install(header: initial.header, snapshot: a.object(initial.head), key: key)
        var contents = try a.contents(state: initial, key: key); contents.items[0].password = "from a"
        let pushed = try a.save(contents, key: key, expected: initial)
        _ = try await VaultSync(repository: a, client: NearbyRepositoryTransport(repository: b, key: key)).synchronize(key: key, expected: pushed)
        XCTAssertEqual(try a.state(), try b.state())
        let bStore = try NearbyRepositoryTransport(repository: b, key: key)
        do { try await bStore.setHead(initial.head, expected: pushed.head); XCTFail("Rollback accepted") } catch { XCTAssertEqual(error as? ProximusError, .conflict) }
        contents.items[0].password = "from b"
        let remote = try b.save(contents, key: key, expected: pushed)
        _ = try await VaultSync(repository: a, client: NearbyRepositoryTransport(repository: b, key: key)).synchronize(key: key, expected: pushed)
        XCTAssertEqual(try a.state(), remote)
        contents.items[0].password = "a offline"
        let localFork = try a.save(contents, key: key, expected: remote)
        contents.items[0].password = "b offline"
        let remoteFork = try b.save(contents, key: key, expected: remote)
        let result = try await VaultSync(repository: a, client: NearbyRepositoryTransport(repository: b, key: key)).synchronize(key: key, expected: localFork)
        guard case .conflict(let hash) = result else { return XCTFail("Divergent edits were not reported") }
        XCTAssertEqual(hash, remoteFork.head); XCTAssertEqual(try a.state(), localFork); XCTAssertEqual(try b.state(), remoteFork)
        let merged = try a.merge(local: localFork, remote: hash, key: key)
        _ = try await VaultSync(repository: a, client: NearbyRepositoryTransport(repository: b, key: key)).synchronize(key: key, expected: merged)
        XCTAssertEqual(try a.state(), try b.state())
        XCTAssertEqual(Set(try b.contents(state: b.state(), key: key).items.map(\.password)), Set(["a offline", "b offline"]))
    }

    func testNearbyRejectsForeignObjectsAndConcurrentHeadChanges() async throws {
        let a = try VaultRepository(directory: directory.appendingPathComponent("a")), foreign = try VaultRepository(directory: directory.appendingPathComponent("foreign"))
        let (state, key) = try a.create(passphrase: "a long test passphrase", recovery: VaultCrypto.random(32), contents: VaultContents())
        let (other, _) = try foreign.create(passphrase: "another long passphrase", recovery: VaultCrypto.random(32), contents: VaultContents())
        let transport = try NearbyRepositoryTransport(repository: a, key: key)
        do { try await transport.put(other.head, data: foreign.object(other.head)); XCTFail("Foreign vault accepted") } catch { }
        XCTAssertThrowsError(try a.object(other.head))
        let changed = try a.save(VaultContents(items: [VaultItem(title: "Concurrent edit", password: "secret")]), key: key, expected: state)
        do { try await transport.setHead(state.head, expected: state.head); XCTFail("Concurrent change overwritten") } catch { XCTAssertEqual(error as? ProximusError, .conflict) }
        XCTAssertEqual(try a.state(), changed)
    }

    func testEncryptedChannelStreamsLargeMessagesAndRejectsReplayedRecords() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "Loopback listener ready"), accepted = expectation(description: "Loopback accepted")
        let server = ConnectionBox()
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in server.set(connection); connection.start(queue: .global()); accepted.fulfill() }
        listener.start(queue: .global())
        defer { listener.cancel(); server.get()?.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp); client.start(queue: .global())
        defer { client.cancel() }
        await fulfillment(of: [accepted], timeout: 5)
        let key = try VaultCrypto.random(32)
        let left = try NearbyChannel(wire: FramedConnection(client), key: key, client: true)
        let right = try NearbyChannel(wire: FramedConnection(XCTUnwrap(server.get())), key: key, client: false)
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { client.cancel(); server.get()?.cancel() } }
        defer { watchdog.cancel() }
        let data = try VaultCrypto.random(200000)
        async let received = right.receive()
        try await left.send(data)
        let copy = try await received; XCTAssertEqual(copy, data)
        async let reply = left.receive()
        try await right.send(Data("received".utf8))
        let response = try await reply; XCTAssertEqual(response, Data("received".utf8))
        let replay = try VaultCrypto.seal(Data([0, 0, 0, 1]), key: key, context: NearbyCrypto.context(direction: "client", sequence: 0))
        try await FramedConnection(client).send(replay)
        do { _ = try await right.receive(); XCTFail("Replayed record accepted") } catch { XCTAssertEqual(error as? ProximusError, .authentication) }
    }
}

private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    func set(_ value: NWConnection) { lock.lock(); defer { lock.unlock() }; connection = value }
    func get() -> NWConnection? { lock.lock(); defer { lock.unlock() }; return connection }
}
