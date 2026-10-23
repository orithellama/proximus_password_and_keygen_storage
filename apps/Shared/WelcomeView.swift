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
    @State private var profileName = "Personal"
    @State private var deviceUnlock = HardwareUnlock.isAvailable
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
    @State private var error: ErrorMessage?
    @State private var showPair = false
    @State private var showImport = false
    @State private var restoreData: Data?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Brand().padding(.bottom, 16)
                Text(session.hasVault ? "Unlock your vault" : "Create your vault")
                    .font(Theme.heading(30)).tracking(-0.7)
                Text(session.hasVault ? "Unlock to access your passwords, passkeys, wallet addresses, and private notes." : "A private home for passwords, passkeys, and wallet keys. Works offline, with optional encrypted sync.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if session.hasVault {
                    VStack(alignment: .leading, spacing: 14) {
                        if let state = session.state, HardwareUnlock.isEnabled(state.header.vaultID) {
                            Button { perform { try await session.unlockWithDevice() } } label: { Label("Unlock with this device", systemImage: "faceid").frame(maxWidth: .infinity).padding(8) }.buttonStyle(ProximusPrimaryButton())
                        }
                        SecureField("Master passphrase", text: $passphrase).textFieldStyle(.roundedBorder).onSubmit { unlock() }
                        SecureField("Recovery key, if not saved on this device", text: $recovery).textFieldStyle(.roundedBorder)
                        Button("Unlock with passphrase") { unlock() }.buttonStyle(.bordered).disabled(passphrase.isEmpty)
                    }
                } else if creating || restoreData != nil {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(restoreData == nil ? "Create your vault" : "Restore encrypted backup").font(.title2.bold())
                        SecureField("Master passphrase - 12 characters minimum", text: $passphrase).textFieldStyle(.roundedBorder)
                        if restoreData == nil {
                            TextField("Profile name", text: $profileName).textFieldStyle(.roundedBorder)
                            SecureField("Repeat master passphrase", text: $confirmation).textFieldStyle(.roundedBorder)
                            Button("Generate from BIP-39") {
                                do { let words = try WalletCrypto.mnemonic(); generatedPhrase = words; passphrase = words; confirmation = words }
                                catch { self.error = ErrorMessage(error) }
                            }.buttonStyle(.bordered)
                            if !generatedPhrase.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Your generated master passphrase").font(.headline)
                                    Text(generatedPhrase).font(.system(.callout, design: .monospaced))
                                    Button("Copy passphrase for 30 seconds") { Platform.copySecret(generatedPhrase) }
                                    Text("24 random BIP-39 words. Save them privately. Use this phrase only to unlock this vault, never as a wallet recovery phrase.").font(.caption).foregroundStyle(.secondary)
                                }.padding().background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                            }
                            Text("Use six or seven randomly chosen words for a passphrase you type. Never use a quote, name, or reused password.").font(.caption).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Save your recovery key", systemImage: "key.viewfinder").font(.headline)
                                Text(recovery).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                Button("Copy recovery key for 30 seconds") { Platform.copySecret(recovery) }
                                Text("Keep this key and your passphrase separately. You need both to restore a standard vault backup. Proximus cannot reset them. Hardware-bound passkeys need separate account recovery.").font(.caption).foregroundStyle(.secondary)
                            }.padding().background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                            Toggle("I saved my recovery key somewhere safe", isOn: $savedRecovery)
                            Toggle("Use Face ID or Touch ID to unlock", isOn: $deviceUnlock).disabled(!HardwareUnlock.isAvailable)
                            if recoveryKitData != nil {
                                SecureField("Recovery kit password", text: $kitPassword).textFieldStyle(.roundedBorder)
                                Text("Restores passwords and backed-up wallet phrases into a new local vault. Choose a new master passphrase above. Hardware passkeys remain on their original device.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Toggle("Automatically save an encrypted recovery kit", isOn: $backupEnabled).disabled(!HardwareUnlock.isAvailable)
                                if backupEnabled {
                                    SecureField("Separate backup password - 16 characters minimum", text: $backupPassword).textFieldStyle(.roundedBorder)
                                    SecureField("Repeat backup password", text: $backupConfirmation).textFieldStyle(.roundedBorder)
                                    Button(folderName.isEmpty ? "Choose a folder in iCloud Drive" : "Backup folder: " + folderName) { chooseFolder = true }
                                    Text("Includes passwords and wallet recovery phrases. Only encrypted files are saved. Choose iCloud Drive to upload when connected. Keep the backup password separately, it cannot be reset.").font(.caption).foregroundStyle(.secondary)
                                    Toggle("I saved the backup password separately", isOn: $backupPasswordSaved)
                                }
                            }
                            Toggle("Remember the recovery key in this device’s Keychain", isOn: $rememberRecovery).font(.callout)
                        } else { SecureField("Recovery key", text: $recovery).textFieldStyle(.roundedBorder) }
                        HStack {
                            Button("Back") { creating = false; restoreData = nil; recoveryKitData = nil; kitPassword = ""; backupPassword = ""; backupConfirmation = ""; passphrase = ""; confirmation = ""; generatedPhrase = ""; recovery = "" }
                            Spacer()
                            Button(restoreData == nil ? "Create vault" : "Restore vault") { submit() }.buttonStyle(ProximusPrimaryButton())
                                .disabled(passphrase.utf8.count < 12 || (restoreData == nil && (!savedRecovery || passphrase != confirmation)) || (recoveryKitData != nil && kitPassword.isEmpty) || (backupEnabled && recoveryKitData == nil && (backupPassword.utf8.count < 16 || backupPassword != backupConfirmation || backupPassword == passphrase || backupFolder == nil || !backupPasswordSaved)))
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Button { do { recovery = try VaultCrypto.recoveryKey(); creating = true } catch { self.error = ErrorMessage(error) } } label: { Label("Create a vault", systemImage: "plus").frame(maxWidth: .infinity).padding(8) }.buttonStyle(ProximusPrimaryButton())
                        Button { showPair = true } label: { Label("Pair with another device", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(5) }.buttonStyle(.bordered)
                        Button("Restore an encrypted vault backup") { importingKit = false; showImport = true }
                        Button("Restore an iCloud recovery kit") { importingKit = true; showImport = true }
                    }
                }
                if busy { ProgressView("Working securely…") }
                Divider()
                Label("Free to use. No account required.", systemImage: "checkmark.shield").font(.callout).foregroundStyle(.secondary)
                Text("Version 0.3.0 - PROXIMUS Research Labs Foundation").font(Theme.body(11)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: 480).padding(32).padding(.vertical, 20).frame(maxWidth: .infinity)
        }
        .background(Theme.background).disabled(busy).privacySensitive().errorAlert($error)
        .sheet(isPresented: $showPair) { PairingView(session: session, isHost: false, initialLink: pairingLink ?? "") }
        .onChange(of: passphrase) { _, value in if value != generatedPhrase { generatedPhrase = "" } }
        .onChange(of: pairingLink) { _, value in if value != nil { showPair = true } }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.data]) { result in
            do {
                let data = try readImport(result.get())
                if importingKit { recoveryKitData = data; restoreData = nil; creating = true; recovery = try VaultCrypto.recoveryKey(); savedRecovery = false }
                else { restoreData = data; recovery = "" }
                passphrase = ""; confirmation = ""
            } catch { self.error = ErrorMessage(error) }
        }
        .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
            do { let folder = try result.get(); backupFolder = try RecoveryFolder.bookmark(folder); folderName = folder.lastPathComponent } catch { self.error = ErrorMessage(error) }
        }
    }
    private func perform(_ work: @escaping () async throws -> Void) {
        busy = true
        Task { do { try await work(); passphrase = ""; recovery = ""; confirmation = ""; generatedPhrase = ""; backupPassword = ""; backupConfirmation = ""; kitPassword = "" } catch { self.error = ErrorMessage(error) }; busy = false }
    }
    private func unlock() { perform { try await session.unlock(passphrase: passphrase, recovery: recovery) } }
    private func submit() {
        perform {
            if let recoveryKitData { try await session.restoreRecoveryKit(recoveryKitData, backupPassword: kitPassword, passphrase: passphrase, recovery: recovery, deviceName: Platform.deviceName, deviceUnlock: deviceUnlock, rememberRecovery: rememberRecovery) }
            else if let restoreData { try await session.restore(restoreData, passphrase: passphrase, recovery: recovery) }
            else { try await session.create(passphrase: passphrase, recovery: recovery, name: profileName, deviceName: Platform.deviceName, rememberRecovery: rememberRecovery, deviceUnlock: deviceUnlock, recoverySetup: backupEnabled ? backupFolder.map { RecoverySetup(password: backupPassword, folder: $0) } : nil) }
        }
    }
}
