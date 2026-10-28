import XCTest
@testable import ProximusKit

final class BrowserProtocolTests: XCTestCase {
    private let origin = "https://accounts.example.com"

    func testRejectsNoncanonicalAndUnsafeOrigins() throws {
        for value in ["http://example.com", "https://example.com/", "https://EXAMPLE.com", "https://example.com:443", "https://example.com.", "https://example.com/path", "https://user@example.com", "https://example.com?x=1", "https://example.com#x", "https://éxample.com", "https://example.com\n", "example.com"] {
            XCTAssertThrowsError(try BrowserRequest(action: .fill, origin: value), value)
        }
        XCTAssertEqual(try BrowserRequest(action: .fill, origin: "https://example.com:8443").origin, "https://example.com:8443")
        XCTAssertNoThrow(try BrowserRequest(action: .fill, origin: "https://xn--xample-9ua.com"))
    }

    func testStrictMessagesAndSizeLimits() throws {
        let request = try BrowserRequest(action: .fill, origin: origin)
        XCTAssertEqual(try BrowserRequest.decode(JSONEncoder().encode(request)), request)
        var fields: [String: Any] = ["version": 1, "id": request.id, "action": "fill", "origin": origin]
        for (key, value) in [("version", 2 as Any), ("id", "not-a-request" as Any), ("action", "export" as Any), ("unexpected", true as Any), ("login", ["username": "x", "password": "secret", "title": "Site"] as Any)] {
            var changed = fields; changed[key] = value
            XCTAssertThrowsError(try BrowserRequest.decode(JSONSerialization.data(withJSONObject: changed)))
        }
        fields["action"] = "save"
        XCTAssertThrowsError(try BrowserRequest.decode(JSONSerialization.data(withJSONObject: fields)))
        XCTAssertThrowsError(try BrowserRequest.decode(Data(repeating: 32, count: BrowserProtocol.maximumMessage + 1)))
        let oversized = BrowserSaveLogin(title: "Site", username: "", password: String(repeating: "x", count: 4097))
        XCTAssertThrowsError(try BrowserRequest(action: .save, origin: origin, login: oversized))
    }

    func testFramesRejectAllocationAbuseAndRoundTripResponse() throws {
        for size: UInt32 in [0, UInt32(BrowserProtocol.maximumMessage + 1), UInt32.max] {
            var size = size
            XCTAssertThrowsError(try BrowserMessageFrame.length(withUnsafeBytes(of: &size) { Data($0) }))
        }
        XCTAssertThrowsError(try BrowserMessageFrame.length(Data([1, 2, 3])))
        let request = try BrowserRequest(action: .fill, origin: origin)
        let frame = try BrowserMessageFrame.encode(BrowserResponse(request: request, status: "filled", login: BrowserLogin(username: "test", password: "test secret")))
        XCTAssertEqual(try BrowserMessageFrame.length(frame.prefix(4)), frame.count - 4)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.dropFirst(4)) as? [String: Any])
        XCTAssertEqual(response["origin"] as? String, origin)
        XCTAssertEqual(response["id"] as? String, request.id)
    }

    func testSaveCannotOverwriteOtherSiteOrSecretType() throws {
        let login = BrowserSaveLogin(title: "Account", username: "user@example.com", password: "replacement secret")
        let request = try BrowserRequest(action: .save, origin: origin, login: login)
        for item in [VaultItem(title: "Other", website: "https://example.com", password: "old"), VaultItem(kind: .note, title: "Note", website: origin, password: "old")] {
            XCTAssertThrowsError(try request.savedItem(login, replacing: item))
        }
        let item = VaultItem(title: "Account", website: origin, password: "old", notes: "Keep this note", collection: "Personal", favorite: true)
        let changed = try request.savedItem(login, replacing: item)
        XCTAssertEqual(changed.id, item.id)
        XCTAssertEqual(changed.notes, item.notes)
        XCTAssertTrue(changed.favorite)
        XCTAssertEqual(changed.password, login.password)
    }

    @MainActor func testFillAuthenticatesAndNeverReleasesWrongSiteOrOtherSecretTypes() async throws {
        let repository = try VaultRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("browser-protocol-" + UUID().uuidString))
        var prompts = 0
        let session = try VaultSession(repository: repository, deviceID: UUID(), authenticateCredentialAccess: { _ in prompts += 1 })
        defer { session.lock(); try? FileManager.default.removeItem(at: repository.directory) }
        try await session.create(passphrase: "browser fixture vault password", recovery: VaultCrypto.recoveryKey(), name: "Fixture", deviceName: "Test", rememberRecovery: false)
        let item = VaultItem(title: "Site", username: "test@example.com", website: origin, password: "fixture password", notes: "never release notes")
        try await session.save(item)
        let current = try XCTUnwrap(session.contents?.items.first)
        let wrong = try BrowserRequest(action: .fill, origin: "https://example.com")
        do { _ = try await session.browserCredential(for: wrong, item: current); XCTFail("Released to another origin") } catch { }
        XCTAssertEqual(prompts, 0)
        let request = try BrowserRequest(action: .fill, origin: origin)
        let first = try await session.browserCredential(for: request, item: current)
        XCTAssertEqual(first, BrowserLogin(username: item.username, password: item.password))
        _ = try await session.browserCredential(for: request, item: current)
        XCTAssertEqual(prompts, 2)
        session.lock()
        do { _ = try await session.browserCredential(for: request, item: current); XCTFail("Released while locked") } catch { }
    }

    @MainActor func testAnotherWindowChangingItemDuringAuthenticationPreventsRelease() async throws {
        let repository = try VaultRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("browser-conflict-" + UUID().uuidString))
        let other = try VaultSession(repository: repository, deviceID: UUID(), authenticateCredentialAccess: { _ in })
        let recovery = try VaultCrypto.recoveryKey(), password = "browser fixture vault password"
        try await other.create(passphrase: password, recovery: recovery, name: "Fixture", deviceName: "Test", rememberRecovery: false)
        try await other.save(VaultItem(title: "Site", website: origin, password: "fixture password"))
        let item = try XCTUnwrap(other.contents?.items.first)
        let session = try VaultSession(repository: repository, deviceID: UUID(), authenticateCredentialAccess: { _ in try await other.delete(item) })
        defer { session.lock(); other.lock(); try? FileManager.default.removeItem(at: repository.directory) }
        try await session.unlock(passphrase: password, recovery: recovery)
        let request = try BrowserRequest(action: .fill, origin: origin)
        do { _ = try await session.browserCredential(for: request, item: item); XCTFail("Released a deleted record") } catch { }
    }
}
