import AuthenticationServices
import SwiftUI
import ProximusKit

private struct AssertionRequest {
    var relyingParty: String
    var clientDataHash: Data
    var allowed: [Data]
}

@MainActor final class CredentialProviderViewController: ASCredentialProviderViewController {
    private var session: VaultSession?
    #if os(iOS)
    private var host: UIHostingController<ProviderView>?
    #else
    private var host: NSHostingController<ProviderView>?
    #endif
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) { show(services: serviceIdentifiers) }
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
        show(services: serviceIdentifiers, assertion: AssertionRequest(relyingParty: requestParameters.relyingPartyIdentifier, clientDataHash: requestParameters.clientDataHash, allowed: requestParameters.allowedCredentials))
    }
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) { interactionRequired() }
    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) { interactionRequired() }
    private func interactionRequired() { extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue)) }
    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) { show(services: [credentialIdentity.serviceIdentifier], selected: credentialIdentity.recordIdentifier) }
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        if let request = credentialRequest as? ASPasskeyCredentialRequest, let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity {
            show(services: [], assertion: AssertionRequest(relyingParty: identity.relyingPartyIdentifier, clientDataHash: request.clientDataHash, allowed: [identity.credentialID]), selected: identity.recordIdentifier)
        } else if let identity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
            show(services: [identity.serviceIdentifier], selected: identity.recordIdentifier)
        } else { cancel() }
    }
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let request = registrationRequest as? ASPasskeyCredentialRequest else { cancel(); return }
        show(services: [], registration: request)
    }
    override func prepareInterfaceForExtensionConfiguration() { show(services: [], configuration: true) }
    private func cancel() { session?.lock(); extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue)) }
    private func show(services: [ASCredentialServiceIdentifier], assertion: AssertionRequest? = nil, registration: ASPasskeyCredentialRequest? = nil, selected: String? = nil, configuration: Bool = false) {
        Theme.registerFonts()
        do {
            let session = try VaultSession(repository: AppEnvironment.repository(), deviceID: AppEnvironment.deviceID()); self.session = session
            let content = ProviderView(session: session, services: services, assertion: assertion, registration: registration, selected: selected, configuration: configuration, context: extensionContext, cancel: { [weak self] in self?.cancel() })
            host?.view.removeFromSuperview(); host?.removeFromParent()
            #if os(iOS)
            let host = UIHostingController(rootView: content)
            #else
            let host = NSHostingController(rootView: content)
            preferredContentSize = NSSize(width: 520, height: 640)
            #endif
            self.host = host; addChild(host); host.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host.view)
            NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
            #if os(iOS)
            host.didMove(toParent: self)
            #endif
        } catch { extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])) }
    }
    #if os(iOS)
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); session?.lock() }
    #else
    override func viewDidDisappear() { super.viewDidDisappear(); session?.lock() }
    #endif
}

