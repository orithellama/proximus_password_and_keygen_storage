import XCTest
@testable import ProximusKit

final class RecoveryTests: XCTestCase {
    func testEncryptedKitRestoresAllNetworksAndNeverContainsPlaintext() throws {
        let owner = UUID(); var records = [WalletRecoveryRecord](), items = [VaultItem]()
        for network in WalletNetwork.allCases {
            let material = try WalletCrypto.derive(network: network)
            let metadata = material.metadata(network: network, deviceID: owner)
            records.append(WalletRecoveryRecord(metadata: metadata, material: material))
            items.append(VaultItem(kind: .wallet, title: network.label, modifiedAt: Date(timeIntervalSince1970: 1700000000), wallet: metadata))
        }
        items.append(VaultItem(title: "Account", password: "private-test-password", modifiedAt: Date(timeIntervalSince1970: 1700000000)))
        let payload = RecoveryPayload(contents: VaultContents(items: items, createdAt: Date(timeIntervalSince1970: 1700000000)), wallets: records)
        let salt = try VaultCrypto.random(16), password = "separate backup test password"
        let key = try RecoveryKit.key(password: password, salt: salt)
        let encrypted = try RecoveryKit.seal(payload, key: key, salt: salt)
        let text = String(decoding: encrypted, as: UTF8.self)
        XCTAssertFalse(text.contains("private-test-password"))
        for record in records { XCTAssertFalse(text.contains(record.material.recovery)); XCTAssertFalse(text.contains(record.material.privateKey)) }
        let restored = try RecoveryKit.open(encrypted, password: password)
        XCTAssertEqual(restored.contents, payload.contents)
        XCTAssertEqual(restored.wallets.map { $0.material.recovery }, records.map { $0.material.recovery })
        XCTAssertNotEqual(encrypted, try RecoveryKit.seal(payload, key: key, salt: salt))
        XCTAssertThrowsError(try RecoveryKit.open(encrypted, password: "wrong separate backup password"))
        var kit = try Encoding.decode(RecoveryKit.self, from: encrypted)
        kit.salt[0] ^= 1; XCTAssertThrowsError(try RecoveryKit.open(Encoding.encode(kit), password: password))
        kit = try Encoding.decode(RecoveryKit.self, from: encrypted); kit.ciphertext[15] ^= 1
        XCTAssertThrowsError(try RecoveryKit.open(Encoding.encode(kit), password: password))
        kit.kdf = "attacker-controlled-cost"; XCTAssertThrowsError(try RecoveryKit.open(Encoding.encode(kit), password: password))
    }
    func testMismatchedWalletRecoveryCannotBeExported() throws {
        let material = try WalletCrypto.derive(network: .solana), other = try WalletCrypto.derive(network: .solana)
        let metadata = material.metadata(network: .solana, deviceID: UUID())
        var altered = material; altered.recovery = other.recovery
        let payload = RecoveryPayload(contents: VaultContents(items: [VaultItem(kind: .wallet, title: "Wallet", wallet: metadata)]), wallets: [WalletRecoveryRecord(metadata: metadata, material: altered)])
        XCTAssertThrowsError(try payload.validate())
        XCTAssertThrowsError(try RecoveryKit.key(password: "short", salt: Data(repeating: 0, count: 16)))
    }
    func testChosenFolderStoresEncryptedRecoverableFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let salt = try VaultCrypto.random(16), password = "independent recovery password"
        let contents = VaultContents(items: [VaultItem(title: "Local test", password: "secret-in-kit-only")])
        let data = try RecoveryKit.seal(RecoveryPayload(contents: contents, wallets: []), key: RecoveryKit.key(password: password, salt: salt), salt: salt)
        let bookmark = try RecoveryFolder.bookmark(folder)
        try RecoveryFolder.write(data, bookmark: bookmark, name: "test.proximusrecovery")
        let saved = try BoundedFile.read(folder.appendingPathComponent("test.proximusrecovery"), limit: 1024 * 1024)
        XCTAssertEqual(saved, data)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("secret-in-kit-only"))
        let recovered = try RecoveryKit.open(saved, password: password)
        XCTAssertEqual(recovered.contents.items.first?.password, "secret-in-kit-only")
        let repository = try VaultRepository(directory: folder.appendingPathComponent("restored"))
        let factors = try VaultCrypto.random(32)
        let (_, key) = try repository.create(passphrase: "a different new master password", recovery: factors, contents: recovered.contents)
        XCTAssertEqual(try repository.contents(state: repository.state(), key: key).items.first?.password, "secret-in-kit-only")
    }
    func testBoundedReadRejectsOversizedFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 1, count: 1025).write(to: file)
        XCTAssertThrowsError(try BoundedFile.read(file, limit: 1024))
        XCTAssertEqual(try BoundedFile.read(file, limit: 1025).count, 1025)
    }
    func testRPCUsesReadOnlyMethodsAndRejectsUnsafeEndpoints() throws {
        let methods: [WalletNetwork: String] = [.solana: "getGenesisHash", .evm: "eth_chainId", .bitcoin: "getblockchaininfo", .monero: "get_info"]
        for network in WalletNetwork.allCases {
            let configuration = try RPCConfiguration(network: network, endpoint: URL(string: "https://rpc.example/json_rpc")!, username: "rpc", password: "node-auth-only")
            let request = try configuration.request()
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["method"] as? String, methods[network]); XCTAssertEqual((body["params"] as? [String])?.count, 0)
            XCTAssertNil(request.url?.user); XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.hasPrefix("Basic "))
        }
        for value in ["http://remote.example", "file:///tmp/secrets", "https://user:pass@rpc.example", "https://rpc.example/#fragment"] {
            XCTAssertThrowsError(try RPCConfiguration(network: .evm, endpoint: URL(string: value)!))
        }
        let config = try RPCConfiguration(network: .evm, endpoint: URL(string: "http://127.0.0.1:8545")!)
        XCTAssertEqual(try config.parseResponse(Data(#"{"id":"proximus-connection-check","result":"0x1"}"#.utf8)), "Connected. EVM chain ID: 0x1")
        XCTAssertThrowsError(try config.parseResponse(Data(#"{"id":"wrong","result":"0x1"}"#.utf8)))
        XCTAssertThrowsError(try config.parseResponse(Data(#"{"id":"proximus-connection-check","error":{"message":"arbitrary provider text"},"result":"0x1"}"#.utf8)))
    }
}
