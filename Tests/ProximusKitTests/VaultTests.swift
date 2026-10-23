import XCTest
import CryptoKit
@testable import ProximusKit

final class VaultTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func repository(_ name: String = "a") throws -> VaultRepository { try VaultRepository(directory: directory.appendingPathComponent(name)) }

    func testVaultRecoveryBackupAndConcurrentWriteRejection() throws {
        let repo = try repository(), recovery = try VaultCrypto.random(32)
        let item = VaultItem(title: "Example", username: "alice", website: "https://example.com", password: "random-secret")
        let (state, key) = try repo.create(passphrase: "seven randomly selected words belong in this passphrase", recovery: recovery, contents: VaultContents(items: [item]))
        let disk = try repo.object(state.head)
        XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("random-secret"))
        let (_, decoded, recovered) = try repo.unlock(passphrase: "seven randomly selected words belong in this passphrase", recovery: recovery)
        XCTAssertEqual(recovered, key); XCTAssertEqual(decoded.items.first?.password, item.password)
        XCTAssertThrowsError(try repo.unlock(passphrase: "the wrong passphrase", recovery: recovery))
        XCTAssertThrowsError(try repo.unlock(passphrase: "seven randomly selected words belong in this passphrase", recovery: VaultCrypto.random(32)))
        var changed = decoded; changed.items[0].password = "a different secret"
        let next = try repo.save(changed, key: key, expected: state)
        XCTAssertThrowsError(try repo.save(decoded, key: key, expected: state)) { XCTAssertEqual($0 as? ProximusError, .conflict) }
        XCTAssertEqual(try repo.state(), next)
        let backup = try repo.backup(), restored = try repository("b")
        let importedKey = try restored.restore(backup, passphrase: "seven randomly selected words belong in this passphrase", recovery: recovery)
        XCTAssertEqual(importedKey, key)
        XCTAssertEqual(try restored.contents(state: restored.state(), key: key), changed)
        XCTAssertThrowsError(try restored.restore(backup, passphrase: "seven randomly selected words belong in this passphrase", recovery: recovery))
    }

    func testSnapshotBindsVaultParentsRevisionAndCiphertext() throws {
        let repo = try repository()
        let (state, key) = try repo.create(passphrase: "a sufficiently long passphrase", recovery: VaultCrypto.random(32), contents: VaultContents())
        let original = try Encoding.decode(EncryptedSnapshot.self, from: repo.object(state.head))
        for mutation in 0..<4 {
            var snapshot = original
            switch mutation {
            case 0: snapshot.header.vaultID = UUID()
            case 1: snapshot.header.revision += 1
            case 2: snapshot.header.parents = [String(repeating: "a", count: 64)]
            default: snapshot.ciphertext[12] ^= 1
            }
            XCTAssertThrowsError(try snapshot.decrypt(key: key, vaultID: state.header.vaultID))
        }
        XCTAssertThrowsError(try repo.object("../state.json"))
    }

    func testExplicitMergePreservesBothSecrets() throws {
        let a = try repository(), b = try repository("b")
        let (state, key) = try a.create(passphrase: "a sufficiently long passphrase", recovery: VaultCrypto.random(32), contents: VaultContents(items: [VaultItem(title: "Account", website: "example.com", password: "initial")]))
        try b.install(header: state.header, snapshot: a.object(state.head), key: key)
        var first = try a.contents(state: state, key: key), second = first
        first.items[0].password = "from a"; second.items[0].password = "from b"
        let local = try a.save(first, key: key, expected: state), remote = try b.save(second, key: key, expected: state)
        _ = try a.storeObject(b.object(remote.head))
        let merged = try a.merge(local: local, remote: remote.head, key: key)
        let contents = try a.contents(state: merged, key: key)
        XCTAssertEqual(Set(contents.items.map(\.password)), Set(["from a", "from b"]))
        XCTAssertEqual(Set(contents.items.map(\.id)).count, 2)
        let snapshot = try Encoding.decode(EncryptedSnapshot.self, from: a.object(merged.head))
        XCTAssertEqual(Set(snapshot.header.parents), Set([local.head, remote.head]))
    }

    func testDomainPolicyRejectsPhishingAndInsecureDestinations() throws {
        XCTAssertTrue(DomainPolicy.matches(saved: "https://EXAMPLE.com/login", requested: "example.com"))
        for url in ["https://example.com.evil.org", "https://login.example.com", "https://example.com:444", "http://example.com", "https://example.com@evil.org", "https://example.com\\@evil.org", "https://example.com."] {
            XCTAssertFalse(DomainPolicy.matches(saved: "example.com", requested: url), url)
        }
        XCTAssertThrowsError(try DomainPolicy.relyingParty("https://example.com"))
        XCTAssertThrowsError(try DomainPolicy.relyingParty("localhost"))
        XCTAssertTrue(DomainPolicy.passwordNotice(destination: "example.com").contains("cannot guarantee"))
    }

    func testPasswordGeneratorAndSizeLimits() throws {
        for length in [12, 24, 128] {
            let value = try VaultCrypto.password(length: length, symbols: false)
            XCTAssertEqual(value.count, length)
            XCTAssertTrue(value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
        XCTAssertNotEqual(try VaultCrypto.password(), try VaultCrypto.password())
        XCTAssertThrowsError(try VaultCrypto.password(length: 11))
        XCTAssertThrowsError(try VaultCrypto.password(length: 129))
        XCTAssertThrowsError(try VaultItem(title: "").validated())
        XCTAssertThrowsError(try VaultCrypto.open(Data(repeating: 0, count: 29), key: Data(repeating: 0, count: 32), context: Data("test".utf8)))
    }

    func testPairingAuthenticatesTranscriptAndPhase() throws {
        let host = P256.KeyAgreement.PrivateKey(), client = P256.KeyAgreement.PrivateKey()
        let invite = PairingInvitation(session: UUID(), hostPublicKey: host.publicKey.x963Representation, expires: Date().addingTimeInterval(120))
        let parsed = try PairingInvitation.parse(invite.link())
        let hostKey = try PairingCrypto.key(privateKey: host, peer: client.publicKey.x963Representation, invitation: parsed, clientPublicKey: client.publicKey.x963Representation)
        let clientKey = try PairingCrypto.key(privateKey: client, peer: parsed.hostPublicKey, invitation: parsed, clientPublicKey: client.publicKey.x963Representation)
        XCTAssertEqual(hostKey, clientKey); XCTAssertEqual(PairingCrypto.code(hostKey), PairingCrypto.code(clientKey))
        let message = try VaultCrypto.seal(Data("private vault".utf8), key: hostKey, context: PairingCrypto.context("bundle", invitation: parsed))
        XCTAssertEqual(try VaultCrypto.open(message, key: clientKey, context: PairingCrypto.context("bundle", invitation: parsed)), Data("private vault".utf8))
        XCTAssertThrowsError(try VaultCrypto.open(message, key: clientKey, context: PairingCrypto.context("hello", invitation: parsed)))
        let attacker = P256.KeyAgreement.PrivateKey()
        let wrong = try PairingCrypto.key(privateKey: attacker, peer: parsed.hostPublicKey, invitation: parsed, clientPublicKey: attacker.publicKey.x963Representation)
        XCTAssertThrowsError(try VaultCrypto.open(message, key: wrong, context: PairingCrypto.context("bundle", invitation: parsed)))
        XCTAssertThrowsError(try PairingInvitation.parse(invite.link(), now: Date().addingTimeInterval(181)))
    }

    func testPasskeyEncodingAndSignatureBindRelyingParty() throws {
        let key = P256.Signing.PrivateKey(), id = try VaultCrypto.random(32), challenge = try VaultCrypto.random(32)
        let registration = try WebAuthnEncoding.authenticatorData(relyingParty: "example.com", credentialID: id, publicKey: key.publicKey.x963Representation)
        XCTAssertEqual(registration.prefix(32), Data(SHA256.hash(data: Data("example.com".utf8)))); XCTAssertEqual(registration[32], 0x45)
        XCTAssertEqual(registration.subdata(in: 53..<55), Data([0, 32])); XCTAssertEqual(registration.subdata(in: 55..<87), id)
        let assertion = try WebAuthnEncoding.authenticatorData(relyingParty: "example.com")
        XCTAssertEqual(assertion.count, 37); XCTAssertEqual(assertion[32], 0x05)
        let signature = try key.signature(for: assertion + challenge)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: assertion + challenge))
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: try WebAuthnEncoding.authenticatorData(relyingParty: "evil.example") + challenge))
    }

    func testCSVImportPreservesQuotedSecretsAndRejectsPartialFiles() throws {
        let source = "name,url,username,password,notes\r\nExample,https://example.com,alice,\"a,b\"\"c\",\"first\nsecond\"\r\n"
        let items = try PasswordCSV.parse(Data(source.utf8))
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].password, "a,b\"c"); XCTAssertEqual(items[0].notes, "first\nsecond")
        for invalid in ["name,password\nAccount,\"unterminated", "name,password\nAccount,x,extra", "password,password\nx,y", "password,otpauth\nx,otpauth://secret"] {
            XCTAssertThrowsError(try PasswordCSV.parse(Data(invalid.utf8)))
        }
    }
}
