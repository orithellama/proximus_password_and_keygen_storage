import SwiftUI
import ProximusKit

struct WalletCreator: View {
    @ObservedObject var session: VaultSession
    var created: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var network: WalletNetwork = .solana
    @State private var title = ""
    @State private var restoring = false
    @State private var recovery = ""
    @State private var busy = false
    @State private var error: ErrorMessage?
    var body: some View {
        NavigationStack {
            ProximusForm {
                ProximusSection("Your wallet") {
                    TextField("Name, e.g. Personal or Savings", text: $title)
                    ProximusPicker(title: "Blockchain", selection: $network, options: WalletNetwork.allCases.map { ($0, $0.label) })
                    Toggle("Restore an existing wallet", isOn: $restoring)
                }
                if restoring {
                    ProximusSection(network.recoveryLabel) {
                        SecureField(network == .monero ? "Private spend key" : "Recovery words", text: $recovery)
                        Text(network == .monero ? "Restores a deterministic Monero wallet. The private view key is derived from the spend key." : "English BIP-39 phrases only, with no extra BIP-39 passphrase. Proximus restores the first address at the derivation path shown below.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ProximusSection("Recovery and device storage") {
                    Text("Paired devices receive the address and label. Keep recovery details separately or enable an encrypted recovery kit in Settings. Standard vault exports do not include wallet keys.")
                    Text("Connect a network in Wallet networks to check balances and send native coins. Monero sending uses a local wallet companion on Mac.").font(.caption).foregroundStyle(.secondary)
                    if !HardwareUnlock.isAvailable { Text("A device with Secure Enclave and a device passcode is required.").foregroundStyle(.secondary) }
                }
                ProximusSection { DisclosureGroup("Technical details") {
                    Text(path).font(.system(.callout, design: .monospaced))
                    Text(network == .evm ? "This address works on EVM networks. The sender and recipient must choose the same network." : "Mainnet").font(.caption).foregroundStyle(.secondary)
                } }
                if busy { ProgressView("Preparing device-protected keys…") }
            }.appForm().navigationTitle(restoring ? "Restore wallet" : "Create wallet")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(restoring ? "Restore" : "Create") { create() }.disabled(busy || !HardwareUnlock.isAvailable || (restoring && recovery.isEmpty)) }
                }
        }.frame(idealWidth: 560, idealHeight: 610).privacySensitive().errorAlert($error)
            .interactiveDismissDisabled(busy).disabled(busy)
            .onChange(of: network) { _, _ in recovery = "" }
            .onDisappear { recovery = "" }
    }
    private var path: String { switch network { case .solana: return "m/44'/501'/0'/0'"; case .evm: return "m/44'/60'/0'/0/0"; case .bitcoin: return "m/84'/0'/0'/0/0 (native SegWit)"; case .monero: return "Standard deterministic Monero address" } }
    private func create() {
        busy = true
        Task {
            do {
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = try await session.createWallet(network: network, title: name.isEmpty ? network.label + " wallet" : name, recovery: restoring ? recovery : "")
                recovery = ""; created(id); dismiss()
            } catch { self.error = ErrorMessage(error) }
            busy = false
        }
    }
}

