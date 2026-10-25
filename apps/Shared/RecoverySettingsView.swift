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
        ProximusForm {
            ProximusSection {
                Label(session.hasRecoveryBackup ? "Automatic backup is set up" : "Keep a way to recover your vault", systemImage: "icloud").font(.headline).foregroundStyle(Theme.accent)
                Text(session.hasRecoveryBackup ? session.recoveryStatus : "Save an encrypted copy of your passwords and wallet keys in iCloud Drive. You choose the folder and a separate backup password.").font(.callout).foregroundStyle(Theme.muted)
            }
            ProximusSection { DisclosureGroup("What’s included?") {
                Text("Your passwords, notes, and the wallet recovery keys held on this device. Wallets held on other devices include addresses only. Passkeys stay on the device where they were created.").font(.callout).foregroundStyle(Theme.muted)
                Text("On a replacement device, choose Restore an iCloud recovery kit from the welcome screen. You’ll need the backup password below.").font(.caption).foregroundStyle(Theme.muted)
            } }
            ProximusSection(session.hasRecoveryBackup ? "Change backup settings" : "Set up your backup") {
                SecureField("1. Backup password (at least 16 characters)", text: $password)
                SecureField("Repeat backup password", text: $confirmation)
                Button(folderName.isEmpty ? "2. Choose a folder in iCloud Drive" : "Folder: " + folderName) { choosing = true }
                Toggle("3. I saved the backup password somewhere safe", isOn: $saved)
                if !confirmation.isEmpty && password != confirmation { Text("The backup passwords don’t match yet.").font(.caption).foregroundStyle(Theme.muted) }
                Button("Turn on encrypted backup") { run { guard let folder else { return }; try await session.enableRecoveryBackup(password: password, folder: folder); password = ""; confirmation = ""; saved = false } }
                    .disabled(password.utf8.count < 16 || password != confirmation || folder == nil || !saved || busy || !HardwareUnlock.isAvailable)
            }
            if session.hasRecoveryBackup {
                ProximusSection {
                    Button("Back up now") { run { try await session.resumeRecoveryBackup() } }
                    Button("Turn off automatic backup", role: .destructive) { run { try await session.disableRecoveryBackup() } }
                    Text("Turning off backup leaves existing files in the selected folder. Changing the backup password does not revoke copies encrypted with the old password.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProximusSection("Automatic saving") {
                Text("Changes save while the vault and backup session are unlocked. Device authentication resumes backups after unlock. A canceled prompt pauses backup until you resume it. iCloud needs internet to upload, and older copies may remain in its history.").font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView("Preparing encrypted recovery…") }
        }.appForm().navigationTitle("Backup & recovery").privacySensitive().disabled(busy).errorAlert($error)
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
        ProximusForm {
            ProximusSection {
                Label("Connect your wallet to a blockchain", systemImage: "network").font(.headline)
                Text("A network connection checks balances and sends transactions you approve. Your recovery phrases and private keys are not sent to this server.").font(.callout).foregroundStyle(Theme.muted)
            }
            ProximusSection("Network connection") {
                ProximusPicker(title: "Blockchain", selection: $network, options: WalletNetwork.allCases.map { ($0, $0.label) })
                TextField("Server address (HTTPS RPC URL)", text: $endpoint).autocorrectionDisabled()
                DisclosureGroup("Server login, if required") {
                    TextField("Username", text: $username).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                if network == .evm { Text("Supported: Ethereum, BNB Smart Chain, Polygon PoS, Avalanche C-Chain, and Sepolia testnet. The app reads the chain ID before showing a balance or preparing a transfer.").font(.caption) }
                if network == .bitcoin { Text("Use the Bitcoin Core wallet endpoint, for example http://127.0.0.1:8332/wallet/proximus. Import your public address as a watch-only descriptor and rescan before refreshing. Core never needs your private keys.").font(.caption) }
                if network == .monero {
                    #if os(macOS)
                    Toggle("Local wallet companion (balances & sending)", isOn: $companion)
                    #endif
                    Text(companion ? "Use monero-wallet-rpc at http://127.0.0.1:18082/json_rpc with RPC username/password. Open the matching mainnet wallet and let it sync first. It has its own wallet storage; Proximus never transfers keys to it. Digest authentication is supported." : "Use the daemon’s /json_rpc endpoint for connection checks. Balances and sending require the local wallet companion on Mac.").font(.caption)
                }
                Button("Save connection") { do { try configuration().save(); status = "Connection saved on this device. Open your wallet and refresh its balance." } catch { self.error = ErrorMessage(error) } }
                Button("Check connection") {
                    busy = true; status = ""
                    Task { do { status = try await configuration().checkConnection() } catch { self.error = ErrorMessage(error) }; busy = false }
                }
                Button("Remove connection", role: .destructive) { do { try RPCConfiguration.remove(network); endpoint = ""; username = ""; password = ""; status = "Removed" } catch { self.error = ErrorMessage(error) } }
            }
            ProximusSection { DisclosureGroup("Privacy & connection details") {
                Text("Connection checks request node information. Refreshing a wallet shares its public address with this node. Sending submits the reviewed signed transaction. Recovery phrases and private keys are never sent to the RPC. Endpoints and credentials stay on this device and are excluded from recovery kits.")
                Text("Nearby devices can exchange addresses and approval codes offline. Blockchain payments need a connected node to broadcast and the network to confirm them.").font(.caption).foregroundStyle(.secondary)
                Text("A successful connection check is the node’s response, not proof that the node is honest.").font(.caption).foregroundStyle(.secondary)
            } }
            if busy { ProgressView() }
            if !status.isEmpty { Text(status).textSelection(.enabled) }
        }.appForm().navigationTitle("Wallet networks").privacySensitive().disabled(busy).errorAlert($error)
            .onAppear { load() }.onChange(of: network) { _, _ in load() }.onDisappear { password = "" }
    }
    private func configuration() throws -> RPCConfiguration {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ProximusError.invalid("Enter an RPC endpoint.") }
        return try RPCConfiguration(network: network, endpoint: url, username: username, password: password, moneroWalletCompanion: network == .monero && companion)
    }
    private func load() { do { let saved = try RPCConfiguration.load(network); endpoint = saved?.endpoint.absoluteString ?? ""; username = saved?.username ?? ""; password = saved?.password ?? ""; companion = saved?.moneroWalletCompanion == true; status = "" } catch { self.error = ErrorMessage(error) } }
}
