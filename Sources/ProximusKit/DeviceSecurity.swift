import Foundation
import Security
import CryptoKit
import LocalAuthentication

public enum AppEnvironment {
    public static var isStandaloneMac: Bool {
        #if os(macOS)
        let team = Bundle.main.object(forInfoDictionaryKey: "ProximusSigningTeam") as? String ?? ""
        return team.isEmpty || team.contains("$(")
        #else
        return false
        #endif
    }
    public static var appGroup: String? { Bundle.main.object(forInfoDictionaryKey: "ProximusAppGroup") as? String }
    public static var keychainGroup: String? { Bundle.main.object(forInfoDictionaryKey: "ProximusKeychainGroup") as? String }
    public static func repository() throws -> VaultRepository {
        if isStandaloneMac {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return try VaultRepository(directory: root.appendingPathComponent((Bundle.main.bundleIdentifier ?? "org.proximus.passwords") + ".local/Vault", isDirectory: true))
        }
        guard let group = appGroup, !group.contains("$("), let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ProximusError.unavailable("The shared vault container is unavailable. Build and sign the app and AutoFill extension with the same App Group.")
        }
        return try VaultRepository(directory: root.appendingPathComponent("Vault", isDirectory: true))
    }
    public static func deviceID() throws -> UUID {
        if isStandaloneMac {
            if let value = UserDefaults.standard.string(forKey: "local-device-id"), let id = UUID(uuidString: value) { return id }
            let id = UUID(); UserDefaults.standard.set(id.uuidString, forKey: "local-device-id"); return id
        }
        if let saved = try DeviceKeychain.read("device-id"), let string = String(data: saved, encoding: .utf8), let id = UUID(uuidString: string) { return id }
        let id = UUID(); try DeviceKeychain.write(Data(id.uuidString.utf8), account: "device-id"); return id
    }
}

public enum DeviceKeychain {
    private static func query(_ account: String) -> [String: Any] {
        #if os(macOS)
        if AppEnvironment.isStandaloneMac {
            return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "org.proximus.passwords") + ".local", kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: false]
        }
        #endif
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.proximus.passwords", kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
        if let group = AppEnvironment.keychainGroup, !group.isEmpty, !group.contains("$(") { query[kSecAttrAccessGroup as String] = group }
        return query
    }
    public static func read(_ account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return result as? Data
    }
    public static func write(_ data: Data, account: String) throws {
        var attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        #if os(macOS)
        if AppEnvironment.isStandaloneMac { attributes.removeValue(forKey: kSecAttrAccessible as String) }
        #endif
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query(account).merging(attributes) { _, new in new }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    public static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> ProximusError {
        .unavailable("Device Keychain is unavailable (\(status)). Check signing entitlements and unlock this device.")
    }
}

private struct HardwareEnvelope: Codable {
    var keyReference: Data
    var ephemeralPublicKey: Data
    var ciphertext: Data
}

/// Wallet secrets use a separate Secure Enclave key and domain from vault unlock.
enum WalletProtection {
    static func seal(_ plain: Data, context: Data) throws -> Data {
        guard SecureEnclave.isAvailable else { throw ProximusError.unavailable("Wallet keys require a device with Secure Enclave and a device passcode.") }
        let hardware = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: HardwareUnlock.accessControl())
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: hardware.publicKey)
        var wrapping = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: Data("wallet-wrap".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        defer { wrapping.resetBytes(in: 0..<wrapping.count) }
        return try Encoding.encode(HardwareEnvelope(keyReference: hardware.dataRepresentation, ephemeralPublicKey: ephemeral.publicKey.x963Representation, ciphertext: VaultCrypto.seal(plain, key: wrapping, context: context)))
    }
    static func open(_ data: Data, context: Data) throws -> Data {
        let envelope = try Encoding.decode(HardwareEnvelope.self, from: data)
        let auth = LAContext()
        auth.localizedReason = "Show this wallet’s recovery phrase and private keys"
        auth.touchIDAuthenticationAllowableReuseDuration = 0
        let hardware = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.keyReference, authenticationContext: auth)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
        let secret = try hardware.sharedSecretFromKeyAgreement(with: ephemeral)
        var wrapping = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: Data("wallet-wrap".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        defer { wrapping.resetBytes(in: 0..<wrapping.count) }
        return try VaultCrypto.open(envelope.ciphertext, key: wrapping, context: context)
    }
}

public enum HardwareUnlock {
    public static var isAvailable: Bool { SecureEnclave.isAvailable }
    private static func account(_ vault: UUID) -> String { "hardware-unlock/" + vault.uuidString }
    private static func context(_ vault: UUID) -> Data { Data(("proximus/v1/device-unlock/" + vault.uuidString).utf8) }
    public static func isEnabled(_ vault: UUID) -> Bool { (try? DeviceKeychain.read(account(vault))) != nil }
    public static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error) else {
            throw ProximusError.unavailable("Set a device passcode before enabling hardware unlock.")
        }
        return control
    }
    public static func enable(vault: UUID, key: Data) throws {
        guard isAvailable else { throw ProximusError.unavailable("Secure Enclave is required for device unlock. Use your passphrase and recovery key on this device.") }
        let hardware = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: accessControl())
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: hardware.publicKey)
        let wrapping = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context(vault), sharedInfo: Data("wrap".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        let envelope = HardwareEnvelope(keyReference: hardware.dataRepresentation, ephemeralPublicKey: ephemeral.publicKey.x963Representation, ciphertext: try VaultCrypto.seal(key, key: wrapping, context: context(vault)))
        try DeviceKeychain.write(Encoding.encode(envelope), account: account(vault))
    }
    public static func unlock(vault: UUID) throws -> Data {
        guard let data = try DeviceKeychain.read(account(vault)) else { throw ProximusError.unavailable("Device unlock has not been enabled.") }
        let envelope = try Encoding.decode(HardwareEnvelope.self, from: data)
        let auth = LAContext(); auth.localizedReason = "Unlock your Proximus vault"; auth.touchIDAuthenticationAllowableReuseDuration = 0
        let hardware = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.keyReference, authenticationContext: auth)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
        let secret = try hardware.sharedSecretFromKeyAgreement(with: ephemeral)
        let wrapping = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context(vault), sharedInfo: Data("wrap".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        return try VaultCrypto.open(envelope.ciphertext, key: wrapping, context: context(vault))
    }
    public static func disable(vault: UUID) throws { try DeviceKeychain.delete(account(vault)) }
}
