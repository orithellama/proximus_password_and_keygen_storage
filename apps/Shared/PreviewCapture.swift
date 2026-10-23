#if DEBUG && os(macOS)
import SwiftUI
import AppKit
import ProximusKit

struct PreviewCaptureView: View {
    @State private var session: VaultSession?
    @State private var selection: UUID?
    @State private var error = ""
    private let device = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    var body: some View {
        Group {
            if let session {
                if ProcessInfo.processInfo.arguments.contains("--unlock-screen") { WelcomeView(session: session, pairingLink: .constant(nil)) }
                else { VaultView(session: session, initialSelection: selection) }
            } else { Text(error.isEmpty ? "Rendering app preview…" : error) }
        }.frame(minWidth: 1180, minHeight: 760)
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : .light)
            .task {
                do {
                    if ProcessInfo.processInfo.environment["PROXIMUS_VERIFY_LOCAL_KEYCHAIN"] == "1" {
                        let account = "installation-check/" + UUID().uuidString
                        let value = try VaultCrypto.random(32)
                        try DeviceKeychain.write(value, account: account)
                        defer { try? DeviceKeychain.delete(account) }
                        guard try DeviceKeychain.read(account) == value else { throw ProximusError.unavailable("Local Keychain verification failed.") }
                        _ = try VaultSession(repository: AppEnvironment.repository(), deviceID: AppEnvironment.deviceID())
                        print("Local Keychain round trip and vault initialization passed")
                    }
                    let items = [
                        VaultItem(title: "Proximus", username: "alex@example.com", website: "https://www.proximus.sh", password: "sample-password-for-preview", notes: "Workspace account", collection: "Work", favorite: true),
                        VaultItem(title: "Apple", username: "alex@example.com", website: "https://account.apple.com", password: "sample-password-for-preview", favorite: true),
                        VaultItem(kind: .passkey, title: "GitHub", username: "alex", website: "https://github.com", collection: "Work", passkey: PasskeyMetadata(credentialID: Data(repeating: 1, count: 32), userHandle: Data("sample".utf8), relyingParty: "github.com", deviceID: device)),
                        VaultItem(title: "Linear", username: "alex@example.com", website: "https://linear.app", password: "sample-password-for-preview", collection: "Work"),
                        VaultItem(kind: .note, title: "Recovery instructions", notes: "Keep the offline recovery kit in a separate secure location."),
                        VaultItem(title: "Figma", username: "alex@example.com", website: "https://figma.com", password: "sample-password-for-preview", collection: "Work")
                    ]
                    let model = try VaultSession.visualFixture(contents: VaultContents(items: items, devices: [PairedDevice(id: device, name: "MacBook Pro")]), deviceID: device)
                    selection = items[0].id
                    if ProcessInfo.processInfo.arguments.contains("--unlock-screen") { model.lock() }
                    session = model
                    try await Task.sleep(for: .seconds(2))
                    guard let path = ProcessInfo.processInfo.environment["PROXIMUS_PREVIEW_OUTPUT"] else { return }
                    guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil && $0.isVisible }), let view = window.contentView?.superview ?? window.contentView else { throw ProximusError.unavailable("Preview window is unavailable.") }
                    NSApplication.shared.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(300))
                    window.displayIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ProximusError.unavailable("Preview capture failed.") }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ProximusError.unavailable("Preview encoding failed.") }
                    try png.write(to: URL(fileURLWithPath: path))
                    if let session { try? FileManager.default.removeItem(at: session.repository.directory) }
                    NSApplication.shared.terminate(nil)
                } catch {
                    self.error = error.localizedDescription
                    FileHandle.standardError.write(Data(("Preview failed: " + error.localizedDescription + "\n").utf8))
                }
            }
    }
}
#endif
