#if DEBUG
import SwiftUI
#if os(macOS)
import AppKit
#endif
import ProximusKit

struct PreviewCaptureView: View {
    @State private var session: VaultSession?
    @State private var selection: UUID?
    @State private var error = ""
    private let device = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private var detailScreen: Bool {
        ["--wallet-screen", "--recovery-screen", "--generator-screen", "--devices-screen", "--settings-screen", "--welcome-screen", "--unlock-screen"].contains { ProcessInfo.processInfo.arguments.contains($0) }
    }
    var body: some View {
        Group {
            if let session {
                if ProcessInfo.processInfo.arguments.contains("--unlock-screen") || ProcessInfo.processInfo.arguments.contains("--welcome-screen") { WelcomeView(session: session, pairingLink: .constant(nil)) }
                else if ProcessInfo.processInfo.arguments.contains("--wallet-screen") { WalletCreator(session: session, created: { _ in }) }
                else if ProcessInfo.processInfo.arguments.contains("--recovery-screen") { NavigationStack { RecoverySettingsView(session: session) } }
                else if ProcessInfo.processInfo.arguments.contains("--generator-screen") { GeneratorView() }
                else if ProcessInfo.processInfo.arguments.contains("--devices-screen") { DevicesView(session: session) }
                else if ProcessInfo.processInfo.arguments.contains("--settings-screen") { SettingsView(session: session) }
                else { VaultView(session: session, initialSelection: selection, initialCategory: ProcessInfo.processInfo.arguments.contains("--wallet-detail-screen") ? "wallet" : "all") }
            } else { Text(error.isEmpty ? "Rendering app preview…" : error) }
        }
            #if os(macOS)
            .frame(minWidth: detailScreen ? 760 : 1180, minHeight: 760)
            #endif
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
                    var items = [
                        VaultItem(title: "Proximus", username: "alex@example.com", website: "https://www.proximus.sh", password: "sample-password-for-preview", notes: "Workspace account", collection: "Work", favorite: true),
                        VaultItem(title: "Apple", username: "alex@example.com", website: "https://account.apple.com", password: "sample-password-for-preview", favorite: true),
                        VaultItem(kind: .passkey, title: "GitHub", username: "alex", website: "https://github.com", collection: "Work", passkey: PasskeyMetadata(credentialID: Data(repeating: 1, count: 32), userHandle: Data("sample".utf8), relyingParty: "github.com", deviceID: device)),
                        VaultItem(title: "Linear", username: "alex@example.com", website: "https://linear.app", password: "sample-password-for-preview", collection: "Work"),
                        VaultItem(kind: .note, title: "Recovery instructions", notes: "Keep the offline recovery kit in a separate secure location."),
                        VaultItem(title: "Figma", username: "alex@example.com", website: "https://figma.com", password: "sample-password-for-preview", collection: "Work")
                    ]
                    if ProcessInfo.processInfo.arguments.contains("--wallet-detail-screen") {
                        items = try WalletNetwork.allCases.map { network in
                            let material = try WalletCrypto.derive(network: network, recovery: network == .monero ? "01" + String(repeating: "00", count: 31) : "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
                            return VaultItem(kind: .wallet, title: network == .solana ? "Personal" : network.label, wallet: material.metadata(network: network, deviceID: device))
                        }
                    }
                    let model = try VaultSession.visualFixture(contents: VaultContents(items: items, devices: [PairedDevice(id: device, name: "MacBook Pro")]), deviceID: device, sampleWalletBalances: true)
                    selection = ProcessInfo.processInfo.arguments.contains("--home-screen") ? nil : items[0].id
                    if ProcessInfo.processInfo.arguments.contains("--unlock-screen") { model.lock() }
                    if ProcessInfo.processInfo.arguments.contains("--welcome-screen") {
                        let empty = try VaultRepository(directory: model.repository.directory.appendingPathComponent("welcome"))
                        session = try VaultSession(repository: empty, deviceID: device)
                    } else { session = model }
                    try await Task.sleep(for: .seconds(2))
                    #if os(macOS)
                    guard let path = ProcessInfo.processInfo.environment["PROXIMUS_PREVIEW_OUTPUT"] else { return }
                    guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil && $0.isVisible }), let view = window.contentView?.superview ?? window.contentView else { throw ProximusError.unavailable("Preview window is unavailable.") }
                    window.setContentSize(NSSize(width: detailScreen ? 820 : 1180, height: 800))
                    NSApplication.shared.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(300))
                    window.displayIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ProximusError.unavailable("Preview capture failed.") }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ProximusError.unavailable("Preview encoding failed.") }
                    try png.write(to: URL(fileURLWithPath: path))
                    try? FileManager.default.removeItem(at: model.repository.directory)
                    NSApplication.shared.terminate(nil)
                    #endif
                } catch {
                    self.error = error.localizedDescription
                    FileHandle.standardError.write(Data(("Preview failed: " + error.localizedDescription + "\n").utf8))
                    #if os(macOS)
                    if ProcessInfo.processInfo.environment["PROXIMUS_PREVIEW_OUTPUT"] != nil { NSApplication.shared.terminate(nil) }
                    #endif
                }
            }
    }
}
#endif
