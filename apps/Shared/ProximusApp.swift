import SwiftUI
import ProximusKit

@main struct ProximusPasswordsApp: App {
    init() { Theme.registerFonts() }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--capture-preview") { PreviewCaptureView().tint(Theme.accent).font(Theme.body()).buttonStyle(ProximusButtonStyle()).toggleStyle(ProximusToggleStyle()).textFieldStyle(ProximusTextFieldStyle()) }
            else { BootstrapView().tint(Theme.accent).font(Theme.body()).buttonStyle(ProximusButtonStyle()).toggleStyle(ProximusToggleStyle()).textFieldStyle(ProximusTextFieldStyle()) }
            #else
            BootstrapView().tint(Theme.accent).font(Theme.body()).buttonStyle(ProximusButtonStyle()).toggleStyle(ProximusToggleStyle()).textFieldStyle(ProximusTextFieldStyle())
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .commands { CommandGroup(replacing: .newItem) {} }
        #endif
    }
}

struct BootstrapView: View {
    @State private var session: VaultSession?
    @State private var error: String?
    var body: some View {
        Group {
            if let session { RootView(session: session) }
            else if let error {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "lock.trianglebadge.exclamationmark").font(.system(size: 44)).foregroundStyle(Theme.accent)
                    SectionHeading(title: "Let’s get your vault open.", subtitle: "Proximus couldn’t access its storage on this device. Unlock your device, then try again.")
                    Button("Try again") { load() }.buttonStyle(ProximusButtonStyle(.primary))
                    DisclosureGroup("Technical details") { Text(error).font(.callout).foregroundStyle(Theme.muted).textSelection(.enabled) }
                }.padding(32).frame(maxWidth: 560)
            } else { ProgressView("Opening Proximus…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
        .task { load() }
    }
    private func load() {
        error = nil
        do { session = try VaultSession(repository: AppEnvironment.repository(), deviceID: AppEnvironment.deviceID()) }
        catch { self.error = error.localizedDescription }
    }
}

struct RootView: View {
    @ObservedObject var session: VaultSession
    @Environment(\.scenePhase) private var phase
    @State private var pairingLink: String?
    var body: some View {
        Group {
            if session.isUnlocked { VaultView(session: session) }
            else { WelcomeView(session: session, pairingLink: $pairingLink) }
        }
        .onChange(of: phase) { _, phase in
            if phase == .background { session.lock() }
        }
        .overlay {
            if phase != .active {
                Theme.ink.ignoresSafeArea().overlay { Label("Vault hidden", systemImage: "lock.shield").foregroundStyle(.white).font(.title2) }
            }
        }
        .onOpenURL { url in if url.scheme == "proximus", !session.hasVault { pairingLink = url.absoluteString } }
        #if os(macOS)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in session.lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in session.lock() }
        #endif
    }
}

struct ErrorMessage: Identifiable { let id = UUID(); let text: String; init(_ error: Error) { text = error.localizedDescription } }

extension View {
    func errorAlert(_ error: Binding<ErrorMessage?>) -> some View {
        alert("Could not complete this action", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) { Button("OK", role: .cancel) { error.wrappedValue = nil } } message: { Text(error.wrappedValue?.text ?? "") }
    }
}
