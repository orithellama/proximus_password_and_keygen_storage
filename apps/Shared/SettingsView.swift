import SwiftUI
import ProximusKit

struct SettingsView: View {
    @ObservedObject var session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @State private var error: ErrorMessage?
    @State private var message = ""
    @State private var relayURL = ""
    @State private var enrollment = ""
    @State private var busy = false
    @State private var document: VaultDocument?
    @State private var filename = "Proximus.proximusvault"
    @State private var exporting = false
    @State private var importingCSV = false
    @State private var importItems: [VaultItem] = []
    @State private var confirmImport = false
    @State private var mergeNotice = false
    var body: some View {
        NavigationStack {
            ProximusForm {
                ProximusSection("Everyday use") {
                    NavigationLink { unlockSettings } label: { Label("Unlock & AutoFill", systemImage: "touchid") }
                    NavigationLink { RecoverySettingsView(session: session) } label: { Label("Backup & recovery", systemImage: "icloud") }
                    Button { importingCSV = true } label: { Label("Import passwords", systemImage: "square.and.arrow.down") }
                    Text("Bring passwords from another manager using a CSV export.").font(.caption).foregroundStyle(Theme.muted)
                }
                ProximusSection("Connections") {
                    NavigationLink { RPCSettingsView().onDisappear { session.clearWalletBalances() } } label: { Label("Wallet networks", systemImage: "network") }
                    NavigationLink { syncSettings } label: { Label("Sync over the internet", systemImage: "arrow.triangle.2.circlepath") }
                    Text("Your vault works offline. These connections are optional.").font(.caption).foregroundStyle(Theme.muted)
                }
                ProximusSection("Advanced backup") {
                    Button { run { document = VaultDocument(data: try session.exportBackup()); filename = "Proximus-\(Date().formatted(.iso8601.year().month().day())).proximusvault"; exporting = true } } label: { Label("Export a standard vault backup", systemImage: "externaldrive") }
                    Text("Includes passwords, notes, and public wallet addresses. Wallet keys need a recovery kit instead. To restore this export, keep your vault password and recovery key.").font(.caption).foregroundStyle(Theme.muted)
                }
                ProximusSection("About Proximus") {
                    LabeledContent("Version", value: AppPresentation.version)
                    Text("Free to use. All features included.")
                    Link(destination: ProximusLinks.source) { Label("Source code on GitHub", systemImage: "arrow.up.right.square") }
                    DisclosureGroup("Privacy & security") {
                        Text("Passwords are encrypted on this device. Vaults lock after five minutes without an app interaction, when the app enters the background, or when the Mac sleeps or switches users. Hardware passkeys stay on their original device.").font(.callout).foregroundStyle(Theme.muted)
                        Text("AES-256-GCM encryption, Argon2id recovery protection, and Secure Enclave device unlock.").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Text("Open source under Apache-2.0. PROXIMUS Research Labs Foundation.").font(.caption).foregroundStyle(Theme.muted)
                }
                if busy { ProgressView() }
                if !message.isEmpty { Text(message).foregroundStyle(Theme.accent) }
            }.appForm().navigationTitle("Settings").disabled(busy).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(idealWidth: 640, idealHeight: 740).errorAlert($error)
            .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: filename) { result in if case .failure(let error) = result { self.error = ErrorMessage(error) } }
            .fileImporter(isPresented: $importingCSV, allowedContentTypes: [.commaSeparatedText, .data]) { result in do { importItems = try PasswordCSV.parse(readImport(result.get())); confirmImport = true } catch { self.error = ErrorMessage(error) } }
            .confirmationDialog("Import \(importItems.count) passwords?", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("Import passwords") { run { try await session.importPasswords(importItems); message = "Imported \(importItems.count) passwords. Remove the plaintext CSV export when it is no longer needed."; importItems = [] } }
                Button("Cancel", role: .cancel) { importItems = [] }
            } message: { Text("Imported passwords are added as new items. Existing items are kept. The source CSV contains plaintext passwords.") }
            .confirmationDialog("Keep both versions?", isPresented: $mergeNotice, titleVisibility: .visible) { Button("Merge and sync") { run { try await session.mergeConflict() } } } message: { Text("Different versions of the same item will both be kept. Items deleted on only one branch can reappear. Review the result and delete unwanted copies.") }
    }
    private var unlockSettings: some View {
        ProximusForm {
            ProximusSection("A quicker way in") {
                Button("Set up \(AppPresentation.unlockName)") { run { try await session.enableDeviceUnlock(); message = "Device unlock is ready." } }
                Text("Use device authentication instead of typing your vault password each time. Your device can also accept its passcode or login password.").font(.callout).foregroundStyle(Theme.muted)
            }
            ProximusSection("Fill passwords in websites & apps") {
                if AppEnvironment.isStandaloneMac {
                    Text("In Chrome, pin the Proximus extension and choose Fill saved login on a sign-in page. Approve the website and login in the Proximus window.").font(.callout).foregroundStyle(Theme.muted)
                    Link("Set up the Chrome extension", destination: ProximusLinks.source.appendingPathComponent("tree/main/extension"))
                } else {
                    Text("1. Open your device’s Settings.\n2. Find AutoFill & Passwords.\n3. Enable Proximus as a password provider.").lineSpacing(6)
                    Button(session.indexEnabled ? "Turn off login suggestions" : "Turn on login suggestions") { run { try await session.setIndexEnabled(!session.indexEnabled) } }
                    Text("Suggestions share website names and usernames with your system. Passwords stay encrypted until you approve their use.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            if busy { ProgressView("Waiting for device authentication…") }
            if !message.isEmpty { Label(message, systemImage: "checkmark.circle").foregroundStyle(Theme.accent) }
        }.appForm().navigationTitle("Unlock & AutoFill").disabled(busy)
    }
    private var syncSettings: some View {
        ProximusForm {
            ProximusSection("Internet sync") {
                LabeledContent("Status", value: session.syncStatus)
                Text("Share encrypted changes through a server you control. For nearby devices, use My devices → Sync nearby instead.").font(.callout).foregroundStyle(Theme.muted)
                if let relay = session.relay {
                    Text(relay.endpoint.absoluteString).font(.caption).textSelection(.enabled)
                    Button("Sync now") { run { try await session.synchronize() } }
                    Button("Disconnect this device") { run { try session.disconnectRelay() } }
                    Text("Disconnecting stops this device’s sync. It does not revoke another device’s copy of your vault.").font(.caption).foregroundStyle(Theme.muted)
                } else {
                    TextField("Server address (https://…)", text: $relayURL).autocorrectionDisabled()
                    SecureField("Server enrollment key", text: $enrollment)
                    Button("Connect server") { run { guard let url = URL(string: relayURL) else { throw ProximusError.invalid("Enter a valid server address.") }; try await session.connectRelay(url: url, enrollment: enrollment); enrollment = "" } }.disabled(relayURL.isEmpty || enrollment.isEmpty)
                    DisclosureGroup("For self-hosted servers") { Text("Use the HTTPS address and enrollment key from your Proximus relay. Proximus-hosted sync is not configured.").font(.caption).foregroundStyle(Theme.muted) }
                }
                if session.conflictingHead != nil { Button("Review different versions") { mergeNotice = true } }
                if busy { ProgressView("Syncing…") }
            }
        }.appForm().navigationTitle("Internet sync").disabled(busy)
    }
    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { do { try await work() } catch { self.error = ErrorMessage(error) }; busy = false }
    }
}
