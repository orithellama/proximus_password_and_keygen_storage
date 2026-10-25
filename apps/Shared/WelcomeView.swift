import SwiftUI
import ProximusKit
import UniformTypeIdentifiers

struct WelcomeView: View {
    @ObservedObject var session: VaultSession
    @Binding var pairingLink: String?
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var generatedPhrase = ""
    @State private var recovery = ""
    @State private var rememberRecovery = true
    @State private var savedRecovery = false
    @State private var creating = false
    @State private var step = 0
    @State private var profileName = "Personal"
    @State private var deviceUnlock = HardwareUnlock.isAvailable
    @State private var deviceUnlockEnabled = false
    @State private var showPassword = false
    @State private var backupEnabled = false
    @State private var backupPassword = ""
    @State private var backupConfirmation = ""
    @State private var backupPasswordSaved = false
    @State private var backupFolder: Data?
    @State private var folderName = ""
    @State private var chooseFolder = false
    @State private var importingKit = false
    @State private var recoveryKitData: Data?
    @State private var kitPassword = ""
    @State private var busy = false
    @State private var activity = ""
    @State private var error: ErrorMessage?
    @State private var showPair = false
    @State private var showImport = false
    @State private var restoreData: Data?
    private var setup: Bool { creating || restoreData != nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Brand().padding(.bottom, 8)
                if session.hasVault { unlockContent }
                else if restoreData != nil { restoreContent }
                else if creating { creationContent }
                else { introduction }
                if busy {
                    AppCard {
                        ProgressView(activity)
                        #if os(macOS)
                        Text("If macOS opens a Keychain dialog, enter your Mac login password there. Your vault password is different.")
                            .font(Theme.body(13)).foregroundStyle(Theme.muted)
                        #else
                        Text("Complete the device authentication prompt to continue.").font(.callout).foregroundStyle(Theme.muted)
                        #endif
                    }.accessibilityElement(children: .combine)
                }
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                    Text("Private by default. Free. No online account needed.").font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                Text("Proximus \(AppPresentation.version)").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: 500).padding(24).padding(.vertical, 24).frame(maxWidth: .infinity)
        }.background(Theme.background).privacySensitive().errorAlert($error)
            .task(id: session.state?.header.vaultID) {
                guard let vault = session.state?.header.vaultID else { return }
                let enabled = await Task.detached { HardwareUnlock.isEnabled(vault) }.value
                if !Task.isCancelled { deviceUnlockEnabled = enabled; showPassword = !enabled }
            }
            .sheet(isPresented: $showPair) { PairingView(session: session, isHost: false, initialLink: pairingLink ?? "") }
            .onChange(of: passphrase) { _, value in if value != generatedPhrase { generatedPhrase = "" } }
            .onChange(of: pairingLink) { _, value in if value != nil { showPair = true } }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.data]) { result in
                do {
                    let data = try readImport(result.get()); resetSetup()
                    if importingKit { recoveryKitData = data; creating = true; recovery = try VaultCrypto.recoveryKey() }
                    else { restoreData = data }
                } catch { self.error = ErrorMessage(error) }
            }
            .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
                do { let folder = try result.get(); backupFolder = try RecoveryFolder.bookmark(folder); folderName = folder.lastPathComponent } catch { self.error = ErrorMessage(error) }
            }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeading(title: "A little peace of mind.", subtitle: "Keep your passwords, private notes, and wallets together. Protected on your device.")
            AppCard {
                Label("Save a password once. Find it whenever you need it.", systemImage: "key.horizontal")
                Label("Keep a private copy on your other devices.", systemImage: "laptopcomputer.and.iphone")
                Label("Use your vault even without internet.", systemImage: "wifi.slash")
            }
            Button {
                do { resetSetup(); recovery = try VaultCrypto.recoveryKey(); creating = true }
                catch { self.error = ErrorMessage(error) }
            } label: { Label("Get started", systemImage: "arrow.right").frame(maxWidth: .infinity) }.buttonStyle(ProximusButtonStyle(.primary))
            ActionRow(title: "Already using Proximus?", subtitle: "Connect to a vault on your other device.", symbol: "qrcode") { showPair = true }
            DisclosureGroup("Restore from a backup") {
                VStack(alignment: .leading, spacing: 14) {
                    Button("Restore an iCloud recovery kit") { importingKit = true; showImport = true }
                    Text("Includes passwords and backed-up wallet keys. Requires your backup password.").font(.caption).foregroundStyle(Theme.muted)
                    Button("Restore a standard vault backup") { importingKit = false; showImport = true }
                    Text("Requires your vault password and recovery key.").font(.caption).foregroundStyle(Theme.muted)
                }.padding(.top, 12)
            }
        }.disabled(busy)
    }
    private var unlockContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "lock.shield").font(.system(size: 34)).foregroundStyle(Theme.accent)
            SectionHeading(title: "Welcome back.", subtitle: "Unlock your vault to see your passwords and wallets.")
            if deviceUnlockEnabled {
                Button { perform("Waiting for device authentication…") { try await session.unlockWithDevice() } } label: {
                    Label("Unlock with \(AppPresentation.unlockName)", systemImage: AppPresentation.unlockSymbol).frame(maxWidth: .infinity)
                }.buttonStyle(ProximusButtonStyle(.primary))
                Text("Your device may ask for its passcode or login password.").font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            if deviceUnlockEnabled { Button(showPassword ? "Hide password options" : "Use my vault password instead") { showPassword.toggle() }.buttonStyle(.plain).foregroundStyle(Theme.accent) }
            if showPassword || !deviceUnlockEnabled {
                AppCard {
                    LabeledField(title: "Vault password") { SecureField("Enter your vault password", text: $passphrase).onSubmit { unlock() } }
                    DisclosureGroup("Enter a recovery key") {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("Recovery key", text: $recovery).textFieldStyle(ProximusTextFieldStyle())
                            Text("Only needed if the key is not saved on this device.").font(.caption).foregroundStyle(Theme.muted)
                        }.padding(.top, 10)
                    }
                    Button("Unlock vault") { unlock() }.buttonStyle(ProximusButtonStyle(.primary)).disabled(passphrase.isEmpty)
                }
            }
            #if os(macOS)
            DisclosureGroup("Why is my Mac asking for a password?") {
                Text("The macOS Keychain keeps your device’s unlock information safe. If its dialog appears, use the login password for your Mac. After installing a new local build, macOS may ask you to allow Proximus again.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted).padding(.top, 8)
            }
            #endif
        }.disabled(busy)
    }
    private var creationContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepIndicator(labels: ["Your vault", "Recovery", "Finish"], current: step)
            if step == 0 {
                SectionHeading(title: recoveryKitData == nil ? "Make yourself at home." : "Restore into a new vault.", subtitle: "Choose a password you use only for Proximus. You’ll be able to use device unlock day to day.")
                AppCard {
                    LabeledField(title: "Vault name") { TextField("For example, Personal", text: $profileName) }
                    LabeledField(title: "Vault password") { SecureField("At least 12 characters", text: $passphrase) }
                    LabeledField(title: "Confirm password") { SecureField("Enter it again", text: $confirmation) }
                    if !confirmation.isEmpty && passphrase != confirmation { Text("The passwords don’t match yet.").font(.caption).foregroundStyle(Theme.muted) }
                    Text("Use a long, unique password. Several randomly chosen words are easier to remember than a short mix of characters.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    DisclosureGroup("Generate a recovery-style password (BIP-39)") {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Generate 24 random words") { do { let words = try WalletCrypto.mnemonic(); generatedPhrase = words; passphrase = words; confirmation = words } catch { self.error = ErrorMessage(error) } }
                            if !generatedPhrase.isEmpty {
                                Text(generatedPhrase).font(.system(.callout, design: .monospaced))
                                Button("Copy for 30 seconds") { Platform.copySecret(generatedPhrase) }
                            }
                            Text("Save these words privately. Use them only as your vault password, never as a crypto wallet recovery phrase.").font(.caption).foregroundStyle(Theme.muted)
                        }.padding(.top, 12)
                    }
                }
            } else if step == 1 {
                SectionHeading(title: "Keep a way back in.", subtitle: "Save this recovery key somewhere safe, separate from your vault password.")
                AppCard {
                    Label("Your recovery key", systemImage: "key.viewfinder").font(.headline)
                    Text(recovery).font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Copy recovery key for 30 seconds") { Platform.copySecret(recovery) }
                    Text("You need this key and your vault password to restore a standard backup. Proximus cannot reset either one.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    Divider()
                    Toggle("I saved my recovery key somewhere safe", isOn: $savedRecovery)
                }
            } else {
                SectionHeading(title: "Make every day easier.", subtitle: "Choose how to unlock. You can change these options in Settings.")
                AppCard {
                    Toggle("Use \(AppPresentation.unlockName)", isOn: $deviceUnlock).disabled(!HardwareUnlock.isAvailable)
                    if !HardwareUnlock.isAvailable { Text("Device unlock isn’t available here. You can use your vault password.").font(.caption).foregroundStyle(Theme.muted) }
                    Text("Your device may also accept its passcode or login password.").font(.caption).foregroundStyle(Theme.muted)
                    if recoveryKitData != nil {
                        LabeledField(title: "Password for your recovery kit") { SecureField("Enter your backup password", text: $kitPassword) }
                        Text("Passwords and backed-up wallet keys will be restored. Passkeys stay on the device where they were created.").font(.caption).foregroundStyle(Theme.muted)
                    } else {
                        Divider()
                        Toggle("Set up iCloud backup now", isOn: $backupEnabled).disabled(!HardwareUnlock.isAvailable)
                        Text("Optional. You can set this up later in Settings → Backup & recovery.").font(.caption).foregroundStyle(Theme.muted)
                        if backupEnabled { backupFields }
                    }
                    DisclosureGroup("Advanced") { Toggle("Remember recovery key on this device", isOn: $rememberRecovery).padding(.top, 10) }
                }
            }
            HStack {
                Button("Back") { if step > 0 { step -= 1 } else { resetSetup() } }.buttonStyle(ProximusButtonStyle()).controlSize(.large)
                Spacer()
                Button(step == 2 ? (recoveryKitData == nil ? "Create my vault" : "Restore my vault") : "Continue") {
                    if step < 2 { step += 1 } else { submit() }
                }.buttonStyle(ProximusButtonStyle(.primary)).disabled(!canContinue)
            }
        }.disabled(busy)
    }
    private var backupFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField(title: "Separate backup password") { SecureField("At least 16 characters", text: $backupPassword) }
            LabeledField(title: "Confirm backup password") { SecureField("Enter it again", text: $backupConfirmation) }
            Button(folderName.isEmpty ? "Choose a folder in iCloud Drive" : "Folder: " + folderName) { chooseFolder = true }
            Text("Only encrypted files are saved, including wallet keys on this device. Keep the backup password separately; you’ll need it to restore.").font(.caption).foregroundStyle(Theme.muted)
            Toggle("I saved the backup password separately", isOn: $backupPasswordSaved)
        }
    }
    private var restoreContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionHeading(title: "Restore your vault.", subtitle: "Enter the password and recovery key that belong to this backup.")
            AppCard {
                LabeledField(title: "Vault password") { SecureField("Original vault password", text: $passphrase) }
                LabeledField(title: "Recovery key") { SecureField("Recovery key from your backup", text: $recovery) }
            }
            HStack {
                Button("Back") { resetSetup() }.buttonStyle(ProximusButtonStyle())
                Spacer()
                Button("Restore vault") { submit() }.buttonStyle(ProximusButtonStyle(.primary)).disabled(passphrase.isEmpty || recovery.isEmpty)
            }
        }.disabled(busy)
    }
    private var canContinue: Bool {
        switch step {
        case 0: return passphrase.utf8.count >= 12 && passphrase == confirmation && !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1: return savedRecovery
        default:
            if recoveryKitData != nil { return !kitPassword.isEmpty }
            return !backupEnabled || (backupPassword.utf8.count >= 16 && backupPassword == backupConfirmation && backupPassword != passphrase && backupFolder != nil && backupPasswordSaved)
        }
    }
    private func resetSetup() {
        creating = false; step = 0; restoreData = nil; recoveryKitData = nil; kitPassword = ""; backupPassword = ""; backupConfirmation = ""
        passphrase = ""; confirmation = ""; generatedPhrase = ""; recovery = ""; savedRecovery = false; backupEnabled = false; backupPasswordSaved = false
    }
    private func perform(_ message: String, _ work: @escaping () async throws -> Void) {
        guard !busy else { return }; activity = message; busy = true
        Task { do { try await work(); passphrase = ""; recovery = ""; confirmation = ""; generatedPhrase = ""; backupPassword = ""; backupConfirmation = ""; kitPassword = "" } catch { self.error = ErrorMessage(error) }; busy = false }
    }
    private func unlock() { guard !passphrase.isEmpty else { return }; perform("Unlocking your vault…") { try await session.unlock(passphrase: passphrase, recovery: recovery) } }
    private func submit() {
        perform(restoreData == nil && recoveryKitData == nil ? "Creating your vault…" : "Restoring your vault…") {
            if let recoveryKitData { try await session.restoreRecoveryKit(recoveryKitData, backupPassword: kitPassword, passphrase: passphrase, recovery: recovery, deviceName: Platform.deviceName, deviceUnlock: deviceUnlock, rememberRecovery: rememberRecovery) }
            else if let restoreData { try await session.restore(restoreData, passphrase: passphrase, recovery: recovery) }
            else { try await session.create(passphrase: passphrase, recovery: recovery, name: profileName, deviceName: Platform.deviceName, rememberRecovery: rememberRecovery, deviceUnlock: deviceUnlock, recoverySetup: backupEnabled ? backupFolder.map { RecoverySetup(password: backupPassword, folder: $0) } : nil) }
        }
    }
}