struct WalletDetails: View {
    @ObservedObject var session: VaultSession
    let metadata: WalletMetadata
    @State private var recovery = false
    @State private var sending = false
    @State private var receiving = false
    @State private var nodes = false
    @State private var approvals = false
    @State private var refreshing = false
    @State private var receipt: TransferReceipt?
    @State private var error: ErrorMessage?
    private var local: Bool { metadata.ownerDeviceID == session.deviceID }
    private var balance: WalletBalance? { session.walletBalances[metadata.id] }
    private var supportsWalletRPC: Bool {
        #if os(iOS)
        return metadata.network != .monero
        #else
        return true
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppCard {
                Label(balance?.chain.display ?? metadata.network.coinLabel, systemImage: "network").font(Theme.body(14).weight(.semibold)).foregroundStyle(Theme.accent)
                Text("Available balance").font(Theme.body(13)).foregroundStyle(Theme.muted)
                if let balance {
                    Text(balance.chain.amount(balance.available)).font(Theme.heading(32)).fixedSize(horizontal: false, vertical: true)
                    if balance.total != balance.available { Text("Including locked funds: " + balance.chain.amount(balance.total)).font(.caption).foregroundStyle(Theme.muted) }
                    Text(balance.detail).font(.caption).foregroundStyle(Theme.muted)
                    Text("Checked " + balance.checkedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(Theme.muted)
                } else {
                    Text("—").font(Theme.heading(32))
                    Text(supportsWalletRPC ? "Connect a network, then check your balance. Nothing is sent until you choose Send and approve a transfer." : "Check your Monero balance on your Mac.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                }
                ViewThatFits(in: .horizontal) { HStack(spacing: 12) { transferActions }; VStack(alignment: .leading, spacing: 12) { transferActions } }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { balanceActions }
                    VStack(alignment: .leading, spacing: 14) { balanceActions }
                }
            }
            AppCard {
                Text("Your public address").font(Theme.body(13)).foregroundStyle(Theme.muted)
                Text(metadata.address).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                CopyValueButton(value: metadata.address, title: "Copy address").buttonStyle(ProximusButtonStyle())
                Text("Share this address to receive crypto. Always use the same network on both sides.").font(.caption).foregroundStyle(Theme.muted)
            }
            if local {
                ActionRow(title: "Wallet recovery", subtitle: "View and back up the keys for this wallet.", symbol: "key.viewfinder") { recovery = true }
                DisclosureGroup("Security & transfer approvals") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Keys are protected on this device", systemImage: "lock.shield").foregroundStyle(Theme.accent)
                        Button("Require approval from another device") { approvals = true }.buttonStyle(ProximusButtonStyle())
                        Text("Pairing shares only this address. To recover keys, save the recovery details or set up an encrypted recovery kit.").font(.callout).foregroundStyle(Theme.muted)
                        Text("Signing and revealing keys puts them in app memory. A compromised device can expose them; this app cannot provide the isolation of a dedicated hardware wallet.").font(.caption).foregroundStyle(Theme.muted)
                    }.padding(.top, 12)
                }
            } else {
                AppCard {
                    Label("Address only on this device", systemImage: "eye").foregroundStyle(Theme.accent)
                    Text("You can receive crypto and view this address here. To send, open Proximus on the device that holds the keys, or restore the wallet from its recovery backup.").font(.callout).foregroundStyle(Theme.muted)
                }
            }
            #if os(iOS)
            if metadata.network == .monero { Text("Monero balances and sending use the local wallet companion on Mac. Your address and recovery details remain available here.").font(.caption).foregroundStyle(Theme.muted) }
            #endif
            if let receipt { AppCard { Text("Latest transfer").font(.headline); TransferReceiptView(receipt: receipt, wallet: metadata).id(receipt.id) } }
            DisclosureGroup("Technical details") { Text(metadata.derivationPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 8) }
        }.sheet(isPresented: $recovery) { WalletRecoveryView(session: session, metadata: metadata) }
            .sheet(isPresented: $receiving) { ReceiveCryptoView(metadata: metadata, chain: balance?.chain.display) }
            .sheet(isPresented: $sending, onDismiss: loadReceipt) { SendCryptoView(session: session, wallet: metadata) }
            .sheet(isPresented: $approvals) { WalletApprovalPolicyView(session: session, wallet: metadata) }
            .sheet(isPresented: $nodes, onDismiss: { session.clearWalletBalances() }) { NavigationStack { RPCSettingsView(network: metadata.network).toolbar { Button("Done") { nodes = false } } }.frame(idealWidth: 620, idealHeight: 700) }
            .onAppear(perform: loadReceipt).errorAlert($error)
    }
    @ViewBuilder private var transferActions: some View {
        if local { Button { sending = true } label: { Label("Send", systemImage: "arrow.up.right") }.buttonStyle(ProximusButtonStyle(.primary)).disabled(!supportsWalletRPC) }
        Button { receiving = true } label: { Label("Receive", systemImage: "qrcode") }.buttonStyle(ProximusButtonStyle()).controlSize(.large)
    }
    @ViewBuilder private var balanceActions: some View {
        Button { refresh() } label: { Label(refreshing ? "Checking…" : "Refresh balance", systemImage: "arrow.clockwise") }.disabled(refreshing || !supportsWalletRPC)
        Button("Network settings") { nodes = true }
        if refreshing { ProgressView().controlSize(.small) }
    }
    private func refresh() { refreshing = true; Task { do { try await session.refreshWalletBalance(metadata) } catch { self.error = ErrorMessage(error) }; refreshing = false } }
    private func loadReceipt() { do { receipt = try TransferReceipt.load(wallet: metadata.id) } catch { self.error = ErrorMessage(error) } }
}

