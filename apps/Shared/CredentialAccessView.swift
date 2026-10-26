import SwiftUI
import ProximusKit

enum CredentialAction {
    case showPassword, copyPassword, showUsername, copyUsername, edit
    var title: String {
        switch self {
        case .showPassword: return "Show password"
        case .copyPassword: return "Copy password"
        case .showUsername: return "Show username or email"
        case .copyUsername: return "Copy username or email"
        case .edit: return "Edit saved item"
        }
    }
}

struct CredentialAccessRequest: Identifiable {
    let id = UUID()
    let item: VaultItem
    let action: CredentialAction
}

struct CredentialAccessView: View {
    @ObservedObject var session: VaultSession
    let request: CredentialAccessRequest
    var onAuthorized: (CredentialAccessGrant) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var password = ""
    @State private var recovery = ""
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ProximusForm {
                ProximusSection {
                    Label(request.item.title, systemImage: "lock.shield").font(Theme.heading(20))
                    Text("Confirm it’s you to continue.").foregroundStyle(Theme.muted)
                    Button { authenticate(.device) } label: { Label("Use " + AppPresentation.unlockName, systemImage: AppPresentation.unlockSymbol) }.disabled(busy)
                    if busy { ProgressView("Waiting for authentication…") }
                    if let error { Text(error).font(.callout).foregroundStyle(Theme.muted).accessibilityLabel(error) }
                }
                ProximusSection {
                    DisclosureGroup("Use vault password instead") {
                        VStack(alignment: .leading, spacing: 14) {
                            SecureField("Vault password", text: $password)
                            SecureField("Recovery key, if not saved on this device", text: $recovery)
                            Button("Continue") { authenticate(.vaultPassword(password, recoveryKey: recovery)) }.disabled(busy || password.isEmpty)
                        }.padding(.top, 12)
                    }
                }
            }.appForm().navigationTitle(request.action.title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { operation?.cancel(); dismiss() } } }
        }.frame(idealWidth: 480, idealHeight: 440).privacySensitive()
            .task { authenticate(.device) }
            .onDisappear { operation?.cancel(); operation = nil; password = ""; recovery = "" }
            .onChange(of: phase) { _, value in if value == .background { operation?.cancel(); dismiss() } }
    }

    private func authenticate(_ authorization: CredentialAuthorization) {
        guard !busy else { return }
        busy = true; error = nil
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            do {
                let item = try await session.authorizeCredentialAccess(request.item, reason: request.action.title + " in Proximus", using: authorization)
                guard !Task.isCancelled, phase != .background else { return }
                password = ""; recovery = ""
                onAuthorized(item)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
