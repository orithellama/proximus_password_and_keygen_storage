import SwiftUI
import ProximusKit

struct DeviceApprovalsView: View {
    @ObservedObject var session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @State private var identity: ApprovalIdentity?
    @State private var peers: [ApprovalIdentity] = []
    @State private var candidate: ApprovalIdentity?
    @State private var compared = false
    @State private var busy = false
    @State private var reviewing = false
    @State private var error: ErrorMessage?
    var body: some View {
        NavigationStack {
            ProximusForm {
                ProximusSection("Independent approval devices") {
                    Text("Pair and sync your vault first. Exchange these approval codes in both directions and compare the full fingerprints on the devices’ screens. Then open a wallet’s Security & transfer approvals and choose an approval device.")
                    Text("Proximus enforces this approval before sending. The blockchain still receives a single-key transaction. Anyone with the wallet’s recovery phrase can use it outside Proximus.").font(.caption).foregroundStyle(.secondary)
                }
                ProximusSection("This device") {
                    if let identity {
                        Text(identity.name).font(.headline)
                        Text(identity.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if let code = try? identity.code { TransferCodeOutput(code: code, filename: "Proximus-approval-device.txt") }
                    } else { Button("Show this device’s approval code") { run { identity = try await session.approvalIdentity(name: Platform.deviceName) } } }
                }
                ProximusSection("Trust a paired device") {
                    TransferCodeInput(title: "Device code") { value in candidate = try ApprovalIdentity.decode(value); compared = false }
                    if let candidate {
                        Text(candidate.name).font(.headline)
                        Text(candidate.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Toggle("This fingerprint matches the other device’s screen", isOn: $compared)
                        Button("Trust this device") { run { try await session.trustApprovalDevice(candidate); self.candidate = nil; compared = false; try load() } }.disabled(!compared)
                    }
                }
                if !peers.isEmpty {
                    ProximusSection("Trusted fingerprints on this device") {
                        ForEach(peers) { peer in VStack(alignment: .leading, spacing: 5) { Text(peer.name); Text(peer.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                    }
                }
                ProximusSection { Button("Review a transfer from another device") { reviewing = true } }
                if busy { ProgressView("Waiting for device authentication…") }
            }.appForm().navigationTitle("Device approvals")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(idealWidth: 620, idealHeight: 740).privacySensitive().disabled(busy).errorAlert($error)
            .onAppear { do { try load() } catch { self.error = ErrorMessage(error) } }
            .sheet(isPresented: $reviewing) { ApproveTransferView(session: session) }
            .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { dismiss() } }
    }
    private func load() throws { if let vault = session.state?.header.vaultID { peers = try ApprovalStore.peers(vault: vault) } }
    private func run(_ work: @escaping () async throws -> Void) { busy = true; Task { do { try await work() } catch { self.error = ErrorMessage(error) }; busy = false } }
}

struct ApproveTransferView: View {
    @ObservedObject var session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var request: TransferApprovalRequest?
    @State private var response: TransferApproval?
    @State private var checked = false
    @State private var busy = false
    @State private var error: ErrorMessage?
    var body: some View {
        NavigationStack {
            ProximusForm {
                if let request {
                    ProximusSection("Requested by " + request.requester.name) { TransferReviewFields(plan: request.plan) }
                    if let response, let code = try? response.code {
                        ProximusSection("Return this approval to the sending device") { TransferCodeOutput(code: code, filename: "Proximus-transfer-approval.txt") }
                    } else {
                        ProximusSection {
                            Toggle("I checked the chain, full recipient address, amount, and fee", isOn: $checked)
                            Button("Authenticate & approve transfer") { approve(request) }.disabled(!checked || busy)
                            Text("Approval is valid only for this exact transfer until its review expires. The sending device still needs to authenticate and submit it.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProximusSection("Transfer request") { TransferCodeInput(title: "Transfer request") { code in let value = try TransferApprovalRequest.decode(code); try session.validateApprovalRequest(value); request = value; checked = false } }
                }
                if busy { ProgressView("Waiting for device authentication…") }
            }.appForm().navigationTitle("Approve transfer")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
        }.frame(idealWidth: 620, idealHeight: 760).privacySensitive().errorAlert($error).interactiveDismissDisabled(busy)
            .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { clear() } }
            .onChange(of: phase) { _, value in if value == .background { clear() } }
    }
    private func clear() { request = nil; response = nil; checked = false; dismiss() }
    private func approve(_ request: TransferApprovalRequest) { busy = true; Task { do { let value = try await session.approveTransfer(request); if session.isUnlocked && phase != .background { response = value } } catch { self.error = ErrorMessage(error) }; busy = false } }
}

struct WalletApprovalPolicyView: View {
    @ObservedObject var session: VaultSession
    let wallet: WalletMetadata
    @Environment(\.dismiss) private var dismiss
    @State private var peers: [ApprovalIdentity] = []
    @State private var current: ApprovalIdentity?
    @State private var selected = ""
    @State private var devices = false
    @State private var busy = false
    @State private var error: ErrorMessage?
    var body: some View {
        NavigationStack {
            ProximusForm {
                ProximusSection("Required before sending") {
                    Text(current.map { "Current approver: " + $0.name } ?? "This wallet currently uses this device’s authentication only.")
                    ProximusPicker(title: "Approval device", selection: $selected, options: [("", "This device only")] + peers.map { ($0.deviceID.uuidString, $0.name) })
                    Button("Save approval requirement") { save() }
                    Button("Set up device fingerprints…") { devices = true }
                    Text("Changing this setting requires device authentication. Approval settings and fingerprints stay on this device; they are not included in vault sync or recovery kits.").font(.caption).foregroundStyle(.secondary)
                }
                ProximusSection { Text("This is an app approval policy, not blockchain multisig. It does not protect against a compromised signing device or someone using the recovery phrase in another wallet.").font(.caption).foregroundStyle(.secondary) }
                if busy { ProgressView() }
            }.appForm().navigationTitle("Wallet device approval")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(idealWidth: 540, idealHeight: 480).disabled(busy).errorAlert($error)
            .onAppear { load() }.sheet(isPresented: $devices, onDismiss: load) { DeviceApprovalsView(session: session) }
            .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { dismiss() } }
    }
    private func load() { do { if let vault = session.state?.header.vaultID { peers = try ApprovalStore.peers(vault: vault).filter { peer in peer.deviceID != session.deviceID && session.contents?.devices.contains(where: { $0.id == peer.deviceID }) == true } }; current = try ApprovalStore.policy(wallet: wallet.id); selected = current?.deviceID.uuidString ?? "" } catch { self.error = ErrorMessage(error) } }
    private func save() { busy = true; Task { do { let peer = peers.first { $0.deviceID.uuidString == selected }; if !selected.isEmpty && peer == nil { throw ProximusError.invalid("Choose a trusted device.") }; try await session.setApprovalDevice(peer, wallet: wallet); load() } catch { self.error = ErrorMessage(error) }; busy = false } }
}
