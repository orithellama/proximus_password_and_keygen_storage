import Foundation
import CryptoKit
import Network
import Combine

public struct PairingInvitation: Codable {
    public var version = 1
    public var session: UUID
    public var hostPublicKey: Data
    public var expires: Date
    public var service: String { "px-" + session.uuidString.lowercased() }
    public func link() throws -> String { "proximus://pair?data=" + (try Encoding.encode(self)).base64URLEncoded }
    public static func parse(_ link: String, now: Date = Date()) throws -> Self {
        guard link.utf8.count < 4096, let url = URLComponents(string: link), url.scheme == "proximus", url.host == "pair", let encoded = url.queryItems?.first(where: { $0.name == "data" })?.value, let data = Data(base64URL: encoded) else { throw ProximusError.invalid("This is not a Proximus pairing code.") }
        let invitation = try Encoding.decode(Self.self, from: data)
        guard invitation.version == 1, invitation.hostPublicKey.count == 65, invitation.expires > now, invitation.expires.timeIntervalSince(now) <= 180 else { throw ProximusError.invalid("This pairing code has expired. Generate a new code on your other device.") }
        _ = try P256.KeyAgreement.PublicKey(x963Representation: invitation.hostPublicKey)
        return invitation
    }
}

public struct PairingBundle: Codable {
    public var header: VaultHeader
    public var snapshot: Data
    public var vaultKey: Data
    public var recovery: Data?
    public var relay: RelayConfiguration?
    public init(header: VaultHeader, snapshot: Data, vaultKey: Data, recovery: Data?, relay: RelayConfiguration?) {
        self.header = header; self.snapshot = snapshot; self.vaultKey = vaultKey; self.recovery = recovery; self.relay = relay
    }
    public func validate() throws {
        try header.validate()
        guard vaultKey.count == 32, recovery == nil || recovery?.count == 32 else { throw ProximusError.authentication }
        _ = try Encoding.decode(EncryptedSnapshot.self, from: snapshot).decrypt(key: vaultKey, vaultID: header.vaultID)
        _ = try relay?.validated()
    }
}

public enum PairingCrypto {
    public static func key(privateKey: P256.KeyAgreement.PrivateKey, peer: Data, invitation: PairingInvitation, clientPublicKey: Data) throws -> Data {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer))
        return try secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: Encoding.encode(invitation))), sharedInfo: Data("proximus/v1/pairing".utf8) + clientPublicKey, outputByteCount: 32).withUnsafeBytes { Data($0) }
    }
    public static func code(_ key: Data) -> String {
        let bytes = Array(SHA256.hash(data: key + Data("confirmation".utf8)))
        let number = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%03d %03d", number / 1000, number % 1000)
    }
    public static func context(_ phase: String, invitation: PairingInvitation) -> Data { Data(("proximus/v1/pairing/" + invitation.session.uuidString + "/" + phase).utf8) }
}

private struct PairingHello: Codable { var publicKey: Data; var proof: Data }
private struct PairingPeer: Codable { var id: UUID; var name: String }

private final class FramedConnection {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }
    func send(_ data: Data) async throws {
        guard data.count <= VaultCrypto.maximumPayload * 2 else { throw ProximusError.invalid("Pairing data is too large.") }
        let n = UInt32(data.count)
        let framed = Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + data
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func receive() async throws -> Data {
        let prefix = try await exact(4)
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...VaultCrypto.maximumPayload * 2).contains(length) else { throw ProximusError.authentication }
        return try await exact(length)
    }
    private func exact(_ length: Int) async throws -> Data {
        var result = Data()
        while result.count < length {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: length - result.count) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: ProximusError.transport(complete ? "The pairing connection closed." : "The pairing connection returned no data.")) }
                }
            }
            result.append(chunk)
        }
        return result
    }
}

