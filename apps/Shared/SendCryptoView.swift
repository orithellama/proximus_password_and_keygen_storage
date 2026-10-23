import SwiftUI
import ProximusKit

struct SendCryptoView: View {
    @ObservedObject var session: VaultSession
    let wallet: WalletMetadata
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var recipient = ""
    @State private var amount = ""
    @State private var transfer: PreparedTransfer?
    @State private var client: WalletRPCClient?
    @State private var peer: ApprovalIdentity?
    @State private var requestCode: String?
    @State private var approval: TransferApproval?
    @State private var receipt: TransferReceipt?
    @State private var checked = false
    @State private var busy = false
    @State private var confirmAnother = false
    @State private var scanning = false
    @State private var error: ErrorMessage?
    @State private var work: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                if let receipt {
                    Section("Transfer record") { TransferReceiptView(receipt: receipt, wallet: wallet) }
                    Section { Button("Create another transfer") { confirmAnother = true } }
                } else if let transfer {
                    Section("Review transfer") { TransferReviewFields(plan: transfer.plan) }
                    if let peer {
                        Section("Approval from " + peer.name) {
                            if let approval {
                                Label("Approval verified for this transfer", systemImage: "checkmark.shield.fill").foregroundStyle(Theme.accent)
                                Text(approval.deviceID.uuidString).font(.caption).foregroundStyle(.secondary)
                            } else {
                                if let requestCode { TransferCodeOutput(code: requestCode, filename: "Proximus-transfer-request.txt") }
                                else { Button("Create approval request") { requestApproval(transfer.plan) } }
                                Text("On your other device, open Device approvals → Review a transfer. Return its approval here. Both devices must already trust each other’s fingerprints.").font(.caption).foregroundStyle(.secondary)
                                TransferCodeInput(title: "Returned approval") { code in
                                    let response = try TransferApproval.decode(code)
                                    try response.validate(plan: transfer.plan, peer: peer)
                                    approval = response
                                }
                            }
                        }
                    }
                    Section {
                        Toggle("I checked the chain, full recipient address, amount, and fee", isOn: $checked)
                        Button("Authenticate & send " + transfer.plan.chain.amount(transfer.plan.amount)) { send(transfer) }
                            .buttonStyle(.borderedProminent).disabled(!checked || (peer != nil && approval == nil))
                        Button("Edit transfer") { clearReview() }
                        Text("This sends a real blockchain transaction. Submission is not confirmation. Proximus will retain its transaction ID if the node times out.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Native coin transfer") {
                        Label(wallet.network.coinLabel, systemImage: "wallet.bifold")
                        TextField("Recipient address", text: $recipient)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        #if os(iOS)
                        Button("Scan recipient address") { scanning = true }
                        #endif
                        TextField("Amount", text: $amount)
                        if let balance = session.walletBalances[wallet.id] { LabeledContent("Last available balance", value: balance.chain.amount(balance.available)) }
                        Button(wallet.network == .monero ? "Prepare with local companion" : "Review transfer") { prepare() }.disabled(recipient.isEmpty || amount.isEmpty)
                        if wallet.network == .monero { Text("The local Mac companion must already have this wallet loaded and synced. Preparing signs inside the companion with relay disabled; final review and device approval control broadcasting.").font(.caption).foregroundStyle(.secondary) }
                        Text("Supports native coins. Tokens, contract calls, integrated Monero payment IDs, and send-max are not supported.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if busy { ProgressView(transfer == nil ? "Preparing transfer…" : "Authenticating / checking the network…") }
            }.formStyle(.grouped).navigationTitle("Send crypto")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(receipt == nil ? "Cancel" : "Done") { dismiss() }.disabled(busy) } }
        }.frame(idealWidth: 640, idealHeight: 780).privacySensitive().disabled(busy).errorAlert($error).interactiveDismissDisabled(busy)
            .onAppear { do { receipt = try TransferReceipt.load(wallet: wallet.id) } catch { self.error = ErrorMessage(error) } }
            .onDisappear { work?.cancel(); clearReview() }
            .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { work?.cancel(); clearReview(); dismiss() } }
            .onChange(of: phase) { _, value in if value == .background { work?.cancel(); clearReview(); dismiss() } }
            .confirmationDialog("Create a separate transfer?", isPresented: $confirmAnother, titleVisibility: .visible) {
                Button("I checked the previous transaction; create another") { receipt = nil; recipient = ""; amount = ""; clearReview() }
            } message: { Text("An unknown or pending transaction may still confirm. A new transfer could pay the recipient twice.") }
            #if os(iOS)
            .sheet(isPresented: $scanning) { NavigationStack {
                QRScanner(onCode: { value in recipient = value; scanning = false }, onError: { value in scanning = false; error = ErrorMessage(ProximusError.invalid(value)) })
                    .navigationTitle("Scan recipient address").toolbar { Button("Cancel") { scanning = false } }
            } }
            #endif
    }
    private func clearReview() { transfer = nil; client = nil; requestCode = nil; approval = nil; checked = false; peer = nil }
    private func run(_ operation: @escaping () async throws -> Void) { busy = true; work = Task { do { try await operation() } catch { if !Task.isCancelled { self.error = ErrorMessage(error) } }; busy = false } }
    private func prepare() { run {
        guard let configuration = try RPCConfiguration.load(wallet.network) else { throw ProximusError.unavailable("Add your node in RPC settings first.") }
        let rpc = try WalletRPCClient(configuration: configuration)
        let prepared = try await session.prepareTransfer(wallet: wallet, client: rpc, recipient: recipient, amount: amount)
        try Task.checkCancellation()
        peer = try ApprovalStore.policy(wallet: wallet.id); transfer = prepared; client = rpc
    } }
    private func requestApproval(_ plan: TransferPlan) { run { let request = try await session.makeApprovalRequest(plan, deviceName: Platform.deviceName); try Task.checkCancellation(); requestCode = try request.code } }
    private func send(_ transfer: PreparedTransfer) { run {
        guard let client else { throw ProximusError.authentication }
        let result = try await session.sendTransfer(transfer, client: client, approval: approval)
        if !Task.isCancelled { receipt = result; clearReview() }
    } }
}

struct TransferReceiptView: View {
    let receipt: TransferReceipt
    let wallet: WalletMetadata
    @State private var status = ""
    @State private var busy = false
    @State private var error: ErrorMessage?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(receipt.chain.amount(receipt.amount)).font(.title2.bold())
            Text(receipt.chain.display).foregroundStyle(Theme.accent)
            Text(status.isEmpty ? receipt.status : status).font(.callout)
            Text("Transaction ID").font(.caption).foregroundStyle(.secondary)
            Text(receipt.transactionID).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text("To: " + receipt.recipient).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(receipt.date.formatted()).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy transaction ID") { Platform.copyPublic(receipt.transactionID) }
                Button("Check confirmation") { refresh() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
        }.errorAlert($error)
    }
    private func refresh() { busy = true; Task { do {
        guard let configuration = try RPCConfiguration.load(wallet.network) else { throw ProximusError.unavailable("Configure this wallet’s RPC first.") }
        status = try await WalletRPCClient(configuration: configuration).status(receipt, wallet: wallet)
    } catch { self.error = ErrorMessage(error) }; busy = false } }
}
