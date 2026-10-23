import SwiftUI
import ProximusKit

struct RecoverySettingsView: View {
    @ObservedObject var session: VaultSession
    @State private var password = ""
    @State private var confirmation = ""
    @State private var saved = false
    @State private var folder: Data?
    @State private var folderName = ""
    @State private var choosing = false
    @State private var busy = false
    @State private var error: ErrorMessage?
    var body: some View {
        Form {
            Section("Encrypted recovery kit") {
                Text(session.recoveryStatus)
                Text("Includes your vault and the recovery phrases/private keys held on this device. Hardware passkeys are not exportable. Wallets held only on other devices contribute addresses only.").font(.callout)
                Text("Choose a folder in iCloud Drive to sync encrypted kits through your Apple account. Proximus encrypts before writing. Your separate backup password is required on a replacement device.").font(.caption).foregroundStyle(.secondary)
            }
            Section(session.hasRecoveryBackup ? "Replace backup settings" : "Set up automatic backup") {
                SecureField("Backup password - at least 16 characters", text: $password)
                SecureField("Repeat backup password", text: $confirmation)
                Button(folderName.isEmpty ? "Choose a folder in iCloud Drive" : folderName) { choosing = true }
                Toggle("I saved the backup password separately", isOn: $saved)
                Button("Enable encrypted backup") { run { guard let folder else { return }; try await session.enableRecoveryBackup(password: password, folder: folder); password = ""; confirmation = ""; saved = false } }
                    .disabled(password.utf8.count < 16 || password != confirmation || folder == nil || !saved || busy || !HardwareUnlock.isAvailable)
            }
            if session.hasRecoveryBackup {
                Section {
                    Button("Resume backup / back up now") { run { try await session.resumeRecoveryBackup() } }
                    Button("Turn off automatic backup", role: .destructive) { run { try await session.disableRecoveryBackup() } }
                    Text("Turning off backup leaves existing files in the selected folder. Changing the backup password does not revoke copies encrypted with the old password.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Automatic saving") {
                Text("Changes save while the vault and backup session are unlocked. Device authentication resumes backups after unlock. A canceled prompt pauses backup until you resume it. iCloud needs internet to upload, and older copies may remain in its history.").font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView("Preparing encrypted recovery…") }
        }.formStyle(.grouped).navigationTitle("iCloud & recovery").privacySensitive().disabled(busy).errorAlert($error)
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                do { let url = try result.get(); folder = try RecoveryFolder.bookmark(url); folderName = url.lastPathComponent } catch { self.error = ErrorMessage(error) }
            }
            .onDisappear { password = ""; confirmation = "" }
    }
    private func run(_ work: @escaping () async throws -> Void) { busy = true; Task { do { try await work() } catch { self.error = ErrorMessage(error) }; busy = false } }
}

struct RPCSettingsView: View {
    @State private var network: WalletNetwork = .solana
    @State private var companion = false
    @State private var endpoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var busy = false
    @State private var error: ErrorMessage?
    init(network: WalletNetwork = .solana) { _network = State(initialValue: network) }
    var body: some View {
        Form {
            Section("Your node") {
                Picker("Network", selection: $network) { ForEach(WalletNetwork.allCases) { Text($0.label).tag($0) } }
                TextField("HTTPS RPC endpoint", text: $endpoint)
                TextField("RPC username (optional)", text: $username)
                SecureField("RPC password (optional)", text: $password)
                if network == .evm { Text("Supported: Ethereum, BNB Smart Chain, Polygon PoS, Avalanche C-Chain, and Sepolia testnet. The app reads the chain ID before showing a balance or preparing a transfer.").font(.caption) }
                if network == .bitcoin { Text("Use the Bitcoin Core wallet endpoint, for example http://127.0.0.1:8332/wallet/proximus. Import your public address as a watch-only descriptor and rescan before refreshing. Core never needs your private keys.").font(.caption) }
                if network == .monero {
                    #if os(macOS)
                    Toggle("Local wallet companion (balances & sending)", isOn: $companion)
                    #endif
                    Text(companion ? "Use monero-wallet-rpc at http://127.0.0.1:18082/json_rpc with RPC username/password. Open the matching mainnet wallet and let it sync first. It has its own wallet storage; Proximus never transfers keys to it. Digest authentication is supported." : "Use the daemon’s /json_rpc endpoint for connection checks. Balances and sending require the local wallet companion on Mac.").font(.caption)
                }
                Button("Save on this device") { do { try configuration().save(); status = "Saved in this device’s Keychain." } catch { self.error = ErrorMessage(error) } }
                Button("Check connection") {
                    busy = true; status = ""
                    Task { do { status = try await configuration().checkConnection() } catch { self.error = ErrorMessage(error) }; busy = false }
                }
                Button("Remove saved endpoint", role: .destructive) { do { try RPCConfiguration.remove(network); endpoint = ""; username = ""; password = ""; status = "Removed" } catch { self.error = ErrorMessage(error) } }
            }
            Section {
                Text("Connection checks request node information. Refreshing a wallet shares its public address with this node. Sending submits the reviewed signed transaction. Recovery phrases and private keys are never sent to the RPC. Endpoints and credentials stay on this device and are excluded from recovery kits.")
                Text("Nearby devices can exchange addresses and approval codes offline. Blockchain payments need a connected node to broadcast and the network to confirm them.").font(.caption).foregroundStyle(.secondary)
                Text("A successful connection check is the node’s response, not proof that the node is honest.").font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView() }
            if !status.isEmpty { Text(status).textSelection(.enabled) }
        }.formStyle(.grouped).navigationTitle("Custom RPC nodes").privacySensitive().disabled(busy).errorAlert($error)
            .onAppear { load() }.onChange(of: network) { _, _ in load() }.onDisappear { password = "" }
    }
    private func configuration() throws -> RPCConfiguration {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ProximusError.invalid("Enter an RPC endpoint.") }
        return try RPCConfiguration(network: network, endpoint: url, username: username, password: password, moneroWalletCompanion: network == .monero && companion)
    }
    private func load() { do { let saved = try RPCConfiguration.load(network); endpoint = saved?.endpoint.absoluteString ?? ""; username = saved?.username ?? ""; password = saved?.password ?? ""; companion = saved?.moneroWalletCompanion == true; status = "" } catch { self.error = ErrorMessage(error) } }
}
