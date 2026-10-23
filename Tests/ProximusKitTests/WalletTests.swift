import XCTest
@testable import ProximusKit

final class WalletTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
    private let fixture = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    func testBIP39AndNetworkRecoveryThroughFFI() throws {
        let words = try WalletCrypto.mnemonic()
        XCTAssertEqual(words.split(separator: " ").count, 24)
        XCTAssertNotEqual(words, try WalletCrypto.mnemonic())
        for network in WalletNetwork.allCases {
            let generated = try WalletCrypto.derive(network: network)
            let restored = try WalletCrypto.derive(network: network, recovery: generated.recovery)
            XCTAssertEqual(restored.address, generated.address)
            XCTAssertEqual(restored.privateKey, generated.privateKey)
            XCTAssertEqual(restored.secondaryPrivateKey, generated.secondaryPrivateKey)
        }
        XCTAssertEqual(try WalletCrypto.derive(network: .bitcoin, recovery: fixture).address, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
        XCTAssertThrowsError(try WalletCrypto.derive(network: .solana, recovery: "invalid words"))
        XCTAssertThrowsError(try WalletCrypto.derive(network: .monero, recovery: String(repeating: "0", count: 64)))
    }

    func testDeviceStoreBindsOwnershipAndMetadataAndExcludesBackup() throws {
        let device = UUID(), key = try VaultCrypto.random(32)
        // Test-only protection lets persistence and binding run without a biometric prompt.
        let store = try LocalWalletStore(directory: directory, deviceID: device,
            protect: { try VaultCrypto.seal($0, key: key, context: $1) },
            unprotect: { try VaultCrypto.open($0, key: key, context: $1) })
        let material = try WalletCrypto.derive(network: .solana, recovery: fixture)
        let metadata = material.metadata(network: .solana, deviceID: device)
        try store.save(material, metadata: metadata)
        XCTAssertTrue(store.contains(metadata))
        XCTAssertEqual(try store.reveal(metadata).privateKey, material.privateKey)
        XCTAssertThrowsError(try store.save(material, metadata: metadata))
        let url = directory.appendingPathComponent(metadata.id.uuidString + ".wallet")
        let original = try Data(contentsOf: url)
        let disk = String(decoding: original, as: UTF8.self)
        XCTAssertFalse(disk.contains(material.recovery)); XCTAssertFalse(disk.contains(material.privateKey))
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var modified = metadata; modified.ownerDeviceID = UUID()
        XCTAssertFalse(store.contains(modified)); XCTAssertThrowsError(try store.reveal(modified))
        modified = metadata; modified.address = "another address"
        XCTAssertThrowsError(try store.reveal(modified))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var publicFields = try XCTUnwrap(object["metadata"] as? [String: Any])
        publicFields["address"] = modified.address; object["metadata"] = publicFields
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try store.reveal(modified)) // altered AAD cannot decrypt
        try original.write(to: url)
        try store.remove(metadata); XCTAssertFalse(store.contains(metadata))
    }

    func testProtectionFailureDoesNotWriteSecretOrPublicRecord() throws {
        let device = UUID()
        let store = try LocalWalletStore(directory: directory, deviceID: device,
            protect: { _, _ in throw ProximusError.unavailable("Authentication canceled") },
            unprotect: { _, _ in throw ProximusError.authentication })
        let material = try WalletCrypto.derive(network: .evm, recovery: fixture)
        XCTAssertThrowsError(try store.save(material, metadata: material.metadata(network: .evm, deviceID: device)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    @MainActor func testSnapshotsBackupsAndPairingContainOnlyWalletPublicData() throws {
        let device = UUID(), material = try WalletCrypto.derive(network: .bitcoin, recovery: fixture)
        let metadata = material.metadata(network: .bitcoin, deviceID: device)
        let item = VaultItem(kind: .wallet, title: "Bitcoin", wallet: metadata)
        let repo = try VaultRepository(directory: directory)
        let (state, key) = try repo.create(passphrase: "test vault passphrase", recovery: VaultCrypto.random(32), contents: VaultContents(items: [item]))
        let contents = try repo.contents(state: state, key: key)
        let publicJSON = String(decoding: try Encoding.encode(contents), as: UTF8.self)
        XCTAssertTrue(publicJSON.contains(metadata.address))
        for secret in [material.recovery, material.privateKey, "\"privateKey\"", "\"recovery\""] { XCTAssertFalse(publicJSON.contains(secret)) }
        let backup = try Encoding.decode(VaultBackup.self, from: repo.backup())
        let snapshot = try Encoding.decode(EncryptedSnapshot.self, from: backup.snapshot)
        XCTAssertEqual(try snapshot.decrypt(key: key, vaultID: state.header.vaultID), contents)
        let bundle = PairingBundle(header: state.header, snapshot: try repo.object(state.head), vaultKey: key, recovery: nil, relay: nil)
        try bundle.validate()
        let paired = try Encoding.decode(EncryptedSnapshot.self, from: bundle.snapshot).decrypt(key: bundle.vaultKey, vaultID: bundle.header.vaultID)
        XCTAssertEqual(paired.items[0].wallet, metadata)
        XCTAssertTrue(paired.items[0].password.isEmpty)
        var invalid = item; invalid.password = material.privateKey
        XCTAssertThrowsError(try invalid.validated())
        // Existing records decode without the newly optional wallet field.
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Encoding.encode(VaultItem(title: "Existing"))) as? [String: Any])
        old.removeValue(forKey: "wallet")
        XCTAssertNil(try Encoding.decode(VaultItem.self, from: JSONSerialization.data(withJSONObject: old)).wallet)
    }
}
