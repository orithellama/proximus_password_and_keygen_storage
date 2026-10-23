import Foundation
import CryptoKit
import LocalAuthentication
import AuthenticationServices

/// Minimal, deterministic CBOR for WebAuthn ES256 COSE public keys and none attestation.
public enum WebAuthnEncoding {
    private static func length(_ major: UInt8, _ count: Int) -> Data {
        if count < 24 { return Data([major << 5 | UInt8(count)]) }
        if count < 256 { return Data([major << 5 | 24, UInt8(count)]) }
        return Data([major << 5 | 25, UInt8((count >> 8) & 255), UInt8(count & 255)])
    }
    public static func bytes(_ value: Data) -> Data { length(2, value.count) + value }
    public static func text(_ value: String) -> Data { length(3, value.utf8.count) + Data(value.utf8) }
    public static func cose(publicKey: Data) throws -> Data {
        guard publicKey.count == 65, publicKey.first == 4 else { throw ProximusError.invalid("Invalid P-256 public key.") }
        // {1: 2, 3: -7, -1: 1, -2: x, -3: y}
        return Data([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21]) + bytes(publicKey.subdata(in: 1..<33)) + Data([0x22]) + bytes(publicKey.subdata(in: 33..<65))
    }
    public static func authenticatorData(relyingParty: String, credentialID: Data? = nil, publicKey: Data? = nil) throws -> Data {
        _ = try DomainPolicy.relyingParty(relyingParty)
        var result = Data(SHA256.hash(data: Data(relyingParty.utf8)))
        // UP + UV, AT for registration. BE/BS unset: these keys cannot leave this device.
        result.append(credentialID == nil ? 0x05 : 0x45)
        result.append(Data(repeating: 0, count: 4)) // A zero counter explicitly means unsupported.
        if let credentialID, let publicKey {
            guard credentialID.count == 32 else { throw ProximusError.invalid("Invalid credential ID.") }
            result.append(Data(repeating: 0, count: 16)) // Anonymous AAGUID.
            result.append(contentsOf: [0, 32]); result.append(credentialID); result.append(try cose(publicKey: publicKey))
        } else if credentialID != nil || publicKey != nil { throw ProximusError.invalid("Incomplete attested credential data.") }
        return result
    }
    public static func attestation(authenticatorData: Data) -> Data {
        Data([0xa3]) + text("fmt") + text("none") + text("attStmt") + Data([0xa0]) + text("authData") + bytes(authenticatorData)
    }
}

public enum PasskeySigner {
    private static func account(_ id: Data) -> String { "passkey/" + id.base64URLEncoded }
    public static func hasKey(_ id: Data) -> Bool { (try? DeviceKeychain.read(account(id))) != nil }
    public static func remove(_ id: Data) throws { try DeviceKeychain.delete(account(id)) }
    public static func register(relyingParty: String, username: String, userHandle: Data, clientDataHash: Data, deviceID: UUID) throws -> (VaultItem, ASPasskeyRegistrationCredential) {
        let rp = try DomainPolicy.relyingParty(relyingParty)
        guard clientDataHash.count == 32, (1...64).contains(userHandle.count), !username.isEmpty else { throw ProximusError.invalid("Invalid passkey registration request.") }
        guard SecureEnclave.isAvailable else { throw ProximusError.unavailable("Creating hardware-bound passkeys requires a device with Secure Enclave. There is no software key fallback.") }
        let auth = LAContext(); auth.localizedReason = "Create a passkey for " + rp; auth.touchIDAuthenticationAllowableReuseDuration = 0
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: HardwareUnlock.accessControl(), authenticationContext: auth)
        // A real private-key operation enforces the hardware user-presence policy before UV is asserted.
        _ = try key.signature(for: clientDataHash)
        let id = try VaultCrypto.random(32)
        let data = try WebAuthnEncoding.authenticatorData(relyingParty: rp, credentialID: id, publicKey: key.publicKey.x963Representation)
        let item = VaultItem(kind: .passkey, title: rp, username: username, website: "https://" + rp, passkey: PasskeyMetadata(credentialID: id, userHandle: userHandle, relyingParty: rp, deviceID: deviceID))
        try DeviceKeychain.write(key.dataRepresentation, account: account(id))
        return (item, ASPasskeyRegistrationCredential(relyingParty: rp, clientDataHash: clientDataHash, credentialID: id, attestationObject: WebAuthnEncoding.attestation(authenticatorData: data)))
    }
    public static func assert(item: VaultItem, relyingParty: String, clientDataHash: Data, allowedCredentials: [Data], deviceID: UUID) throws -> ASPasskeyAssertionCredential {
        let rp = try DomainPolicy.relyingParty(relyingParty)
        guard clientDataHash.count == 32, item.kind == .passkey, let metadata = item.passkey, metadata.relyingParty == rp, metadata.deviceID == deviceID, allowedCredentials.isEmpty || allowedCredentials.contains(metadata.credentialID), let reference = try DeviceKeychain.read(account(metadata.credentialID)) else {
            throw ProximusError.invalid("This passkey does not match the requesting website or is held on another device.")
        }
        let auth = LAContext(); auth.localizedReason = "Sign in to " + rp; auth.touchIDAuthenticationAllowableReuseDuration = 0
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: reference, authenticationContext: auth)
        let data = try WebAuthnEncoding.authenticatorData(relyingParty: rp)
        let signature = try key.signature(for: data + clientDataHash).derRepresentation
        return ASPasskeyAssertionCredential(userHandle: metadata.userHandle, relyingParty: rp, signature: signature, clientDataHash: clientDataHash, authenticatorData: data, credentialID: metadata.credentialID)
    }
}

public enum CredentialIndex {
    /// Only called after opt-in. Apple's credential index contains usernames and domains, never secrets.
    public static func replace(items: [VaultItem], deviceID: UUID) async throws {
        let identities: [any ASCredentialIdentity] = items.compactMap { item in
            if item.kind == .password, let origin = try? DomainPolicy.origin(item.website) {
                return ASPasswordCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: origin, type: .URL), user: item.username, recordIdentifier: item.id.uuidString)
            }
            if let passkey = item.passkey, passkey.deviceID == deviceID, PasskeySigner.hasKey(passkey.credentialID) {
                return ASPasskeyCredentialIdentity(relyingPartyIdentifier: passkey.relyingParty, userName: item.username, credentialID: passkey.credentialID, userHandle: passkey.userHandle, recordIdentifier: item.id.uuidString)
            }
            return nil
        }
        try await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
    }
    public static func clear() async throws { try await ASCredentialIdentityStore.shared.removeAllCredentialIdentities() }
}
