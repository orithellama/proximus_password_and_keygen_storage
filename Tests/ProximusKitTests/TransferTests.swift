import XCTest
import CryptoKit
@testable import ProximusKit

final class TransferTests: XCTestCase {
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let recipient = "0x3535353535353535353535353535353535353535"
    private func wallet(_ network: WalletNetwork) throws -> WalletMetadata {
        try WalletCrypto.derive(network: network, recovery: network == .monero ? "01" + String(repeating: "00", count: 31) : phrase).metadata(network: network, deviceID: UUID())
    }
    private func plan() throws -> TransferPlan {
        let wallet = try wallet(.evm), amount = try NativeAmount("1000000000000000001")
        let transaction = NativeTransaction(network: 2, from: wallet.address, to: recipient, amount: amount.atoms, chainId: 1, nonce: 9, gasPrice: "20000000000", gasLimit: 21000)
        let wire = try NativeSigner.process(transaction), now = Date()
        return try TransferPlan(id: UUID(), vaultID: UUID(), wallet: wallet, chain: WalletChain.resolve(.evm, identity: "1"), recipient: recipient, amount: amount, fee: NativeAmount(wire.fee), createdAt: now, expiresAt: now.addingTimeInterval(600), transaction: transaction, unsigned: wire.unsigned, companionDigest: nil, companionTransactionID: nil)
    }
    private func altered(_ plan: TransferPlan, change: (inout [String: Any]) -> Void) throws -> TransferPlan {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Encoding.encode(plan)) as? [String: Any])
        change(&json); return try Encoding.decode(TransferPlan.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func rpc(_ network: WalletNetwork, handler: @escaping (String, RPCValue) throws -> RPCValue) throws -> WalletRPCClient {
        let config = try RPCConfiguration(network: network, endpoint: URL(string: network == .monero ? "http://127.0.0.1:18082/json_rpc" : "https://node.example/rpc")!, username: network == .monero ? "fixture" : "", password: network == .monero ? "fixture" : "", moneroWalletCompanion: network == .monero)
        return try WalletRPCClient(configuration: config) { request, _, credential in
            let json = try Encoding.decode(RPCValue.self, from: XCTUnwrap(request.httpBody))
            let method = try json["method"].text
            XCTAssertEqual(request.httpMethod, "POST")
            if network == .monero { XCTAssertNotNil(credential); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
            let result = try handler(method, json["params"])
            let data = try Encoding.encode(RPCValue.object(["id": json["id"], "jsonrpc": .string("2.0"), "result": result]))
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func rejects(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected rejection", file: file, line: line) } catch { }
    }

    func testExactAmountsAndRPCNumbersRejectRoundingOverflowAndAmbiguousInput() throws {
        let amount = try NativeAmount.parse("123456789.123456789123456789", decimals: 18)
        XCTAssertEqual(amount.atoms, "123456789123456789123456789")
        XCTAssertEqual(amount.formatted(decimals: 18), "123456789.123456789123456789")
        XCTAssertEqual(try NativeAmount.hex(amount.rpcHex), amount)
        XCTAssertEqual(try NativeAmount.parse("0.000000000000000001", decimals: 18).atoms, "1")
        XCTAssertEqual(try NativeAmount.hex("0xffffffffffffffffffffffffffffffff").atoms, "340282366920938463463374607431768211455")
        XCTAssertThrowsError(try NativeAmount("340282366920938463463374607431768211455").adding(NativeAmount("1")))
        for text in ["", "-1", "+1", "1e3", "1,000", " 1", ".5", "1.", "١", "NaN", "0.0000000001"] { XCTAssertThrowsError(try NativeAmount.parse(text, decimals: 9), text) }
        for text in ["0x", "0xgg", "0x100000000000000000000000000000000"] { XCTAssertThrowsError(try NativeAmount.hex(text)) }
        let exact = try Encoding.decode(RPCValue.self, from: Data("18446744073709551615".utf8))
        XCTAssertEqual(try exact.atoms.atoms, "18446744073709551615")
        XCTAssertEqual(try Encoding.decode(RPCValue.self, from: Data("0.00000001".utf8)).bitcoinAtoms().atoms, "1")
        XCTAssertEqual(try Encoding.decode(RPCValue.self, from: Data("0.00002001".utf8)).bitcoinAtoms().atoms, "2001")
        XCTAssertThrowsError(try Encoding.decode(RPCValue.self, from: Data("0.000000001".utf8)).bitcoinAtoms())
        XCTAssertThrowsError(try RPCValue.bool(true).atoms)
        XCTAssertThrowsError(try RPCValue.decimal(Decimal(string: "-1")!).atoms)
    }

    func testReviewReconstructsBytesAndRejectsChangedChainRecipientAmountFeeAndSecrets() throws {
        let original = try plan(); try original.validate()
        for field in ["recipient", "amount", "fee", "unsigned"] {
            let modified = try altered(original) { $0[field] = field == "recipient" ? "0x4545454545454545454545454545454545454545" : field == "unsigned" ? "00" : "1" }
            XCTAssertThrowsError(try modified.validate(), field)
        }
        XCTAssertThrowsError(try altered(original) { var chain = $0["chain"] as! [String: Any]; chain["name"] = "Safe network"; $0["chain"] = chain }.validate())
        XCTAssertThrowsError(try altered(original) { var transaction = $0["transaction"] as! [String: Any]; transaction["privateKey"] = "secret"; $0["transaction"] = transaction }.validate())
        XCTAssertThrowsError(try original.validate(now: original.expiresAt))
        XCTAssertThrowsError(try WalletChain.resolve(.evm, identity: "8453")) // Additional L1 fee not implemented.
        XCTAssertThrowsError(try WalletChain.resolve(.bitcoin, identity: "test"))
    }

    func testIndependentApprovalBindsEntirePlanAndRejectsWrongPeerReplayAndReflection() throws {
        let plan = try plan(), signer = P256.Signing.PrivateKey(), peerKey = P256.Signing.PrivateKey(), device = UUID()
        let owner = ApprovalIdentity(vaultID: plan.vaultID, deviceID: plan.wallet.ownerDeviceID, name: "Sender", publicKey: signer.publicKey.x963Representation)
        let peer = ApprovalIdentity(vaultID: plan.vaultID, deviceID: device, name: "Approver", publicKey: peerKey.publicKey.x963Representation)
        let request = TransferApprovalRequest(plan: plan, requester: owner, signature: try signer.signature(for: ApprovalKeys.message(plan, domain: "request")).derRepresentation)
        try TransferApprovalRequest.decode(request.code).validate(peer: owner, deviceID: device)
        let signature = try peerKey.signature(for: ApprovalKeys.message(plan, domain: "approval")).derRepresentation
        let response = TransferApproval(requestID: plan.id, planDigest: try plan.fingerprint, deviceID: device, signature: signature)
        try TransferApproval.decode(response.code).validate(plan: plan, peer: peer)
        XCTAssertEqual(try ApprovalIdentity.decode(peer.code), peer)
        let impostor = ApprovalIdentity(vaultID: plan.vaultID, deviceID: device, name: peer.name, publicKey: P256.Signing.PrivateKey().publicKey.x963Representation)
        XCTAssertThrowsError(try response.validate(plan: plan, peer: impostor))
        XCTAssertThrowsError(try response.validate(plan: plan, peer: peer, now: plan.expiresAt.addingTimeInterval(1)))
        XCTAssertThrowsError(try response.validate(plan: altered(plan) { $0["id"] = UUID().uuidString }, peer: peer))
        let reflected = TransferApproval(requestID: plan.id, planDigest: try plan.fingerprint, deviceID: device, signature: request.signature)
        XCTAssertThrowsError(try reflected.validate(plan: plan, peer: peer))
        XCTAssertThrowsError(try request.validate(peer: owner, deviceID: owner.deviceID))
        XCTAssertThrowsError(try request.validate(peer: impostor, deviceID: device))
        XCTAssertThrowsError(try TransferApproval.decode(peer.code))
    }

    func testEVMPrepareIsReadOnlyExactAndRejectsNonceChangeAndContracts() async throws {
        let wallet = try wallet(.evm)
        var nonce = "0x9", code = "0x", calls = [String]()
        let client = try rpc(.evm) { method, params in
            calls.append(method)
            switch method {
            case "eth_chainId": return .string("0x1")
            case "eth_getBalance": return .string("0x8ac7230489e80000") // 10 ETH
            case "eth_getTransactionCount": return .string(nonce)
            case "eth_gasPrice": return .string("0x4a817c800")
            case "eth_getCode": return .string(code)
            case "eth_estimateGas":
                XCTAssertEqual(try params.values[0]["value"].text, "0xde0b6b3a7640001")
                XCTAssertEqual(try params.values[0]["to"].text, self.recipient)
                return .string("0x5208")
            default: XCTFail("Unexpected method \(method)"); throw RPCValue.invalid
            }
        }
        let transfer = try await client.prepare(wallet: wallet, vaultID: UUID(), recipient: recipient, amount: "1.000000000000000001")
        XCTAssertEqual(transfer.plan.amount.atoms, "1000000000000000001")
        XCTAssertEqual(transfer.plan.fee.atoms, "420000000000000")
        try await client.revalidate(transfer)
        nonce = "0xa"
        await rejects { try await client.revalidate(transfer) }
        nonce = "0x9"; code = "0x1234"
        await rejects { _ = try await client.prepare(wallet: wallet, vaultID: UUID(), recipient: self.recipient, amount: "1") }
        XCTAssertFalse(calls.contains("eth_sendRawTransaction"))
    }

    func testSolanaBindsBlockhashFeesAndDoesNotSkipPreflight() async throws {
        let wallet = try wallet(.solana), recipient = try WalletCrypto.derive(network: .solana).address
        var valid = true, fee: UInt64 = 5000, sent = false
        let client = try rpc(.solana) { method, params in
            switch method {
            case "getGenesisHash": return .string(WalletChain.solanaGenesis)
            case "getBalance": return .object(["value": .integer(10_000_000_000)])
            case "getAccountInfo": return .object(["value": .object(["owner": .string("11111111111111111111111111111111"), "executable": .bool(false)])])
            case "getLatestBlockhash": return .object(["value": .object(["blockhash": .string(WalletChain.solanaGenesis)])])
            case "getFeeForMessage": return .object(["value": .integer(fee)])
            case "isBlockhashValid": return .object(["value": .bool(valid)])
            case "sendTransaction":
                sent = true; let p = try params.values
                XCTAssertEqual(p[1]["skipPreflight"], .bool(false)); XCTAssertEqual(p[1]["maxRetries"], .integer(0))
                XCTAssertNotNil(Data(base64Encoded: try p[0].text)); return .string("fixture-signature")
            default: throw RPCValue.invalid
            }
        }
        let transfer = try await client.prepare(wallet: wallet, vaultID: UUID(), recipient: recipient, amount: "0.125")
        XCTAssertFalse(sent); XCTAssertEqual(transfer.plan.fee.atoms, "5000")
        try await client.revalidate(transfer)
        fee = 5001; await rejects { try await client.revalidate(transfer) }
        fee = 5000; valid = false; await rejects { try await client.revalidate(transfer) }
        let material = try WalletCrypto.derive(network: .solana, recovery: phrase)
        var request = try XCTUnwrap(transfer.plan.transaction); request.action = "sign"; request.privateKey = material.privateKey
        let wire = try NativeSigner.process(request)
        _ = try await client.broadcast(wire, transfer: transfer) // In-memory fake transport only.
        XCTAssertTrue(sent)
    }

    func testBitcoinNeedsTrackedAddressAndUsesExactConfirmedOutputs() async throws {
        let wallet = try wallet(.bitcoin)
        var tracked = false
        let client = try rpc(.bitcoin) { method, _ in
            switch method {
            case "getblockchaininfo": return .object(["chain": .string("main"), "initialblockdownload": .bool(false)])
            case "getaddressinfo": return .object(["iswatchonly": .bool(tracked)])
            case "listunspent": return .array([.object(["address": .string(wallet.address), "safe": .bool(true), "confirmations": .integer(3), "amount": .decimal(Decimal(string: "0.00000001")!)])])
            default: throw RPCValue.invalid
            }
        }
        await rejects { _ = try await client.balance(wallet: wallet) }
        tracked = true
        let balance = try await client.balance(wallet: wallet)
        XCTAssertEqual(balance.available.atoms, "1")
    }

    func testMoneroCompanionStaysLocalMatchesAddressAndNeverRelaysDuringPreparation() async throws {
        #if os(macOS)
        for url in ["https://remote.example/json_rpc", "http://localhost:18082/json_rpc", "http://127.0.0.1.evil.test/json_rpc"] {
            XCTAssertThrowsError(try RPCConfiguration(network: .monero, endpoint: URL(string: url)!, username: "user", password: "password", moneroWalletCompanion: true))
        }
        XCTAssertThrowsError(try RPCConfiguration(network: .monero, endpoint: URL(string: "http://127.0.0.1:18082/json_rpc")!, moneroWalletCompanion: true))
        let wallet = try wallet(.monero), recipient = try WalletCrypto.derive(network: .monero).address
        var matches = false, relayed = false
        let metadata = String(repeating: "ab", count: 128), txid = String(repeating: "12", count: 32)
        let client = try rpc(.monero) { method, params in
            switch method {
            case "get_address": return .object(["address": .string(matches ? wallet.address : recipient)])
            case "validate_address": return .object(["valid": .bool(true), "nettype": .string("mainnet"), "integrated": .bool(false)])
            case "get_balance": return .object(["per_subaddress": .array([.object(["address_index": .integer(0), "address": .string(wallet.address), "balance": .integer(20_000_000_000_000), "unlocked_balance": .integer(10_000_000_000_000)])])])
            case "transfer":
                XCTAssertEqual(params["do_not_relay"], .bool(true)); XCTAssertEqual(params["get_tx_metadata"], .bool(true))
                XCTAssertEqual(try params["destinations"].values[0]["amount"], .integer(1_000_000_000_001))
                XCTAssertEqual(params["subaddr_indices"], .array([.integer(0)]))
                return .object(["amount": .integer(1_000_000_000_001), "fee": .integer(30_000_000), "tx_metadata": .string(metadata), "tx_hash": .string(txid)])
            case "relay_tx": relayed = true; XCTAssertEqual(params["hex"], .string(metadata)); return .object(["tx_hash": .string(txid)])
            default: XCTFail("Unexpected wallet RPC method \(method)"); throw RPCValue.invalid
            }
        }
        await rejects { _ = try await client.balance(wallet: wallet) }
        matches = true
        let transfer = try await client.prepare(wallet: wallet, vaultID: UUID(), recipient: recipient, amount: "1.000000000001")
        XCTAssertFalse(relayed)
        XCTAssertFalse(String(decoding: try Encoding.encode(transfer.plan), as: UTF8.self).contains(metadata))
        try await client.revalidate(transfer)
        let changed = PreparedTransfer(plan: transfer.plan, companionMetadata: "00", endpoint: transfer.endpoint)
        await rejects { try await client.revalidate(changed) }
        let returned = try await client.broadcast(nil, transfer: transfer)
        XCTAssertEqual(returned, txid)
        XCTAssertTrue(relayed)
        #endif
    }

    func testRPCRejectsMismatchedResponseIDAndOversizedPayload() async throws {
        let config = try RPCConfiguration(network: .evm, endpoint: URL(string: "https://rpc.example/")!)
        for data in [Data("{\"id\":\"wrong\",\"result\":\"0x1\"}".utf8), Data(repeating: 32, count: 2 * 1024 * 1024 + 1)] {
            let client = try WalletRPCClient(configuration: config) { request, _, _ in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            await rejects { _ = try await client.call("eth_chainId") }
        }
    }

    func testBitcoinVerifiesFullPrevoutAndRefusesSpentInputsBeforeBroadcast() async throws {
        let wallet = try wallet(.bitcoin), destination = try WalletCrypto.derive(network: .bitcoin).address
        let raw = "0200000001" + String(repeating: "00", count: 32) + "ffffffff0100ffffffff01a086010000000000160014c0cebcd6c3d3ca8c75dc5ec62ebe55330ef910e200000000"
        let txid = SHA256.hash(data: Data(SHA256.hash(data: try Data(strictHex: raw)))).reversed().map { String(format: "%02x", $0) }.joined()
        var spent = false, mismatch = false, broadcasts = 0
        let client = try rpc(.bitcoin) { method, params in
            switch method {
            case "getblockchaininfo": return .object(["chain": .string("main"), "initialblockdownload": .bool(false)])
            case "getaddressinfo": return .object(["iswatchonly": .bool(true)])
            case "listunspent": return .array([.object(["address": .string(wallet.address), "safe": .bool(true), "confirmations": .integer(3), "amount": .decimal(Decimal(string: "0.001")!), "txid": .string(mismatch ? String(repeating: "11", count: 32) : txid), "vout": .integer(0)])])
            case "estimatesmartfee": return .object(["feerate": .decimal(Decimal(string: "0.00002001")!)])
            case "gettransaction": return .object(["hex": .string(raw)])
            case "gettxout":
                XCTAssertEqual(try params.values[0], .string(txid))
                return spent ? .null : .object(["confirmations": .integer(3)])
            case "sendrawtransaction": broadcasts += 1; return .string("fixture")
            default: throw RPCValue.invalid
            }
        }
        let transfer = try await client.prepare(wallet: wallet, vaultID: UUID(), recipient: destination, amount: "0.0005")
        XCTAssertEqual(transfer.plan.transaction?.feeRate, 3) // Round sat/vB upwards, never down.
        XCTAssertEqual(transfer.plan.fee.atoms, "432")
        try await client.revalidate(transfer)
        let material = try WalletCrypto.derive(network: .bitcoin, recovery: phrase)
        var request = try XCTUnwrap(transfer.plan.transaction); request.action = "sign"; request.privateKey = material.privateKey
        let wire = try NativeSigner.process(request)
        XCTAssertEqual(wire.unsigned, transfer.plan.unsigned)
        XCTAssertEqual(wire.inputs, [NativeInput(txid: txid, vout: 0)])
        spent = true; await rejects { try await client.revalidate(transfer) }
        mismatch = true; await rejects { _ = try await client.prepare(wallet: wallet, vaultID: UUID(), recipient: destination, amount: "0.0005") }
        XCTAssertEqual(broadcasts, 0)
    }

    func testLocalCompanionDigestAuthenticationWithRealHTTPTransport() async throws {
        #if os(macOS)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/monero_digest_rpc.py")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["python3", script.path]
        process.standardOutput = pipe; process.standardError = Pipe()
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let data = try XCTUnwrap(pipe.fileHandleForReading.read(upToCount: 6))
        let port = try XCTUnwrap(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/json_rpc"))
        let config = try RPCConfiguration(network: .monero, endpoint: endpoint, username: "fixture", password: "fixture", moneroWalletCompanion: true)
        let result = try await config.checkConnection()
        XCTAssertTrue(result.contains("local Monero wallet companion"))
        let wrong = try RPCConfiguration(network: .monero, endpoint: endpoint, username: "fixture", password: "wrong", moneroWalletCompanion: true)
        await rejects { _ = try await wrong.checkConnection() }
        #endif
    }
}
