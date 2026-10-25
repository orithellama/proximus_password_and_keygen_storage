import XCTest
@testable import ProximusKit

final class DeviceAvailabilityTests: XCTestCase {
    func testAvailabilityChecksDoNotCreateOrModifyKeychainItems() throws {
        // Isolated account: never query or alter a real vault's unlock material.
        let account = "availability-test/" + UUID().uuidString
        XCTAssertFalse(DeviceKeychain.contains(account))
        let value = try VaultCrypto.random(32)
        try DeviceKeychain.write(value, account: account)
        defer { try? DeviceKeychain.delete(account) }
        XCTAssertTrue(DeviceKeychain.contains(account))
        XCTAssertTrue(DeviceKeychain.contains(account))
        XCTAssertEqual(try DeviceKeychain.read(account), value)
        try DeviceKeychain.delete(account)
        XCTAssertFalse(DeviceKeychain.contains(account))
    }

    func testUnconfiguredVaultDoesNotOfferConfiguredUnlockOrBackup() {
        let vault = UUID()
        XCTAssertFalse(HardwareUnlock.isEnabled(vault))
        XCTAssertFalse(RecoveryBackupSession.isConfigured(vault))
    }
}