private struct ProviderView: View {
    @ObservedObject var session: VaultSession
    let services: [ASCredentialServiceIdentifier]
    let assertion: AssertionRequest?
    let registration: ASPasskeyCredentialRequest?
    let selected: String?
    let configuration: Bool
    let context: ASCredentialProviderExtensionContext
    let cancel: () -> Void
    @State private var passphrase = ""
    @State private var recovery = ""
    @State private var busy = false
    @State private var error = ""
    @State private var pendingPassword: VaultItem?
    @State private var notice = false
    private var destinations: [String] { services.compactMap { try? DomainPolicy.origin($0.identifier) } }
    private var items: [VaultItem] {
        (session.contents?.items ?? []).filter { item in
            if let selected, item.id.uuidString != selected { return false }
            if let assertion, let metadata = item.passkey {
                return metadata.relyingParty == assertion.relyingParty && metadata.deviceID == session.deviceID && (assertion.allowed.isEmpty || assertion.allowed.contains(metadata.credentialID)) && PasskeySigner.hasKey(metadata.credentialID)
            }
            // A passkey request never silently falls back to a password.
            return assertion == nil && item.kind == .password && destinations.contains { DomainPolicy.matches(saved: item.website, requested: $0) }
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Brand()
                    if !session.hasVault {
                        Text("Create or pair a vault in the Proximus app first.")
                    } else if !session.isUnlocked {
                        Text("Unlock to approve this request.")
                        if let state = session.state, HardwareUnlock.isEnabled(state.header.vaultID) { Button("Unlock with this device") { run { try await session.unlockWithDevice() } }.buttonStyle(ProximusButtonStyle(.primary)) }
                        SecureField("Master passphrase", text: $passphrase).textFieldStyle(ProximusTextFieldStyle())
                        SecureField("Recovery key, if needed", text: $recovery).textFieldStyle(ProximusTextFieldStyle())
                        Button("Unlock with passphrase") { run { try await session.unlock(passphrase: passphrase, recovery: recovery); passphrase = ""; recovery = "" } }
                    } else if configuration {
                        Text("Use Proximus for passwords and hardware-bound passkeys. Suggestions expose usernames and domains to the system credential index, never passwords.")
                        Button("Enable suggestions and finish") { run { try await session.setIndexEnabled(true); session.lock(); context.completeExtensionConfigurationRequest() } }.buttonStyle(ProximusButtonStyle(.primary))
                        Button("Finish without suggestions") { session.lock(); context.completeExtensionConfigurationRequest() }
                    } else if let request = registration, let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity {
                        Text("Create a passkey").font(.title.bold())
                        Text(identity.relyingPartyIdentifier).font(.headline).textSelection(.enabled)
                        Text(identity.userName)
                        Text("This private key will stay in this device’s Secure Enclave. Register another passkey or recovery method on the website before relying on this one.").foregroundStyle(.secondary)
                        Button("Create passkey on this device") { register(request, identity: identity) }.buttonStyle(ProximusButtonStyle(.primary))
                    } else {
                        Text(assertion == nil ? "Choose a password" : "Sign in with a passkey").font(.title.bold())
                        Text(assertion?.relyingParty ?? destinations.joined(separator: ", ")).font(.headline).textSelection(.enabled)
                        if items.isEmpty { Text("No matching credential is available on this device. Return to the website to choose another sign-in method.").foregroundStyle(.secondary) }
                        ForEach(items) { item in
                            Button {
                                if let assertion { sign(item, request: assertion) } else { pendingPassword = item; notice = true }
                            } label: { HStack { Image(systemName: item.kind.symbol); VStack(alignment: .leading) { Text(item.title).font(.headline); Text(CredentialPrivacy.maskedEmail(item.username)).font(.caption) }; Spacer(); Image(systemName: "chevron.right") }.padding() }.buttonStyle(ProximusButtonStyle())
                        }
                        if assertion != nil { Text("A passkey proves control of your key. It does not guarantee that the website or device is safe.").font(.caption).foregroundStyle(.secondary) }
                    }
                    if busy { ProgressView() }
                    if !error.isEmpty { Text(error).foregroundStyle(.red).font(.callout) }
                }.padding(24)
            }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        }.tint(Theme.accent).font(Theme.body()).buttonStyle(ProximusButtonStyle()).textFieldStyle(ProximusTextFieldStyle()).background(Theme.background).privacySensitive()
            .alert("Password sign-in", isPresented: $notice) {
                Button("Cancel", role: .cancel) { pendingPassword = nil }
                Button("Use password") {
                    guard session.isUnlocked, let item = pendingPassword, destinations.contains(where: { DomainPolicy.matches(saved: item.website, requested: $0) }) else { error = "Unlock again and choose a matching password."; return }
                    let credential = ASPasswordCredential(user: item.username, password: item.password)
                    pendingPassword = nil; session.lock(); context.completeRequest(withSelectedCredential: credential, completionHandler: nil)
                }
            } message: { Text(DomainPolicy.passwordNotice(destination: pendingPassword.flatMap { try? DomainPolicy.origin($0.website) })) }
    }
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true; error = ""
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
    private func register(_ request: ASPasskeyCredentialRequest, identity: ASPasskeyCredentialIdentity) {
        run {
            guard request.supportedAlgorithms.contains(where: { $0.rawValue == -7 }) else { throw ProximusError.invalid("This website does not accept ES256 hardware passkeys.") }
            if #available(iOS 18.0, macOS 15.0, *) {
                let excluded = request.excludedCredentials?.map(\.credentialID) ?? []
                if (session.contents?.items ?? []).contains(where: { item in item.passkey.map { $0.relyingParty == identity.relyingPartyIdentifier && $0.deviceID == session.deviceID && excluded.contains($0.credentialID) && PasskeySigner.hasKey($0.credentialID) } ?? false }) { throw ProximusError.invalid("This account already has an excluded passkey on this device.") }
            }
            let device = session.deviceID
            let (item, credential) = try await Task.detached(priority: .userInitiated) { try PasskeySigner.register(relyingParty: identity.relyingPartyIdentifier, username: identity.userName, userHandle: identity.userHandle, clientDataHash: request.clientDataHash, deviceID: device) }.value
            do { try await session.save(item) } catch { if let id = item.passkey?.credentialID { try? PasskeySigner.remove(id) }; throw error }
            session.lock(); context.completeRegistrationRequest(using: credential, completionHandler: nil)
        }
    }
    private func sign(_ item: VaultItem, request: AssertionRequest) {
        run {
            let device = session.deviceID
            let credential = try await Task.detached(priority: .userInitiated) { try PasskeySigner.assert(item: item, relyingParty: request.relyingParty, clientDataHash: request.clientDataHash, allowedCredentials: request.allowed, deviceID: device) }.value
            guard session.isUnlocked else { throw ProximusError.locked }
            session.lock(); context.completeAssertionRequest(using: credential, completionHandler: nil)
        }
    }
}