struct ReceiveCryptoView: View {
    let metadata: WalletMetadata
    let chain: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text("Receive crypto").font(Theme.heading(26))
                    Label(chain ?? metadata.network.coinLabel, systemImage: "network").foregroundStyle(Theme.accent)
                    QRCodeView(value: metadata.address).frame(width: 240, height: 240).accessibilityLabel("Your public wallet address")
                    AppCard {
                        Text("Your public address").font(Theme.body(13)).foregroundStyle(Theme.muted)
                        Text(metadata.address).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        CopyValueButton(value: metadata.address, title: "Copy address").buttonStyle(ProximusButtonStyle(.primary))
                    }
                    Text(metadata.network == .evm && chain == nil ? "Agree on the EVM network with the sender before they send. This address can be used on multiple networks." : "Ask the sender to use the network shown above. Using the wrong network can lose funds.").font(.callout).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                    Text("Sharing this address works offline. A payment still needs an internet-connected blockchain node to be sent and confirmed.").font(.caption).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }.background(Theme.background).navigationTitle("Receive")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(idealWidth: 520, idealHeight: 700)
    }
}

struct WalletRecoveryView: View {
    @ObservedObject var session: VaultSession
    let metadata: WalletMetadata
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var material: WalletMaterial?
    @State private var busy = false
    @State private var closed = false
    @State private var copyValue: String?
    @State private var copyNotice = false
    @State private var error: ErrorMessage?
    @State private var revealID = UUID()
    var body: some View {
        NavigationStack {
            ProximusForm {
                ProximusSection {
                    Text("Anyone with these recovery details can control this wallet. Write them down and keep them somewhere private. Standard vault exports exclude wallet keys. Optional encrypted recovery kits include keys held on this device.")
                    Text(metadata.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let material {
                    ProximusSection(metadata.network.recoveryLabel) { secret(material.recovery) }
                    if metadata.network != .monero { ProximusSection(metadata.network.privateKeyLabel) { secret(material.privateKey) } }
                    if metadata.network == .monero {
                        ProximusSection("Private view key (hex)") { secret(material.secondaryPrivateKey) }
                        ProximusSection { Text("Restore from keys in a compatible Monero wallet using the address, spend key, and view key. If the original restore height is unknown, scan from height 0. This is not a Monero word mnemonic.").font(.caption) }
                    }
                    ProximusSection { Text("Recovery details hide automatically after 60 seconds.").font(.caption); Button("Hide now") { clear() } }
                } else {
                    ProximusSection { Button("Unlock recovery details") { reveal() }.disabled(busy); if busy { ProgressView("Waiting for device authentication…") } }
                }
            }.appForm().navigationTitle("Wallet recovery")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { clear(); dismiss() } } }
        }.frame(idealWidth: 620, idealHeight: 650).privacySensitive().errorAlert($error)
            .task(id: revealID) { guard material != nil else { return }; try? await Task.sleep(for: .seconds(60)); if !Task.isCancelled { clear() } }
            .onDisappear { closed = true; clear() }
            .onChange(of: phase) { _, value in if value == .background { closed = true; clear(); dismiss() } }
            .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { closed = true; clear(); dismiss() } }
            .alert("Copy wallet secret?", isPresented: $copyNotice) {
                Button("Cancel", role: .cancel) { copyValue = nil }
                Button("Copy for 30 seconds") { if let value = copyValue { Platform.copySecret(value) }; copyValue = nil }
            } message: { Text("Other software may read your clipboard. Anyone with this secret can control the wallet.") }
    }
    private func secret(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(value).font(.system(.callout, design: .monospaced)); Button("Copy") { copyValue = value; copyNotice = true } }
    }
    private func clear() { material = nil; copyValue = nil; copyNotice = false }
    private func reveal() {
        busy = true
        Task {
            do { let result = try await session.revealWallet(metadata); if !closed && phase != .background && session.isUnlocked { material = result; revealID = UUID() } }
            catch { if !closed { self.error = ErrorMessage(error) } }
            busy = false
        }
    }
}
