import Foundation
import CryptoKit
import LocalAuthentication

/// An independent Secure Enclave signing identity, separate from the shared vault key.
public struct ApprovalIdentity: Codable, Equatable, Identifiable, Sendable {
    public let vaultID: UUID
    public let deviceID: UUID
    public let name: String
    public let publicKey: Data
    public var id: UUID { deviceID }
    public var fingerprint: String { VaultCrypto.digest(publicKey) }
    public var code: String { get throws { "proximus-approval-device:" + (try Encoding.encode(self)).base64URLEncoded } }
    public static func decode(_ code: String) throws -> Self {
        let prefix = "proximus-approval-device:"
        guard code.hasPrefix(prefix), code.utf8.count < 4096, let data = Data(base64URL: String(code.dropFirst(prefix.count))) else { throw ProximusError.invalid("Paste or scan a Proximus approval device code.") }
        let identity = try Encoding.decode(Self.self, from: data); try identity.validate(); return identity
    }
    func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 128, !name.contains(where: { $0.isNewline }), publicKey.count == 65 else { throw ProximusError.authentication }
        _ = try P256.Signing.PublicKey(x963Representation: publicKey)
    }
}

public struct TransferApprovalRequest: Codable, Sendable {
    public let plan: TransferPlan
    public let requester: ApprovalIdentity
    let signature: Data
    public var code: String { get throws { "proximus-approve-transfer:" + (try Encoding.encode(self)).base64URLEncoded } }
    public static func decode(_ code: String) throws -> Self {
        let prefix = "proximus-approve-transfer:"
        guard code.hasPrefix(prefix), code.utf8.count <= 3 * 1024 * 1024, let data = Data(base64URL: String(code.dropFirst(prefix.count))) else { throw ProximusError.invalid("Open a Proximus transfer approval request.") }
        return try Encoding.decode(Self.self, from: data)
    }
    func validate(peer: ApprovalIdentity, deviceID: UUID, now: Date = Date()) throws {
        try plan.validate(now: now); try requester.validate()
        guard requester == peer, peer.vaultID == plan.vaultID, peer.deviceID == plan.wallet.ownerDeviceID, peer.deviceID != deviceID,
              try P256.Signing.PublicKey(x963Representation: peer.publicKey).isValidSignature(P256.Signing.ECDSASignature(derRepresentation: signature), for: ApprovalKeys.message(plan, domain: "request")) else { throw ProximusError.authentication }
    }
}

public struct TransferApproval: Codable, Sendable {
    public let requestID: UUID
    public let planDigest: String
    public let deviceID: UUID
    let signature: Data
    public var code: String { get throws { "proximus-transfer-approved:" + (try Encoding.encode(self)).base64URLEncoded } }
    public static func decode(_ code: String) throws -> Self {
        let prefix = "proximus-transfer-approved:"
        guard code.hasPrefix(prefix), code.utf8.count <= 4096, let data = Data(base64URL: String(code.dropFirst(prefix.count))) else { throw ProximusError.invalid("Paste or scan the approval returned by your other device.") }
        return try Encoding.decode(Self.self, from: data)
    }
    public func validate(plan: TransferPlan, peer: ApprovalIdentity, now: Date = Date()) throws {
        try plan.validate(now: now); try peer.validate()
        guard requestID == plan.id, planDigest == (try plan.fingerprint), deviceID == peer.deviceID,
              peer.deviceID != plan.wallet.ownerDeviceID, peer.vaultID == plan.vaultID,
              try P256.Signing.PublicKey(x963Representation: peer.publicKey).isValidSignature(P256.Signing.ECDSASignature(derRepresentation: signature), for: ApprovalKeys.message(plan, domain: "approval")) else { throw ProximusError.authentication }
    }
}

enum ApprovalKeys {
    private static func account(_ vault: UUID) -> String { "approval-identity/" + vault.uuidString }
    static func message(_ plan: TransferPlan, domain: String) throws -> Data { Data(("proximus/v1/transfer-" + domain + "/").utf8) + (try Encoding.encode(plan)) }
    private static func key(vault: UUID, reason: String) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else { throw ProximusError.unavailable("Transfer approval requires Secure Enclave and a device passcode.") }
        let auth = LAContext(); auth.localizedReason = reason; auth.touchIDAuthenticationAllowableReuseDuration = 0
        if let data = try DeviceKeychain.read(account(vault)) { return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data, authenticationContext: auth) }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: HardwareUnlock.accessControl(), authenticationContext: auth)
        _ = try key.signature(for: VaultCrypto.random(32))
        try DeviceKeychain.write(key.dataRepresentation, account: account(vault)); return key
    }
    static func identity(vault: UUID, device: UUID, name: String) throws -> ApprovalIdentity {
        let key = try key(vault: vault, reason: "Create this device’s transfer approval identity")
        let identity = ApprovalIdentity(vaultID: vault, deviceID: device, name: name, publicKey: key.publicKey.x963Representation)
        try identity.validate(); return identity
    }
    static func sign(_ data: Data, vault: UUID, reason: String) throws -> Data { try key(vault: vault, reason: reason).signature(for: data).derRepresentation }
    static func authorize(vault: UUID, reason: String) throws { _ = try sign(VaultCrypto.random(32), vault: vault, reason: reason) }
}

public enum ApprovalStore {
    private static func account(_ vault: UUID) -> String { "approval-peers/" + vault.uuidString }
    public static func peers(vault: UUID) throws -> [ApprovalIdentity] {
        guard let data = try DeviceKeychain.read(account(vault)) else { return [] }
        let values = try Encoding.decode([ApprovalIdentity].self, from: data)
        guard values.count <= 100, Set(values.map(\.deviceID)).count == values.count else { throw ProximusError.authentication }
        for value in values { try value.validate(); guard value.vaultID == vault else { throw ProximusError.authentication } }
        return values
    }
    static func trust(_ identity: ApprovalIdentity) throws {
        try identity.validate()
        var peers = try peers(vault: identity.vaultID); peers.removeAll { $0.deviceID == identity.deviceID }; peers.append(identity)
        guard peers.count <= 100 else { throw ProximusError.invalid("Too many approval devices.") }
        try DeviceKeychain.write(Encoding.encode(peers), account: account(identity.vaultID))
    }
    public static func policy(wallet: UUID) throws -> ApprovalIdentity? {
        guard let data = try DeviceKeychain.read("approval-policy/" + wallet.uuidString) else { return nil }
        let peer = try Encoding.decode(ApprovalIdentity.self, from: data); try peer.validate(); return peer
    }
    static func setPolicy(_ peer: ApprovalIdentity?, wallet: UUID) throws {
        let account = "approval-policy/" + wallet.uuidString
        if let peer { try DeviceKeychain.write(Encoding.encode(peer), account: account) } else { try DeviceKeychain.delete(account) }
    }
    static func verify(_ response: TransferApproval?, plan: TransferPlan) throws {
        if let peer = try policy(wallet: plan.wallet.id) {
            guard let response, try peers(vault: plan.vaultID).contains(peer) else { throw ProximusError.invalid("Approval from the configured paired device is required.") }
            try response.validate(plan: plan, peer: peer)
        }
    }
}
