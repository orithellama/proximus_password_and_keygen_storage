#if os(macOS)
import SwiftUI
import ProximusKit

struct BrowserApprovalBootstrap: View {
    let request: BrowserRequest
    @State private var session: VaultSession?
    @State private var error: String?
    var body: some View {
        Group {
            if let session { BrowserApprovalView(session: session, request: request) }
            else {
                VStack(spacing: 20) {
                    Brand()
                    Text(error ?? "Opening your local vault…").foregroundStyle(Theme.muted)
                    Button("Cancel") { BrowserNativeHost.cancel() }
                }.padding(32)
            }
        }.frame(minWidth: 480, idealWidth: 540, minHeight: 540, idealHeight: 680)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            .task {
                do { session = try VaultSession(repository: AppEnvironment.repository(), deviceID: AppEnvironment.deviceID()) }
                catch { self.error = "Proximus could not open its local vault. Open the Mac app to finish setup." }
            }
            .onDisappear { session?.lock(); BrowserNativeHost.cancel() }
    }
}

struct BrowserApprovalView: View {
    @ObservedObject var session: VaultSession
    let request: BrowserRequest
    @Environment(\.scenePhase) private var phase
    @State private var selected: UUID?
    @State private var password = ""
    @State private var recovery = ""
    @State private var useVaultPassword = false
    @State private var title = ""
    @State private var username = ""
    @State private var newPassword = ""
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    private var matches: [VaultItem] { (session.contents?.items ?? []).filter(request.matches).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
    private var selectedItem: VaultItem? { matches.first { $0.id == selected } }

    var body: some View {
        ProximusForm {
            HStack { Brand(compact: true); Spacer(); Text("Browser request").font(Theme.body(12)).foregroundStyle(Theme.muted) }
            AppCard {
                Text(request.action == .fill ? "Sign in to this website" : "Save this login").font(Theme.heading(21))
                Text(request.origin).font(Theme.body(18).weight(.semibold)).foregroundStyle(Theme.accent).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(request.action == .fill ? "Check this address before continuing. The website will receive the login you choose. Proximus cannot guarantee its safety." : "Review the details below. They will be encrypted in your local vault.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            if !session.hasVault {
                Text("Open Proximus and create or restore your vault first.").foregroundStyle(Theme.muted)
            } else if !session.isUnlocked {
                unlockSection
            } else {
                if request.action == .save { saveFields }
                accountSelection
                if request.action == .fill && matches.isEmpty {
                    Text("No saved login for this address. Return to Chrome, enter your login, and choose Save this login. Logins for other subdomains are kept separate.").foregroundStyle(Theme.muted)
                } else {
                    if request.action == .fill || selectedItem != nil { authenticationFields }
                    Button(request.action == .fill ? "Approve and fill login" : selectedItem == nil ? "Save new login" : "Approve and update login") { approve() }
                        .buttonStyle(ProximusButtonStyle(.primary))
                        .disabled(busy || (request.action == .fill && selectedItem == nil) || (request.action == .save && (title.isEmpty || newPassword.isEmpty)))
                }
            }
            if busy { ProgressView("Waiting for approval…") }
            if let error { Text(error).foregroundStyle(Theme.muted).font(Theme.body(13)) }
            Button("Cancel") { cancel() }
        }.privacySensitive()
            .onAppear {
                title = request.login?.title ?? ""; username = request.login?.username ?? ""; newPassword = request.login?.password ?? ""
                BrowserNativeHost.onCancel = { operation?.cancel(); session.lock() }
            }
            .onChange(of: session.isUnlocked) { _, unlocked in
                if unlocked && request.action == .fill { selected = matches.first?.id }
            }
            .onChange(of: phase) { _, value in if value == .background { cancel() } }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in cancel() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in cancel() }
            .onDisappear { operation?.cancel(); password = ""; recovery = ""; newPassword = ""; session.lock() }
    }

    private var unlockSection: some View {
        ProximusSection("Unlock your vault") {
            if let id = session.state?.header.vaultID, HardwareUnlock.isEnabled(id) {
                Button("Unlock with " + AppPresentation.unlockName) { unlock(device: true) }.disabled(busy)
            }
            SecureField("Vault password", text: $password)
            SecureField("Recovery key, if not saved on this Mac", text: $recovery)
            Button("Unlock with vault password") { unlock(device: false) }.disabled(busy || password.isEmpty)
        }
    }
    private var saveFields: some View {
        ProximusSection("Login details") {
            TextField("Name", text: $title)
            TextField("Email or username", text: $username)
            SecureField("Password", text: $newPassword)
        }.disabled(busy)
    }
    private var accountSelection: some View {
        ProximusSection(request.action == .fill ? "Choose a login" : "Save as") {
            if request.action == .save {
                Button { selected = nil } label: { Label("New login", systemImage: selected == nil ? "checkmark.circle.fill" : "circle") }.disabled(busy)
            }
            ForEach(matches) { item in
                Button { selected = item.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected == item.id ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text((request.action == .save ? "Update: " : "") + item.title)
                            Text(CredentialPrivacy.maskedEmail(item.username)).font(Theme.body(13)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(busy)
            }
        }
    }
    private var authenticationFields: some View {
        ProximusSection {
            Toggle("Confirm with vault password", isOn: $useVaultPassword).disabled(busy)
            if useVaultPassword {
                SecureField("Vault password", text: $password).disabled(busy)
                SecureField("Recovery key, if not saved on this Mac", text: $recovery).disabled(busy)
            } else {
                Text("Confirm with " + AppPresentation.unlockName + " or your Mac login password.").font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func unlock(device: Bool) {
        guard !busy else { return }; busy = true; error = nil
        operation = Task { @MainActor in
            defer { busy = false; operation = nil; password = ""; recovery = "" }
            do {
                try BrowserNativeHost.checkActive()
                if device { try await session.unlockWithDevice() }
                else { try await session.unlock(passphrase: password, recovery: recovery) }
                try BrowserNativeHost.checkActive()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func approve() {
        guard !busy else { return }; busy = true; error = nil
        let authorization: CredentialAuthorization = useVaultPassword ? .vaultPassword(password, recoveryKey: recovery) : .device
        let item = selectedItem
        let proposed = BrowserSaveLogin(title: title, username: username, password: newPassword)
        operation = Task { @MainActor in
            defer { busy = false; operation = nil; password = ""; recovery = "" }
            do {
                try BrowserNativeHost.checkActive()
                if request.action == .fill {
                    guard let item else { throw ProximusError.authentication }
                    let login = try await session.browserCredential(for: request, item: item, using: authorization)
                    try BrowserNativeHost.checkActive()
                    session.lock()
                    BrowserNativeHost.complete(status: "filled", login: login)
                } else {
                    if let item {
                        let grant = try await session.authorizeCredentialAccess(item, reason: "Update your login for " + request.origin, using: authorization)
                        guard try session.repository.state() == session.state else { try session.reload(); throw ProximusError.conflict }
                        _ = try session.consumeCredentialAccess(grant)
                    }
                    try BrowserNativeHost.checkActive()
                    try await session.save(request.savedItem(proposed, replacing: item))
                    session.lock(); newPassword = ""
                    BrowserNativeHost.complete(status: "saved")
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func cancel() { operation?.cancel(); session.lock(); BrowserNativeHost.cancel() }
}
#endif
