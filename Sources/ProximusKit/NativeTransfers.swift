import Foundation
import ProximusCrypto

struct NativePrevout: Codable, Equatable, Sendable { var transaction: String; var vout: UInt32 }
struct NativeInput: Codable, Equatable, Sendable { var txid: String; var vout: UInt32 }
struct NativeTransaction: Codable, Equatable, Sendable {
    var action = "prepare"
    var network: UInt32
    var from: String
    var to: String
    var amount: String
    var chainId: UInt64 = 0
    var nonce: UInt64 = 0
    var gasPrice = ""
    var gasLimit: UInt64 = 0
    var blockhash = ""
    var feeRate: UInt64 = 0
    var prevouts: [NativePrevout] = []
    var privateKey = ""
}
struct NativeWire: Codable, Equatable, Sendable {
    var unsigned: String
    var fee: String
    var signed: String
    var transactionId: String
    var inputs: [NativeInput]
}
enum NativeSigner {
    static func process(_ request: NativeTransaction) throws -> NativeWire {
        var input = try Encoding.encode(request)
        defer { input.resetBytes(in: 0..<input.count) }
        guard input.count <= 2 * 1024 * 1024 else { throw ProximusError.invalid("Too many transaction inputs. Consolidate this wallet in a compatible Bitcoin wallet first.") }
        var output = Data(count: 2 * 1024 * 1024), length = 0
        defer { output.resetBytes(in: 0..<output.count) }
        let capacity = output.count
        let status = input.withUnsafeBytes { source in output.withUnsafeMutableBytes { destination in
            px_transaction(source.bindMemory(to: UInt8.self).baseAddress, input.count, destination.bindMemory(to: UInt8.self).baseAddress, capacity, &length)
        } }
        guard status == 0, length > 0, length <= capacity else { throw ProximusError.invalid("Cannot construct this transfer. Check the destination, amount, network, fees, and available inputs.") }
        return try Encoding.decode(NativeWire.self, from: Data(output.prefix(length)))
    }
}

/// Public, immutable review data. No credentials, private keys, or signed Monero blob.
public struct TransferPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let vaultID: UUID
    public let wallet: WalletMetadata
    public let chain: WalletChain
    public let recipient: String
    public let amount: NativeAmount
    public let fee: NativeAmount
    public let createdAt: Date
    public let expiresAt: Date
    let transaction: NativeTransaction?
    let unsigned: String
    let companionDigest: String?
    let companionTransactionID: String?
    public var fingerprint: String { get throws { VaultCrypto.digest(try Encoding.encode(self)) } }
    public var total: NativeAmount { get throws { try amount.adding(fee) } }
    public var feeLabel: String { chain.network == .evm ? "Maximum network fee" : "Network fee" }
    public func validate(now: Date = Date()) throws {
        try wallet.validate(); try chain.validate()
        guard chain.network == wallet.network, amount > .zero, fee > .zero,
              createdAt <= now.addingTimeInterval(30), expiresAt > now,
              expiresAt.timeIntervalSince(createdAt) > 0, expiresAt.timeIntervalSince(createdAt) <= 600,
              !recipient.isEmpty, recipient.utf8.count <= 128 else { throw ProximusError.invalid("This transfer is invalid or expired. Prepare a fresh review.") }
        _ = try total
        if chain.network == .monero {
            guard transaction == nil, unsigned.isEmpty, let companionDigest, EncryptedSnapshot.validHash(companionDigest), let companionTransactionID, EncryptedSnapshot.validHash(companionTransactionID) else { throw ProximusError.authentication }
        } else {
            guard let transaction, transaction.action == "prepare", transaction.privateKey.isEmpty,
                  transaction.network == wallet.network.code, transaction.from == wallet.address,
                  transaction.to == recipient, transaction.amount == amount.atoms,
                  companionDigest == nil, companionTransactionID == nil else { throw ProximusError.authentication }
            if chain.network == .evm { guard String(transaction.chainId) == chain.identity else { throw ProximusError.authentication } }
            let wire = try NativeSigner.process(transaction)
            guard wire.unsigned == unsigned, chain.network == .solana || wire.fee == fee.atoms else { throw ProximusError.authentication }
            // This message has one signature and no priority fee instructions.
            if chain.network == .solana { guard try fee.uint64 <= 1_000_000 else { throw ProximusError.invalid("Unexpected Solana fee. Check your RPC node.") } }
        }
    }
}

public struct PreparedTransfer: Sendable {
    public let plan: TransferPlan
    let companionMetadata: String?
    let endpoint: String
}
public struct WalletBalance: Sendable {
    public let chain: WalletChain
    public let available: NativeAmount
    public let total: NativeAmount
    public let checkedAt: Date
    public let detail: String
}

public struct TransferReceipt: Codable, Identifiable, Sendable {
    public let id: UUID
    public let walletID: UUID
    public let chain: WalletChain
    public let transactionID: String
    public let recipient: String
    public let amount: NativeAmount
    public let date: Date
    public var status: String
    static func account(_ wallet: UUID) -> String { "transfer-receipt/" + wallet.uuidString }
    public static func load(wallet: UUID) throws -> Self? { try DeviceKeychain.read(account(wallet)).map { try Encoding.decode(Self.self, from: $0) } }
    func save() throws { try DeviceKeychain.write(Encoding.encode(self), account: Self.account(walletID)) }
}

extension Data {
    init(strictHex: String) throws {
        guard strictHex.count % 2 == 0, strictHex.count <= 2 * 1024 * 1024, strictHex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ProximusError.invalid("Invalid transaction encoding.") }
        var bytes = [UInt8](); bytes.reserveCapacity(strictHex.count / 2)
        let chars = Array(strictHex.utf8)
        func digit(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
        for i in stride(from: 0, to: chars.count, by: 2) { bytes.append(digit(chars[i]) * 16 + digit(chars[i + 1])) }
        self.init(bytes)
    }
}
