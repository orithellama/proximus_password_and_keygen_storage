import Foundation

// Decode RPC numbers without converting atomic amounts to Double.
enum RPCValue: Codable, Equatable, Sendable {
    case string(String), integer(UInt64), decimal(Decimal), bool(Bool), array([RPCValue]), object([String: RPCValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(UInt64.self) { self = .integer(v) }
        else if let v = try? c.decode(Decimal.self) { self = .decimal(v) }
        else if let v = try? c.decode([RPCValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: RPCValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .decimal(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> RPCValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var text: String { get throws { guard case .string(let s) = self else { throw Self.invalid }; return s } }
    var uint: UInt64 { get throws { guard case .integer(let v) = self else { throw Self.invalid }; return v } }
    var values: [RPCValue] { get throws { guard case .array(let v) = self else { throw Self.invalid }; return v } }
    var isTrue: Bool { self == .bool(true) }
    static var invalid: ProximusError { .transport("The RPC returned incomplete or invalid transaction data.") }
    var atoms: NativeAmount { get throws { try NativeAmount(String(uint)) } }
    func bitcoinAtoms() throws -> NativeAmount {
        var value: Decimal
        switch self { case .integer(let n): value = Decimal(n); case .decimal(let n): value = n; default: throw Self.invalid }
        value *= Decimal(100_000_000)
        var integral = Decimal(); NSDecimalRound(&integral, &value, 0, .plain)
        guard integral == value, value >= 0, value <= Decimal(2_100_000_000_000_000 as UInt64) else { throw Self.invalid }
        return try NativeAmount(NSDecimalNumber(decimal: value).stringValue)
    }
}

public struct WalletRPCClient: Sendable {
    public let configuration: RPCConfiguration
    typealias Transport = @Sendable (URLRequest, Int, URLCredential?) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    public init(configuration: RPCConfiguration) throws {
        try configuration.validate(); self.configuration = configuration
        transport = { try await BoundedHTTP.send($0, limit: $1, digestCredential: $2) }
    }
    init(configuration: RPCConfiguration, transport: @escaping Transport) throws { try configuration.validate(); self.configuration = configuration; self.transport = transport }
    func call(_ method: String, _ params: RPCValue = .array([])) async throws -> RPCValue {
        try Task.checkCancellation(); try configuration.validate()
        let id = UUID().uuidString
        let body = RPCValue.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params])
        var request = URLRequest(url: configuration.endpoint); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try Encoding.encode(body)
        if !configuration.username.isEmpty && configuration.moneroWalletCompanion != true {
            request.setValue("Basic " + Data((configuration.username + ":" + configuration.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        let limit = 2 * 1024 * 1024
        let (data, response) = try await transport(request, limit, configuration.digestCredential)
        guard response.statusCode == 200, data.count <= limit else { throw ProximusError.transport("RPC \(method) failed (HTTP \(response.statusCode)).") }
        let value = try Encoding.decode(RPCValue.self, from: data)
        guard value["id"] == .string(id) else { throw RPCValue.invalid }
        guard value["error"] == .null else { throw ProximusError.transport("The node rejected \(method). Check the node’s configuration, wallet sync, available funds, and transaction status.") }
        return value["result"]
    }
    public func chain(wallet: WalletMetadata) async throws -> WalletChain {
        guard wallet.network == configuration.network else { throw ProximusError.authentication }
        let identity: String
        switch wallet.network {
        case .solana: identity = try await call("getGenesisHash").text
        case .evm: identity = try NativeAmount.hex(await call("eth_chainId").text).atoms
        case .bitcoin:
            let info = try await call("getblockchaininfo")
            guard info["initialblockdownload"] == .bool(false) else { throw ProximusError.unavailable("Wait for Bitcoin Core to finish syncing.") }
            identity = try info["chain"].text
        case .monero:
            try requireCompanion()
            let address = try await call("get_address", .object(["account_index": .integer(0)]))
            guard try address["address"].text == wallet.address else { throw ProximusError.invalid("The local Monero companion has a different wallet loaded. Open the matching wallet in monero-wallet-rpc. Proximus never sends it your keys.") }
            let valid = try await call("validate_address", .object(["address": .string(wallet.address), "any_net_type": .bool(false), "allow_openalias": .bool(false)]))
            guard valid["valid"].isTrue else { throw RPCValue.invalid }
            identity = try valid["nettype"].text
        }
        return try WalletChain.resolve(wallet.network, identity: identity)
    }
    private func requireCompanion() throws {
        #if os(macOS)
        guard configuration.moneroWalletCompanion == true else { throw ProximusError.unavailable("Configure a local monero-wallet-rpc companion in RPC settings to view balances or send XMR.") }
        #else
        throw ProximusError.unavailable("Open this wallet on Mac with a local Monero wallet companion to view balances or send XMR.")
        #endif
    }
    private func unspent(_ wallet: WalletMetadata) async throws -> [RPCValue] {
        let info = try await call("getaddressinfo", .array([.string(wallet.address)]))
        guard info["ismine"].isTrue || info["iswatchonly"].isTrue else { throw ProximusError.unavailable("Import this public address as a watch-only descriptor in the Bitcoin Core wallet, then rescan. Use its /wallet/<name> RPC endpoint. No private key is needed by Core.") }
        let result = try await call("listunspent", .array([.integer(1), .integer(9_999_999), .array([.string(wallet.address)]), .bool(false)]))
        let inputs = try result.values
        guard inputs.count <= 10_000 else { throw RPCValue.invalid }
        for input in inputs {
            guard try input["address"].text == wallet.address, input["safe"].isTrue,
                  try input["confirmations"].uint > 0 else { throw RPCValue.invalid }
        }
        return inputs
    }
    public func balance(wallet: WalletMetadata) async throws -> WalletBalance {
        let chain = try await chain(wallet: wallet)
        let available: NativeAmount, total: NativeAmount, detail: String
        switch wallet.network {
        case .solana:
            available = try await call("getBalance", .array([.string(wallet.address), .object(["commitment": .string("confirmed")])]))["value"].atoms
            total = available; detail = "Confirmed balance"
        case .evm:
            available = try NativeAmount.hex(await call("eth_getBalance", .array([.string(wallet.address), .string("pending")])).text)
            total = available; detail = "Node balance including pending transactions - chain ID " + chain.identity
        case .bitcoin:
            available = try await unspent(wallet).reduce(.zero) { try $0.adding($1["amount"].bitcoinAtoms()) }
            total = available; detail = "Confirmed safe outputs tracked by your Core wallet"
        case .monero:
            let result = try await call("get_balance", .object(["account_index": .integer(0), "address_indices": .array([.integer(0)])]))
            guard let address = try result["per_subaddress"].values.first(where: { $0["address_index"] == .integer(0) }), try address["address"].text == wallet.address else { throw RPCValue.invalid }
            available = try address["unlocked_balance"].atoms; total = try address["balance"].atoms
            guard available <= total else { throw RPCValue.invalid }
            detail = "Unlocked balance - local companion’s scanned wallet"
        }
        return WalletBalance(chain: chain, available: available, total: total, checkedAt: Date(), detail: detail)
    }
    public func prepare(wallet: WalletMetadata, vaultID: UUID, recipient: String, amount text: String) async throws -> PreparedTransfer {
        let balance = try await balance(wallet: wallet), chain = balance.chain
        let amount = try NativeAmount.parse(text, decimals: chain.decimals)
        guard amount > .zero, amount < balance.available else { throw ProximusError.invalid("Enter an amount below the available balance and leave room for the network fee.") }
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, to.utf8.count <= 128, to != wallet.address else { throw ProximusError.invalid("Enter the recipient’s address on this chain.") }
        var transaction = NativeTransaction(network: wallet.network.code, from: wallet.address, to: to, amount: amount.atoms)
        var fee = NativeAmount.zero, unsigned = "", companionMetadata: String?, companionID: String?
        switch wallet.network {
        case .solana:
            let account = try await call("getAccountInfo", .array([.string(wallet.address), .object(["encoding": .string("base64"), "commitment": .string("confirmed")])]))["value"]
            guard try account["owner"].text == "11111111111111111111111111111111", account["executable"] == .bool(false) else { throw ProximusError.invalid("Solana sending requires a standard system account.") }
            transaction.blockhash = try await call("getLatestBlockhash", .array([.object(["commitment": .string("confirmed")])]))["value"]["blockhash"].text
            unsigned = try NativeSigner.process(transaction).unsigned
            fee = try await solanaFee(unsigned)
        case .evm:
            transaction.chainId = try NativeAmount(chain.identity).uint64
            transaction.nonce = try NativeAmount.hex(await call("eth_getTransactionCount", .array([.string(wallet.address), .string("pending")])).text).uint64
            transaction.gasPrice = try NativeAmount.hex(await call("eth_gasPrice").text).atoms
            // No contract invocation or delegated smart-account behavior in this native transfer flow.
            for address in [wallet.address, to] {
                guard try await call("eth_getCode", .array([.string(address), .string("pending")])).text == "0x" else { throw ProximusError.invalid("Native EVM sending currently supports plain accounts only. Contract and delegated account transfers need a separate review flow.") }
            }
            let estimate = try NativeAmount.hex(await call("eth_estimateGas", .array([.object(["from": .string(wallet.address), "to": .string(to), "value": .string(amount.rpcHex), "gasPrice": .string(try NativeAmount(transaction.gasPrice).rpcHex)])])).text).uint64
            guard (21_000...1_000_000).contains(estimate) else { throw RPCValue.invalid }
            transaction.gasLimit = estimate
            let wire = try NativeSigner.process(transaction); unsigned = wire.unsigned; fee = try NativeAmount(wire.fee)
        case .bitcoin:
            let rate = try await call("estimatesmartfee", .array([.integer(6), .string("CONSERVATIVE")]))["feerate"].bitcoinAtoms().uint64
            transaction.feeRate = (rate + 999) / 1000
            guard (1...1000).contains(transaction.feeRate) else { throw ProximusError.unavailable("The node could not provide a usable Bitcoin fee estimate. Try again after it has synced.") }
            let inputs = try await unspent(wallet)
            guard !inputs.isEmpty, inputs.count <= 32 else { throw ProximusError.unavailable("This transfer requires 1–32 tracked Bitcoin outputs. Consolidate larger wallets in a compatible Bitcoin wallet first.") }
            for input in inputs {
                let txid = try input["txid"].text, vout = try input["vout"].uint
                guard EncryptedSnapshot.validHash(txid), let index = UInt32(exactly: vout) else { throw RPCValue.invalid }
                let raw: String
                // gettransaction works for a tracked wallet without a node-wide txindex.
                do { raw = try await call("gettransaction", .array([.string(txid), .bool(true)]))["hex"].text }
                catch { raw = try await call("getrawtransaction", .array([.string(txid), .bool(false)])).text }
                transaction.prevouts.append(NativePrevout(transaction: raw, vout: index))
            }
            let wire = try NativeSigner.process(transaction); unsigned = wire.unsigned; fee = try NativeAmount(wire.fee)
            // The Rust engine derives each outpoint from the full previous transaction.
            for input in wire.inputs { guard inputs.contains(where: { $0["txid"] == .string(input.txid) && $0["vout"] == .integer(UInt64(input.vout)) }) else { throw RPCValue.invalid } }
        case .monero:
            try requireCompanion()
            let valid = try await call("validate_address", .object(["address": .string(to), "any_net_type": .bool(false), "allow_openalias": .bool(false)]))
            guard valid["valid"].isTrue, valid["nettype"] == .string("mainnet"), valid["integrated"] == .bool(false) else { throw ProximusError.invalid("Enter a standard mainnet Monero address or subaddress. Integrated payment-ID addresses are not supported.") }
            let result = try await call("transfer", .object(["destinations": .array([.object(["address": .string(to), "amount": .integer(try amount.uint64)])]), "account_index": .integer(0), "subaddr_indices": .array([.integer(0)]), "priority": .integer(1), "unlock_time": .integer(0), "do_not_relay": .bool(true), "get_tx_metadata": .bool(true), "get_tx_hex": .bool(true)]))
            guard try result["amount"].atoms == amount else { throw RPCValue.invalid }
            fee = try result["fee"].atoms
            let metadata = try result["tx_metadata"].text
            guard !metadata.isEmpty, metadata.count <= 1_000_000 else { throw RPCValue.invalid }
            _ = try Data(strictHex: metadata)
            companionMetadata = metadata; companionID = try result["tx_hash"].text
        }
        guard try amount.adding(fee) <= balance.available else { throw ProximusError.invalid("The available balance does not cover this amount plus the network fee.") }
        // Whole seconds keep signed review dates identical across JSON round trips.
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let plan = TransferPlan(id: UUID(), vaultID: vaultID, wallet: wallet, chain: chain, recipient: to, amount: amount, fee: fee, createdAt: now, expiresAt: now.addingTimeInterval(wallet.network == .solana ? 75 : 600), transaction: wallet.network == .monero ? nil : transaction, unsigned: unsigned, companionDigest: companionMetadata.map { VaultCrypto.digest(Data($0.utf8)) }, companionTransactionID: companionID)
        try plan.validate()
        return PreparedTransfer(plan: plan, companionMetadata: companionMetadata, endpoint: configuration.endpoint.absoluteString)
    }
    private func solanaFee(_ unsigned: String) async throws -> NativeAmount {
        try await call("getFeeForMessage", .array([.string(Data(strictHex: unsigned).base64EncodedString()), .object(["commitment": .string("confirmed")])]))["value"].atoms
    }
    func revalidate(_ transfer: PreparedTransfer) async throws {
        let plan = transfer.plan
        try plan.validate()
        guard configuration.endpoint.absoluteString == transfer.endpoint, try await chain(wallet: plan.wallet) == plan.chain else { throw ProximusError.invalid("The RPC network changed. Prepare the transfer again.") }
        switch plan.chain.network {
        case .solana:
            guard let transaction = plan.transaction,
                  try await call("isBlockhashValid", .array([.string(transaction.blockhash), .object(["commitment": .string("confirmed")])]))["value"].isTrue,
                  try await solanaFee(plan.unsigned) == plan.fee else { throw ProximusError.invalid("The Solana blockhash or fee changed. Prepare a fresh transfer.") }
        case .evm:
            guard let transaction = plan.transaction,
                  try NativeAmount.hex(await call("eth_getTransactionCount", .array([.string(plan.wallet.address), .string("pending")])).text).uint64 == transaction.nonce else { throw ProximusError.invalid("This wallet’s nonce changed. Prepare a fresh transfer.") }
            for address in [plan.wallet.address, plan.recipient] { guard try await call("eth_getCode", .array([.string(address), .string("pending")])).text == "0x" else { throw ProximusError.invalid("An account changed to a contract. Prepare a fresh transfer.") } }
        case .bitcoin:
            guard let transaction = plan.transaction else { throw ProximusError.authentication }
            let wire = try NativeSigner.process(transaction)
            for input in wire.inputs {
                let result = try await call("gettxout", .array([.string(input.txid), .integer(UInt64(input.vout)), .bool(true)]))
                guard result != .null, try result["confirmations"].uint > 0 else { throw ProximusError.invalid("A Bitcoin input is spent or no longer confirmed. Prepare a fresh transfer.") }
            }
        case .monero:
            try requireCompanion()
            guard let metadata = transfer.companionMetadata, VaultCrypto.digest(Data(metadata.utf8)) == plan.companionDigest else { throw ProximusError.authentication }
        }
        try plan.validate()
    }
    func broadcast(_ wire: NativeWire?, transfer: PreparedTransfer) async throws -> String {
        switch transfer.plan.chain.network {
        case .solana:
            guard let wire else { throw ProximusError.authentication }
            return try await call("sendTransaction", .array([.string(Data(strictHex: wire.signed).base64EncodedString()), .object(["encoding": .string("base64"), "skipPreflight": .bool(false), "preflightCommitment": .string("confirmed"), "maxRetries": .integer(0)])])).text
        case .evm:
            guard let wire else { throw ProximusError.authentication }
            return try await call("eth_sendRawTransaction", .array([.string("0x" + wire.signed)])).text
        case .bitcoin:
            guard let wire else { throw ProximusError.authentication }
            return try await call("sendrawtransaction", .array([.string(wire.signed)])).text
        case .monero:
            try requireCompanion()
            guard let metadata = transfer.companionMetadata else { throw ProximusError.authentication }
            return try await call("relay_tx", .object(["hex": .string(metadata)]))["tx_hash"].text
        }
    }
    public func status(_ receipt: TransferReceipt, wallet: WalletMetadata) async throws -> String {
        guard receipt.walletID == wallet.id, try await chain(wallet: wallet) == receipt.chain else { throw ProximusError.authentication }
        switch wallet.network {
        case .solana:
            let values = try await call("getSignatureStatuses", .array([.array([.string(receipt.transactionID)]), .object(["searchTransactionHistory": .bool(true)])]))["value"].values
            guard let value = values.first, value != .null else { return "Not found by this node. Do not assume it failed." }
            if value["err"] != .null { return "Failed on chain" }
            let status = try value["confirmationStatus"].text
            guard ["processed", "confirmed", "finalized"].contains(status) else { throw RPCValue.invalid }
            return "On chain: " + status
        case .evm:
            let value = try await call("eth_getTransactionReceipt", .array([.string(receipt.transactionID)]))
            if value == .null { return "Pending or not found by this node" }
            guard try value["transactionHash"].text.lowercased() == receipt.transactionID.lowercased() else { throw RPCValue.invalid }
            let status = try NativeAmount.hex(value["status"].text)
            return status == (try NativeAmount("1")) ? "Included in block " + (try NativeAmount.hex(value["blockNumber"].text).atoms) : "Failed on chain"
        case .bitcoin:
            let value = try await call("gettransaction", .array([.string(receipt.transactionID), .bool(true)]))
            if let confirmations = try? value["confirmations"].uint { return confirmations > 0 ? "\(confirmations) confirmations" : "Pending confirmation" }
            return "Conflicted or not confirmed"
        case .monero:
            let value = try await call("get_transfer_by_txid", .object(["txid": .string(receipt.transactionID), "account_index": .integer(0)]))["transfer"]
            guard try value["txid"].text == receipt.transactionID else { throw RPCValue.invalid }
            let type = try value["type"].text
            if type == "failed" { return "Companion reports failure" }
            if type == "out" { return "Confirmed - " + String(try value["confirmations"].uint) + " confirmations" }
            return "Pending confirmation"
        }
    }
}
