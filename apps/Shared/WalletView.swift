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
            Form {
                Section("Wallet") {
                    TextField("Name", text: $title)
                    Picker("Network", selection: $network) { ForEach(WalletNetwork.allCases) { Text($0.label).tag($0) } }
                    Toggle("Restore an existing wallet", isOn: $restoring)
                }
                if restoring {
                    Section(network.recoveryLabel) {
                        SecureField(network == .monero ? "Private spend key" : "Recovery words", text: $recovery)
                        Text(network == .monero ? "Restores a deterministic Monero wallet. The private view key is derived from the spend key." : "English BIP-39 phrases only, with no extra BIP-39 passphrase. Proximus restores the first address at the derivation path shown below.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Recovery and device storage") {
                    Text("Paired devices receive the address and label. Keep recovery details separately or enable an encrypted recovery kit in Settings. Standard vault exports do not include wallet keys.")
                    Text("Keys and addresses only. Transaction signing, balances, and transfers are not included.").foregroundStyle(.secondary)
                    if !HardwareUnlock.isAvailable { Text("A device with Secure Enclave and a device passcode is required.").foregroundStyle(.secondary) }
                }
                Section("Address format") {
                    Text(path).font(.system(.callout, design: .monospaced))
                    Text(network == .evm ? "The same address can be used on EVM networks. Always check the destination network before using it." : "Mainnet").font(.caption).foregroundStyle(.secondary)
                }
                if busy { ProgressView("Preparing device-protected keys…") }
            }.formStyle(.grouped).navigationTitle(restoring ? "Restore wallet" : "Create wallet")
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
    private var local: Bool { metadata.ownerDeviceID == session.deviceID }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(metadata.network.label, systemImage: "wallet.bifold").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text(metadata.network == .evm ? "Public address" : "Mainnet address").font(.caption).foregroundStyle(.secondary)
                Text(metadata.address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button("Copy address") { Platform.copyPublic(metadata.address) }
            }
            QRCodeView(value: metadata.address).frame(width: 180, height: 180).accessibilityLabel("Wallet public address QR code")
            Text(metadata.derivationPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Label(local ? "Keys stay on this device" : "Address only on this device", systemImage: local ? "lock.shield" : "eye").foregroundStyle(Theme.accent)
            if local {
                Button("Back up or reveal recovery details") { recovery = true }.buttonStyle(.bordered)
                Text("Save recovery details separately or use an encrypted recovery kit. Pairing and standard vault exports contain the public address only.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Open Proximus on the original device to back up its keys, or restore the wallet here from your separate recovery backup.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Keys are encrypted with device protection. Revealing them brings them into app memory. This app does not provide the isolation of a dedicated hardware wallet.").font(.caption).foregroundStyle(.secondary)
        }.sheet(isPresented: $recovery) { WalletRecoveryView(session: session, metadata: metadata) }
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
            Form {
                Section {
                    Text("Anyone with these recovery details can control this wallet. Write them down and keep them somewhere private. They are not included in your vault recovery kit.")
                    Text(metadata.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let material {
                    Section(metadata.network.recoveryLabel) { secret(material.recovery) }
                    if metadata.network != .monero { Section(metadata.network.privateKeyLabel) { secret(material.privateKey) } }
                    if metadata.network == .monero {
                        Section("Private view key (hex)") { secret(material.secondaryPrivateKey) }
                        Section { Text("Restore from keys in a compatible Monero wallet using the address, spend key, and view key. If the original restore height is unknown, scan from height 0. This is not a Monero word mnemonic.").font(.caption) }
                    }
                    Section { Text("Recovery details hide automatically after 60 seconds.").font(.caption); Button("Hide now") { clear() } }
                } else {
                    Section { Button("Unlock recovery details") { reveal() }.disabled(busy); if busy { ProgressView("Waiting for device authentication…") } }
                }
            }.formStyle(.grouped).navigationTitle("Wallet recovery")
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
