import Foundation
import Combine

@MainActor public final class VaultSession: ObservableObject {
    public let repository: VaultRepository
    public let deviceID: UUID
    @Published public private(set) var state: VaultState?
    @Published public private(set) var contents: VaultContents?
    @Published public private(set) var relay: RelayConfiguration?
    @Published public private(set) var syncStatus = "Local only"
    @Published public private(set) var recoveryStatus = "Recovery backup is off"
    private var recoveryBackup: RecoveryBackupSession?
    private var recoveryUpdate: Task<Void, Never>?
    private var recoveryEpoch: UInt64 = 0
    private var recoveryOperation = false
    @Published public private(set) var conflictingHead: String?
    @Published public private(set) var indexEnabled: Bool
    private var key: SecretBytes?
    private var lockTask: Task<Void, Never>?
    private var lockGeneration: UInt64 = 0
    private let preferences: UserDefaults
    public var isUnlocked: Bool { contents != nil && key != nil }
    public var hasVault: Bool { repository.exists }
    public init(repository: VaultRepository, deviceID: UUID) throws {
        self.repository = repository; self.deviceID = deviceID
        preferences = AppEnvironment.isStandaloneMac ? .standard : (AppEnvironment.appGroup.flatMap { UserDefaults(suiteName: $0) } ?? .standard)
        indexEnabled = preferences.bool(forKey: "credential-index-enabled")
        if repository.exists { state = try repository.state() }
    }
    #if DEBUG
    /// Isolated rendering fixtures. This entry point is absent from Release builds.
    public static func visualFixture(contents: VaultContents, deviceID: UUID) throws -> VaultSession {
        let repository = try VaultRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("proximus-preview-" + UUID().uuidString))
        let (state, key) = try repository.create(passphrase: "visual preview fixture only", recovery: VaultCrypto.random(32), contents: contents)
        let session = try VaultSession(repository: repository, deviceID: deviceID)
        session.state = state; session.key = try SecretBytes(key); session.contents = contents
        return session
    }
    #endif
    public func create(passphrase: String, recovery: String, name: String, deviceName: String, rememberRecovery: Bool, deviceUnlock: Bool = false, recoverySetup: RecoverySetup? = nil) async throws {
        let generation = lockGeneration
        let secret = try VaultCrypto.decodeRecovery(recovery)
        let contents = VaultContents(name: name, devices: [PairedDevice(id: deviceID, name: deviceName)])
        let repository = repository
        let (state, key) = try await Task.detached(priority: .userInitiated) { try repository.create(passphrase: passphrase, recovery: secret, contents: contents) }.value
        self.state = state
        if rememberRecovery { try DeviceKeychain.write(secret, account: "recovery/" + state.header.vaultID.uuidString) }
        do {
            if deviceUnlock { try await Task.detached { try HardwareUnlock.enable(vault: state.header.vaultID, key: key) }.value }
        } catch { throw ProximusError.unavailable("Vault created. Unlock with your master passphrase and recovery key, then enable device unlock in Settings. " + error.localizedDescription) }
        var backup: RecoveryBackupSession?
        if let setup = recoverySetup {
            do { backup = try await Task.detached { try RecoveryBackupSession.configure(vaultID: state.header.vaultID, payload: RecoveryPayload(contents: contents, wallets: []), password: setup.password, folder: setup.folder) }.value }
            catch { throw ProximusError.unavailable("Vault created. Unlock it and finish recovery backup setup in Settings. " + error.localizedDescription) }
        }
        guard generation == lockGeneration else { await backup?.lock(); throw ProximusError.locked }
        recoveryBackup = backup
        try activate(key: key, state: state)
        if backup != nil { recoveryStatus = "Encrypted kit saved to your chosen folder." }
    }
    public func unlock(passphrase: String, recovery: String) async throws {
        let generation = lockGeneration
        let state = try repository.state()
        let remembered = recovery.isEmpty ? try DeviceKeychain.read("recovery/" + state.header.vaultID.uuidString) : nil
        let secret = recovery.isEmpty ? remembered : try VaultCrypto.decodeRecovery(recovery)
        guard let secret else { throw ProximusError.invalid("Enter the recovery key from your kit for this device.") }
        let repository = repository
        let (current, _, key) = try await Task.detached(priority: .userInitiated) { try repository.unlock(passphrase: passphrase, recovery: secret) }.value
        guard generation == lockGeneration else { throw ProximusError.locked }
        try activate(key: key, state: current)
    }
    public func unlockWithDevice() async throws {
        let generation = lockGeneration
        let state = try repository.state()
        let key = try await Task.detached(priority: .userInitiated) { try HardwareUnlock.unlock(vault: state.header.vaultID) }.value
        guard generation == lockGeneration else { throw ProximusError.locked }
        try activate(key: key, state: state)
    }
    private func activate(key: Data, state: VaultState) throws {
        let contents = try repository.contents(state: state, key: key)
        self.key?.erase(); self.key = try SecretBytes(key); self.contents = contents; self.state = state
        if let data = try DeviceKeychain.read("relay/" + state.header.vaultID.uuidString) { relay = try Encoding.decode(RelayConfiguration.self, from: data).validated() }
        else { relay = nil }
        syncStatus = relay == nil ? "Local only" : "Ready to sync"
        touch()
        if recoveryBackup == nil, RecoveryBackupSession.isConfigured(state.header.vaultID) {
            let generation = lockGeneration
            Task { [weak self] in
                guard let self, self.isUnlocked, self.lockGeneration == generation else { return }
                do { try await self.resumeRecoveryBackup() }
                catch { if self.isUnlocked, self.lockGeneration == generation, self.recoveryBackup == nil { self.recoveryStatus = "Backup paused. Resume it in Settings." } }
            }
            recoveryStatus = "Unlock recovery backups to resume automatic saving"
        }
    }
    public func touch() {
        guard isUnlocked else { return }
        lockTask?.cancel()
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }
    public func lock() {
        lockGeneration &+= 1
        recoveryEpoch &+= 1
        let backup = recoveryBackup; recoveryBackup = nil
        recoveryUpdate?.cancel(); recoveryUpdate = nil
        Task { await backup?.lock() }
        if let id = state?.header.vaultID, RecoveryBackupSession.isConfigured(id) { recoveryStatus = "Recovery backup paused while locked" }
        lockTask?.cancel(); lockTask = nil
        key?.erase(); key = nil; contents = nil; conflictingHead = nil
    }
    public func reload() throws {
        guard let key else { throw ProximusError.locked }
        let current = try repository.state()
        contents = try key.withData { try repository.contents(state: current, key: $0) }; state = current
        if let contents { queueRecoveryBackup(contents) }
    }
    public func save(_ item: VaultItem, walletRecovery: WalletRecoveryRecord? = nil) async throws {
        guard var contents else { throw ProximusError.locked }
        var item = try item.validated(); item.modifiedAt = Date()
        if let index = contents.items.firstIndex(where: { $0.id == item.id }) { contents.items[index] = item } else { contents.items.append(item) }
        try persist(contents, walletRecovery: walletRecovery)
        if indexEnabled { await refreshIndex(contents.items) }
    }
    public func createWallet(network: WalletNetwork, title: String, recovery: String = "") async throws -> UUID {
        guard isUnlocked else { throw ProximusError.locked }
        let generation = lockGeneration, device = deviceID
        let (metadata, material) = try await Task.detached(priority: .userInitiated) {
            let material = try WalletCrypto.derive(network: network, recovery: recovery)
            let metadata = material.metadata(network: network, deviceID: device)
            try LocalWalletStore(deviceID: device).save(material, metadata: metadata)
            return (metadata, material)
        }.value
        do {
            guard isUnlocked, generation == lockGeneration else { throw ProximusError.locked }
            let item = VaultItem(kind: .wallet, title: title, wallet: metadata)
            try await save(item, walletRecovery: WalletRecoveryRecord(metadata: metadata, material: material))
            return item.id
        } catch { try? LocalWalletStore(deviceID: device).remove(metadata); throw error }
    }
    public func revealWallet(_ metadata: WalletMetadata) async throws -> WalletMaterial {
        guard isUnlocked, contents?.items.contains(where: { $0.wallet == metadata }) == true else { throw ProximusError.locked }
        let generation = lockGeneration, device = deviceID
        let material = try await Task.detached(priority: .userInitiated) { try LocalWalletStore(deviceID: device).reveal(metadata) }.value
        guard isUnlocked, generation == lockGeneration else { throw ProximusError.locked }
        touch(); return material
    }
    public func delete(_ item: VaultItem) async throws {
        guard var contents else { throw ProximusError.locked }
        contents.items.removeAll { $0.id == item.id }; try persist(contents)
        if let wallet = item.wallet, wallet.ownerDeviceID == deviceID, !contents.items.contains(where: { $0.wallet?.id == wallet.id }) { try LocalWalletStore(deviceID: deviceID).remove(wallet) }
        if let passkey = item.passkey, passkey.deviceID == deviceID { try PasskeySigner.remove(passkey.credentialID) }
        if indexEnabled { await refreshIndex(contents.items) }
    }
    public func importPasswords(_ items: [VaultItem]) async throws {
        guard var contents else { throw ProximusError.locked }
        contents.items.append(contentsOf: items)
        try contents.validate(); try persist(contents)
        if indexEnabled { await refreshIndex(contents.items) }
    }
    private func refreshIndex(_ items: [VaultItem]) async {
        do { try await CredentialIndex.replace(items: items, deviceID: deviceID) }
        catch { syncStatus = "Saved locally. Re-enable AutoFill suggestions in Settings to refresh them." }
    }
    private func persist(_ contents: VaultContents, walletRecovery: WalletRecoveryRecord? = nil) throws {
        guard let key, let state else { throw ProximusError.locked }
        self.state = try key.withData { try repository.save(contents, key: $0, expected: state) }
        self.contents = contents; touch(); queueRecoveryBackup(contents, walletRecovery: walletRecovery)
    }
    public func enableDeviceUnlock() async throws {
        guard let state, let key else { throw ProximusError.locked }
        let data = key.withData { $0 }
        try await Task.detached(priority: .userInitiated) { try HardwareUnlock.enable(vault: state.header.vaultID, key: data) }.value
    }
    public func setIndexEnabled(_ enabled: Bool) async throws {
        guard let contents else { throw ProximusError.locked }
        if enabled { try await CredentialIndex.replace(items: contents.items, deviceID: deviceID) } else { try await CredentialIndex.clear() }
        preferences.set(enabled, forKey: "credential-index-enabled"); indexEnabled = enabled
    }
    public func exportBackup() throws -> Data { guard isUnlocked else { throw ProximusError.locked }; return try repository.backup() }
    public func restore(_ data: Data, passphrase: String, recovery: String) async throws {
        let generation = lockGeneration
        let secret = try VaultCrypto.decodeRecovery(recovery), repository = repository
        let key = try await Task.detached(priority: .userInitiated) { try repository.restore(data, passphrase: passphrase, recovery: secret) }.value
        try DeviceKeychain.write(secret, account: "recovery/" + repository.state().header.vaultID.uuidString)
        self.state = try repository.state()
        guard generation == lockGeneration else { throw ProximusError.locked }
        try activate(key: key, state: repository.state())
    }
    public func connectRelay(url: URL, enrollment: String) async throws {
        guard isUnlocked, let state else { throw ProximusError.locked }
        let configuration = try RelayConfiguration(endpoint: url, token: VaultCrypto.random(32).base64URLEncoded)
        let client = try RelayClient(configuration: configuration, vaultID: state.header.vaultID)
        try await client.create(enrollment: enrollment)
        try DeviceKeychain.write(Encoding.encode(configuration), account: "relay/" + state.header.vaultID.uuidString)
        relay = configuration
        try await synchronize()
    }
    public func disconnectRelay() throws {
        guard let state else { throw ProximusError.locked }
        try DeviceKeychain.delete("relay/" + state.header.vaultID.uuidString); relay = nil; syncStatus = "Local only"
    }
    public func synchronize() async throws {
        guard let key, let state, let relay else { throw ProximusError.unavailable("Connect a relay first.") }
        syncStatus = "Syncing encrypted data…"
        do {
            let sync = VaultSync(repository: repository, client: try RelayClient(configuration: relay, vaultID: state.header.vaultID))
            let result = try await sync.synchronize(key: key.withData { $0 }, expected: state)
            // A lock or a local edit while the request was in flight must not reopen stale UI.
            guard isUnlocked else { return }
            switch result {
            case .unchanged: syncStatus = "Up to date"
            case .updated: try reload(); syncStatus = "Up to date"; if indexEnabled, let contents { try await CredentialIndex.replace(items: contents.items, deviceID: deviceID) }
            case .conflict(let remote): conflictingHead = remote; syncStatus = "Review changes from another device"
            }
        } catch { syncStatus = "Sync stopped. Your local vault is available."; throw error }
    }
    public func mergeConflict() async throws {
        guard let remote = conflictingHead, let state, let key else { throw ProximusError.locked }
        self.state = try key.withData { try repository.merge(local: state, remote: remote, key: $0) }
        conflictingHead = nil; try reload()
        if relay != nil { try await synchronize() }
        else { syncStatus = "Changes merged. Sync nearby again to share them." }
    }
    func nearbyKey() throws -> Data {
        guard let key, isUnlocked else { throw ProximusError.locked }
        return key.withData { $0 }
    }
    func finishNearby(_ result: SyncResult) async throws {
        guard isUnlocked else { throw ProximusError.locked }
        try reload()
        if case .conflict(let head) = result {
            conflictingHead = head; syncStatus = "Review changes from a nearby device"
        } else { syncStatus = "Nearby sync complete" }
        if indexEnabled, let contents { await refreshIndex(contents.items) }
        touch()
    }
    public var hasRecoveryBackup: Bool { state.map { RecoveryBackupSession.isConfigured($0.header.vaultID) } ?? false }
    public func enableRecoveryBackup(password: String, folder: Data) async throws {
        guard let state, let contents, isUnlocked else { throw ProximusError.locked }
        guard !recoveryOperation else { throw ProximusError.unavailable("A recovery backup operation is already in progress.") }
        recoveryOperation = true; defer { recoveryOperation = false }
        await suspendRecoveryBackup()
        guard isUnlocked else { throw ProximusError.locked }
        let generation = lockGeneration, device = deviceID
        recoveryStatus = "Authorizing recovery backup…"
        let backup = try await Task.detached(priority: .userInitiated) {
            let store = try LocalWalletStore(deviceID: device)
            let metadata = Dictionary(grouping: contents.items.compactMap(\.wallet).filter { $0.ownerDeviceID == device }, by: \.id).compactMap { $0.value.first }
            let records = try metadata.map { WalletRecoveryRecord(metadata: $0, material: try store.reveal($0)) }
            return try RecoveryBackupSession.configure(vaultID: state.header.vaultID, payload: RecoveryPayload(contents: contents, wallets: records), password: password, folder: folder)
        }.value
        guard isUnlocked, generation == lockGeneration else { await backup.lock(); throw ProximusError.locked }
        let old = recoveryBackup; recoveryBackup = backup; await old?.lock()
        if let current = self.contents { queueRecoveryBackup(current) }
    }
    public func resumeRecoveryBackup() async throws {
        guard let state, isUnlocked else { throw ProximusError.locked }
        guard !recoveryOperation else { throw ProximusError.unavailable("A recovery backup operation is already in progress.") }
        recoveryOperation = true; defer { recoveryOperation = false }
        await suspendRecoveryBackup()
        guard isUnlocked else { throw ProximusError.locked }
        let generation = lockGeneration, device = deviceID
        guard let backup = try await Task.detached(priority: .userInitiated, operation: { try RecoveryBackupSession.resume(vaultID: state.header.vaultID) }).value else { throw ProximusError.unavailable("Choose a recovery backup folder first.") }
        do {
            guard generation == lockGeneration, let current = contents, isUnlocked else { throw ProximusError.locked }
            let missing = try await backup.missingWallets(contents: current, deviceID: device)
            for metadata in missing {
                let material = try await Task.detached { try LocalWalletStore(deviceID: device).reveal(metadata) }.value
                guard generation == lockGeneration, let latest = contents, isUnlocked else { throw ProximusError.locked }
                try await backup.update(contents: latest, newWallet: WalletRecoveryRecord(metadata: metadata, material: material))
            }
            guard generation == lockGeneration, let latest = contents, isUnlocked else { throw ProximusError.locked }
            let old = recoveryBackup; recoveryBackup = backup; await old?.lock()
            queueRecoveryBackup(latest)
        } catch { await backup.lock(); throw error }
    }
    public func disableRecoveryBackup() async throws {
        guard isUnlocked, let id = state?.header.vaultID else { throw ProximusError.locked }
        guard !recoveryOperation else { throw ProximusError.unavailable("Wait for the current recovery backup operation to finish.") }
        recoveryOperation = true; defer { recoveryOperation = false }
        await suspendRecoveryBackup()
        try RecoveryBackupSession.disable(vaultID: id)
        recoveryStatus = "Recovery backup is off. Existing files remain in your chosen folder."
    }
    private func suspendRecoveryBackup() async {
        recoveryEpoch &+= 1
        let old = recoveryBackup, pending = recoveryUpdate
        recoveryBackup = nil; recoveryUpdate = nil; pending?.cancel()
        await old?.lock()
        await pending?.value
    }
    private func queueRecoveryBackup(_ contents: VaultContents, walletRecovery: WalletRecoveryRecord? = nil) {
        guard let backup = recoveryBackup else { return }
        let previous = recoveryUpdate, generation = lockGeneration, epoch = recoveryEpoch, device = deviceID
        recoveryStatus = "Saving encrypted recovery kit…"
        // Preserve order and new-wallet recovery records across rapid edits.
        recoveryUpdate = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.isUnlocked, self.lockGeneration == generation, self.recoveryEpoch == epoch else { return }
            do {
                try await backup.update(contents: contents, newWallet: walletRecovery)
                let missing = try await backup.missingWallets(contents: contents, deviceID: device)
                if self.isUnlocked, self.lockGeneration == generation, self.recoveryEpoch == epoch { self.recoveryStatus = missing.isEmpty ? "Encrypted kit saved to your chosen folder." : "Wallet keys are missing from this kit. Resume backup to include them." }
            } catch { if self.isUnlocked, self.lockGeneration == generation, self.recoveryEpoch == epoch { self.recoveryStatus = "Backup needs attention: " + error.localizedDescription } }
        }
    }
    public func restoreRecoveryKit(_ data: Data, backupPassword: String, passphrase: String, recovery: String, deviceName: String, deviceUnlock: Bool = true, rememberRecovery: Bool = true) async throws {
        guard !hasVault else { throw ProximusError.conflict }
        let generation = lockGeneration, device = deviceID, repository = repository
        let secret = try VaultCrypto.decodeRecovery(recovery)
        let (state, key) = try await Task.detached(priority: .userInitiated) {
            let payload = try RecoveryKit.open(data, password: backupPassword)
            var contents = payload.contents
            let store = try LocalWalletStore(deviceID: device)
            var installed = [WalletMetadata]()
            do {
                for record in payload.wallets {
                    let material = try WalletCrypto.derive(network: record.metadata.network, recovery: record.material.recovery)
                    let metadata = material.metadata(network: record.metadata.network, deviceID: device)
                    try store.save(material, metadata: metadata); installed.append(metadata)
                    for i in contents.items.indices where contents.items[i].wallet == record.metadata { contents.items[i].wallet = metadata }
                }
                contents.devices = [PairedDevice(id: device, name: deviceName)]
                return try repository.create(passphrase: passphrase, recovery: secret, contents: contents)
            } catch { for metadata in installed { try? store.remove(metadata) }; throw error }
        }.value
        self.state = state
        if rememberRecovery { try DeviceKeychain.write(secret, account: "recovery/" + state.header.vaultID.uuidString) }
        if deviceUnlock {
            do { try await Task.detached { try HardwareUnlock.enable(vault: state.header.vaultID, key: key) }.value }
            catch { throw ProximusError.unavailable("Recovery completed. Unlock with your new master passphrase and recovery key, then enable device unlock in Settings. " + error.localizedDescription) }
        }
        guard generation == lockGeneration else { throw ProximusError.locked }
        try activate(key: key, state: state)
        recoveryStatus = "Recovered into a new local vault. Choose a backup folder to resume automatic saving."
    }
    public func pairingBundle(device: UUID, name: String) throws -> PairingBundle {
        guard var contents, let key else { throw ProximusError.locked }
        if !contents.devices.contains(where: { $0.id == device }) { contents.devices.append(PairedDevice(id: device, name: name)); try persist(contents) }
        guard let state else { throw ProximusError.locked }
        return PairingBundle(header: state.header, snapshot: try repository.object(state.head), vaultKey: key.withData { $0 }, recovery: try DeviceKeychain.read("recovery/" + state.header.vaultID.uuidString), relay: relay)
    }
    public func installPairing(_ bundle: PairingBundle) throws {
        try bundle.validate()
        // Provision hardware unlock before committing the vault so a paired device is usable.
        try HardwareUnlock.enable(vault: bundle.header.vaultID, key: bundle.vaultKey)
        if let recovery = bundle.recovery { try DeviceKeychain.write(recovery, account: "recovery/" + bundle.header.vaultID.uuidString) }
        if let relay = bundle.relay { try DeviceKeychain.write(Encoding.encode(relay), account: "relay/" + bundle.header.vaultID.uuidString) }
        try repository.install(header: bundle.header, snapshot: bundle.snapshot, key: bundle.vaultKey)
        try activate(key: bundle.vaultKey, state: repository.state())
    }
}
