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
            Form {
                Section("Device security") {
                    Button("Enable device unlock") { run { try await session.enableDeviceUnlock(); message = "Device unlock is enabled. Keep your recovery kit for a lost or replaced device." } }
                    Text("Uses Secure Enclave with device owner authentication. A device passcode or password may be accepted when biometrics are unavailable.").font(.caption).foregroundStyle(.secondary)
                    if AppEnvironment.isStandaloneMac {
                        Text("Local Mac installation. Shared browser AutoFill is available in a build signed with an Apple team and the AutoFill capability.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(session.indexEnabled ? "Remove AutoFill suggestions" : "Enable AutoFill suggestions") { run { try await session.setIndexEnabled(!session.indexEnabled) } }
                        Text("Enable Proximus under your system’s AutoFill & Passwords settings. Suggestions share usernames and website names with Apple’s credential index. Passwords stay encrypted until you approve their use.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Vaults lock after five minutes without an app interaction, when the app enters the background, or when the Mac sleeps or switches users.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Encrypted sync") {
                    LabeledContent("Status", value: session.syncStatus)
                    if let relay = session.relay {
                        Text(relay.endpoint.absoluteString).font(.caption).textSelection(.enabled)
                        Button("Sync now") { run { try await session.synchronize() } }
                        Button("Disconnect this device") { run { try session.disconnectRelay() } }
                        Text("Disconnecting stops this device’s sync. It does not revoke a lost device’s vault key or relay access.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("Self-hosted HTTPS relay URL", text: $relayURL)
                        SecureField("Relay enrollment key", text: $enrollment)
                        Button("Connect relay") { run { guard let url = URL(string: relayURL) else { throw ProximusError.invalid("Enter a valid relay URL.") }; try await session.connectRelay(url: url, enrollment: enrollment); enrollment = "" } }.disabled(relayURL.isEmpty || enrollment.isEmpty)
                        Text("Local vault use needs no server. Deploy the included relay on your own infrastructure. Proximus-hosted sync is not configured in this development build.").font(.caption).foregroundStyle(.secondary)
                    }
                    if session.conflictingHead != nil {
                        Button("Review conflict: keep both versions") { mergeNotice = true }
                    }
                }
                Section("Recovery & backup") {
                    Button("Import passwords from CSV") { importingCSV = true }
                    Button("Export encrypted backup") { run { document = VaultDocument(data: try session.exportBackup()); filename = "Proximus-\(Date().formatted(.iso8601.year().month().day())).proximusvault"; exporting = true } }
                    Text("Backups require your master passphrase and recovery key. Store a copy away from this device. Device-bound passkeys cannot be recovered from a vault backup.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Paired devices") {
                    ForEach(session.contents?.devices ?? []) { device in
                        LabeledContent(device.name, value: device.id == session.deviceID ? "This device" : "Paired")
                    }
                    Text("A paired device has access to the password vault. If one is lost, rotate exposed account passwords and move to a fresh vault and relay namespace. Removing a name would not revoke its cryptographic access.").font(.caption).foregroundStyle(.secondary)
                }
                Section("About") {
                    Text("Proximus - 0.2.0")
                    Text("Free to use. All features included.").font(.caption)
                    Text("Open source under Apache-2.0. Copyright PROXIMUS Research Labs Foundation.").font(.caption)
                    Text("AES-256-GCM encrypted vaults. Argon2id recovery protection. Hardware-bound passkeys using Secure Enclave.").font(.caption).foregroundStyle(.secondary)
                }
                if busy { ProgressView() }
                if !message.isEmpty { Text(message).foregroundStyle(Theme.accent) }
            }.formStyle(.grouped).navigationTitle("Settings").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(idealWidth: 640, idealHeight: 740).errorAlert($error)
            .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: filename) { result in if case .failure(let error) = result { self.error = ErrorMessage(error) } }
            .fileImporter(isPresented: $importingCSV, allowedContentTypes: [.commaSeparatedText, .data]) { result in do { importItems = try PasswordCSV.parse(readImport(result.get())); confirmImport = true } catch { self.error = ErrorMessage(error) } }
            .confirmationDialog("Import \(importItems.count) passwords?", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("Import passwords") { run { try await session.importPasswords(importItems); message = "Imported \(importItems.count) passwords. Remove the plaintext CSV export when it is no longer needed."; importItems = [] } }
                Button("Cancel", role: .cancel) { importItems = [] }
            } message: { Text("Imported passwords are added as new items. Existing items are kept. The source CSV contains plaintext passwords.") }
            .confirmationDialog("Keep both versions?", isPresented: $mergeNotice, titleVisibility: .visible) { Button("Merge and sync") { run { try await session.mergeConflict() } } } message: { Text("Different versions of the same item will both be kept. Items deleted on only one branch can reappear. Review the result and delete unwanted copies.") }
    }
    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { do { try await work() } catch { self.error = ErrorMessage(error) }; busy = false }
    }
}