@MainActor public final class PairingSession: ObservableObject {
    @Published public private(set) var invitationLink = ""
    @Published public private(set) var confirmationCode = ""
    @Published public private(set) var peerName = ""
    @Published public private(set) var status = ""
    @Published public private(set) var canConfirm = false
    @Published public private(set) var complete = false
    @Published public private(set) var failure: String?
    private var listener: NWListener?
    private var wire: FramedConnection?
    private var timeout: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var approval: CheckedContinuation<Void, Error>?
    private var confirmed = false
    private var running = false
    public init() {}
    public func confirm() {
        guard canConfirm else { return }
        canConfirm = false; confirmed = true
        approval?.resume(); approval = nil
        status = "Waiting for confirmation on your other device…"
    }
    public func cancel() {
        running = false; canConfirm = false
        approval?.resume(throwing: CancellationError()); approval = nil
        wire?.connection.cancel(); wire = nil
        listener?.cancel(); listener = nil
        timeout?.cancel(); timeout = nil; worker?.cancel(); worker = nil
    }
    private func waitForApproval() async throws {
        if confirmed { return }
        try await withCheckedThrowingContinuation { approval = $0 }
    }
    private func begin() throws {
        guard !running else { throw ProximusError.invalid("A pairing session is already open.") }
        running = true; complete = false; failure = nil; confirmed = false; confirmationCode = ""; canConfirm = false
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.fail(ProximusError.transport("Pairing expired. Generate a fresh code and try again."))
        }
    }
    private func fail(_ error: Error) { failure = error.localizedDescription; status = "Pairing stopped"; cancel() }
    private func finish() { complete = true; status = "Device paired"; cancel() }
    private func parameters() -> NWParameters { let value = NWParameters.tcp; value.includePeerToPeer = true; return value }
    public func host(bundle: @escaping (UUID, String) throws -> PairingBundle) throws {
        try begin()
        let key = P256.KeyAgreement.PrivateKey()
        let invitation = PairingInvitation(session: UUID(), hostPublicKey: key.publicKey.x963Representation, expires: Date().addingTimeInterval(120))
        invitationLink = try invitation.link(); status = "Scan this code from Proximus on your other device."
        let listener = try NWListener(using: parameters())
        self.listener = listener
        listener.service = NWListener.Service(name: invitation.service, type: "_proximus-pair._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in self?.fail(error) } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.running, self.wire == nil else { connection.cancel(); return }
                let wire = FramedConnection(connection); self.wire = wire
                connection.start(queue: .global(qos: .userInitiated))
                self.worker = Task {
                    do {
                        let hello = try Encoding.decode(PairingHello.self, from: await wire.receive())
                        guard invitation.expires > Date() else { throw ProximusError.authentication }
                        let sessionKey = try PairingCrypto.key(privateKey: key, peer: hello.publicKey, invitation: invitation, clientPublicKey: hello.publicKey)
                        let peer = try Encoding.decode(PairingPeer.self, from: VaultCrypto.open(hello.proof, key: sessionKey, context: PairingCrypto.context("hello", invitation: invitation)))
                        guard !peer.name.isEmpty, peer.name.utf8.count <= 128 else { throw ProximusError.authentication }
                        self.peerName = peer.name; self.confirmationCode = PairingCrypto.code(sessionKey); self.canConfirm = true
                        self.status = "Compare this code on both devices before approving."
                        try await wire.send(VaultCrypto.seal(Data("ready".utf8), key: sessionKey, context: PairingCrypto.context("ready", invitation: invitation)))
                        let confirmation = try VaultCrypto.open(await wire.receive(), key: sessionKey, context: PairingCrypto.context("confirm", invitation: invitation))
                        guard confirmation == Data("confirmed".utf8) else { throw ProximusError.authentication }
                        try await self.waitForApproval()
                        guard self.running, invitation.expires > Date() else { throw ProximusError.authentication }
                        let transfer = try bundle(peer.id, peer.name); try transfer.validate()
                        try await wire.send(VaultCrypto.seal(Encoding.encode(transfer), key: sessionKey, context: PairingCrypto.context("bundle", invitation: invitation)))
                        let ack = try VaultCrypto.open(await wire.receive(), key: sessionKey, context: PairingCrypto.context("ack", invitation: invitation))
                        guard ack == Data("installed".utf8) else { throw ProximusError.authentication }
                        self.finish()
                    } catch { if self.running { self.fail(error) } }
                }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }
    public func join(link: String, deviceID: UUID, name: String, install: @escaping (PairingBundle) throws -> Void) throws {
        let invitation = try PairingInvitation.parse(link)
        try begin(); status = "Connecting over your local network…"
        let connection = NWConnection(to: .service(name: invitation.service, type: "_proximus-pair._tcp", domain: "local.", interface: nil), using: parameters())
        let wire = FramedConnection(connection); self.wire = wire
        connection.start(queue: .global(qos: .userInitiated))
        worker = Task {
            do {
                let key = P256.KeyAgreement.PrivateKey()
                let sessionKey = try PairingCrypto.key(privateKey: key, peer: invitation.hostPublicKey, invitation: invitation, clientPublicKey: key.publicKey.x963Representation)
                let peer = PairingPeer(id: deviceID, name: String(name.prefix(64)))
                let hello = PairingHello(publicKey: key.publicKey.x963Representation, proof: try VaultCrypto.seal(Encoding.encode(peer), key: sessionKey, context: PairingCrypto.context("hello", invitation: invitation)))
                try await wire.send(Encoding.encode(hello))
                let ready = try VaultCrypto.open(await wire.receive(), key: sessionKey, context: PairingCrypto.context("ready", invitation: invitation))
                guard ready == Data("ready".utf8) else { throw ProximusError.authentication }
                self.confirmationCode = PairingCrypto.code(sessionKey); self.canConfirm = true
                self.status = "Compare this code with your other device before approving."
                try await self.waitForApproval()
                try await wire.send(VaultCrypto.seal(Data("confirmed".utf8), key: sessionKey, context: PairingCrypto.context("confirm", invitation: invitation)))
                let transfer = try Encoding.decode(PairingBundle.self, from: VaultCrypto.open(await wire.receive(), key: sessionKey, context: PairingCrypto.context("bundle", invitation: invitation)))
                guard self.running, invitation.expires > Date() else { throw ProximusError.authentication }
                try transfer.validate(); try install(transfer)
                try await wire.send(VaultCrypto.seal(Data("installed".utf8), key: sessionKey, context: PairingCrypto.context("ack", invitation: invitation)))
                self.finish()
            } catch { if self.running { self.fail(error) } }
        }
    }
}
