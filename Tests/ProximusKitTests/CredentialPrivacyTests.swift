import XCTest
@testable import ProximusKit

final class CredentialPrivacyTests: XCTestCase {
    private let password = "private test vault password"

    func testEmailMaskDoesNotExposeDomainOrHiddenLength() {
        XCTAssertEqual(CredentialPrivacy.maskedEmail("jane@example.com"), "jane********")
        XCTAssertEqual(CredentialPrivacy.maskedEmail("jane@a.co"), "jane********")
        XCTAssertEqual(CredentialPrivacy.maskedEmail("é🙂ab@example.org"), "é🙂ab********")
        XCTAssertEqual(CredentialPrivacy.maskedEmail(""), "")
        XCTAssertEqual(CredentialPrivacy.maskedEmail("username"), "username")
        XCTAssertEqual(CredentialPrivacy.maskedEmail("a@b"), "a@b")
    }

    @MainActor private func fixture(authenticate: @escaping @MainActor (String) async throws -> Void) async throws -> (VaultSession, VaultItem, String) {
        let repository = try VaultRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("credential-privacy-test-" + UUID().uuidString))
        let session = try VaultSession(repository: repository, deviceID: UUID(), authenticateCredentialAccess: authenticate)
        let recovery = try VaultCrypto.recoveryKey()
        try await session.create(passphrase: password, recovery: recovery, name: "Test", deviceName: "Test", rememberRecovery: false)
        try await session.save(VaultItem(title: "Test account", username: "jane@example.com", password: "saved account secret"))
        return (session, try XCTUnwrap(session.contents?.items.first), recovery)
    }
    @MainActor private func cleanup(_ session: VaultSession) {
        session.lock()
        try? FileManager.default.removeItem(at: session.repository.directory)
    }

    @MainActor func testEveryActionAuthenticatesAndGrantsAreSingleUse() async throws {
        var prompts = 0
        let (session, item, _) = try await fixture { _ in prompts += 1 }
        defer { cleanup(session) }
        for purpose in ["Show password", "Copy password", "Edit saved item"] {
            let grant = try await session.authorizeCredentialAccess(item, reason: purpose)
            XCTAssertEqual(try session.consumeCredentialAccess(grant), item)
            XCTAssertThrowsError(try session.consumeCredentialAccess(grant))
        }
        XCTAssertEqual(prompts, 3)
        session.lock()
        do { _ = try await session.authorizeCredentialAccess(item, reason: "Show password"); XCTFail("Locked vault authorized access") } catch { }
        XCTAssertEqual(prompts, 3)
    }

    @MainActor func testDeniedAuthenticationNeverGrantsAccess() async throws {
        let (session, item, _) = try await fixture { _ in throw ProximusError.authentication }
        defer { cleanup(session) }
        do { _ = try await session.authorizeCredentialAccess(item, reason: "Show password"); XCTFail("Denied authentication authorized access") }
        catch { XCTAssertEqual(error as? ProximusError, .authentication) }
    }

    @MainActor func testVaultPasswordFallbackValidatesPasswordAndRecovery() async throws {
        var devicePrompts = 0
        let (session, item, recovery) = try await fixture { _ in devicePrompts += 1 }
        defer { cleanup(session) }
        for authorization in [CredentialAuthorization.vaultPassword("incorrect test vault password", recoveryKey: recovery), .vaultPassword(password, recoveryKey: try VaultCrypto.recoveryKey())] {
            do { _ = try await session.authorizeCredentialAccess(item, reason: "Show password", using: authorization); XCTFail("Incorrect recovery credentials authorized access") } catch { }
        }
        let grant = try await session.authorizeCredentialAccess(item, reason: "Show password", using: .vaultPassword(password, recoveryKey: recovery))
        XCTAssertEqual(try session.consumeCredentialAccess(grant).password, item.password)
        XCTAssertEqual(devicePrompts, 0)
    }

    @MainActor func testGrantIsInvalidAfterRelockEvenWhenSameVaultIsUnlocked() async throws {
        let (session, item, recovery) = try await fixture { _ in }
        defer { cleanup(session) }
        let grant = try await session.authorizeCredentialAccess(item, reason: "Show password")
        session.lock()
        try await session.unlock(passphrase: password, recovery: recovery)
        XCTAssertThrowsError(try session.consumeCredentialAccess(grant))
    }

    @MainActor func testChangedItemAndExpiredGrantAreRejectedAtUse() async throws {
        let (session, item, _) = try await fixture { _ in }
        defer { cleanup(session) }
        let grant = try await session.authorizeCredentialAccess(item, reason: "Show password")
        let expired = CredentialAccessGrant(id: grant.id, generation: grant.generation, item: grant.item, expires: .distantPast)
        XCTAssertThrowsError(try session.consumeCredentialAccess(expired))
        let second = try await session.authorizeCredentialAccess(item, reason: "Show password")
        var changed = item; changed.password = "replacement secret"
        try await session.save(changed)
        XCTAssertThrowsError(try session.consumeCredentialAccess(second))
    }

    @MainActor func testLockAndCancellationWhilePromptIsPendingRejectResult() async throws {
        for cancel in [false, true] {
            var resume: CheckedContinuation<Void, Never>?
            let prompted = expectation(description: "Authentication started")
            let (session, item, _) = try await fixture { _ in
                await withCheckedContinuation { resume = $0; prompted.fulfill() }
            }
            defer { cleanup(session) }
            let operation = Task { try await session.authorizeCredentialAccess(item, reason: "Show password") }
            await fulfillment(of: [prompted], timeout: 2)
            if cancel { operation.cancel() } else { session.lock() }
            resume?.resume()
            do { _ = try await operation.value; XCTFail("Stale or canceled authentication authorized access") } catch { }
        }
    }

    @MainActor func testItemChangedWhilePromptIsPendingRejectsResult() async throws {
        var resume: CheckedContinuation<Void, Never>?
        let prompted = expectation(description: "Authentication started")
        let (session, item, _) = try await fixture { _ in
            await withCheckedContinuation { resume = $0; prompted.fulfill() }
        }
        defer { cleanup(session) }
        let operation = Task { try await session.authorizeCredentialAccess(item, reason: "Show password") }
        await fulfillment(of: [prompted], timeout: 2)
        try await session.delete(item)
        resume?.resume()
        do { _ = try await operation.value; XCTFail("Deleted item was authorized") }
        catch { XCTAssertEqual(error as? ProximusError, .conflict) }
    }
}
