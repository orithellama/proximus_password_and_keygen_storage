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
    @Published public private(set) var walletBalances: [UUID: WalletBalance] = [:]
    private var key: SecretBytes?
    private var lockTask: Task<Void, Never>?
    private var lockGeneration: UInt64 = 0
    private var transferringWallets = Set<UUID>()
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
    public static func visualFixture(contents: VaultContents, deviceID: UUID, sampleWalletBalances: Bool = false) throws -> VaultSession {
        let repository = try VaultRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("proximus-preview-" + UUID().uuidString))
        let (state, key) = try repository.create(passphrase: "visual preview fixture only", recovery: VaultCrypto.random(32), contents: contents)
        let session = try VaultSession(repository: repository, deviceID: deviceID)
        session.state = state; session.key = try SecretBytes(key); session.contents = contents
        if sampleWalletBalances {
            for item in contents.items {
                guard let wallet = item.wallet else { continue }
                let identity: String, atoms: String
                switch wallet.network {
                case .solana: identity = WalletChain.solanaGenesis; atoms = "12500000000"
                case .evm: identity = "1"; atoms = "1250000000000000000"
                case .bitcoin: identity = "main"; atoms = "4500000"
                case .monero: identity = "mainnet"; atoms = "2200000000000"
                }
                let amount = try NativeAmount(atoms)
                session.walletBalances[wallet.id] = try WalletBalance(chain: WalletChain.resolve(wallet.network, identity: identity), available: amount, total: amount, checkedAt: Date(), detail: "Sample balance for app preview")
            }
        }
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
        let remembered = recovery.isEmpty ? try await Task.detached(priority: .userInitiated) {
            try DeviceKeychain.read("recovery/" + state.header.vaultID.uuidString)
        }.value : nil
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
        walletBalances.removeAll()
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

extension VaultSession {
    public func refreshWalletBalance(_ wallet: WalletMetadata) async throws {
        guard isUnlocked, contents?.items.contains(where: { $0.wallet == wallet }) == true else { throw ProximusError.locked }
        guard let configuration = try RPCConfiguration.load(wallet.network) else { throw ProximusError.unavailable("Add your RPC endpoint in Custom RPC nodes, then refresh this wallet.") }
        let generation = lockGeneration
        let value = try await WalletRPCClient(configuration: configuration).balance(wallet: wallet)
        try requireGeneration(generation); walletBalances[wallet.id] = value; touch()
    }
    public func clearWalletBalances() { walletBalances.removeAll() }
    private func requireTransferWallet(_ wallet: WalletMetadata) throws {
        guard isUnlocked, contents?.items.contains(where: { $0.wallet == wallet }) == true else { throw ProximusError.locked }
        guard wallet.ownerDeviceID == deviceID else { throw ProximusError.unavailable("Send from the original device that holds this wallet’s keys.") }
        try LocalWalletStore(deviceID: deviceID).verifyRecord(wallet)
    }
    private func requireGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard isUnlocked, generation == lockGeneration else { throw ProximusError.locked }
    }
    public func approvalIdentity(name: String) async throws -> ApprovalIdentity {
        guard isUnlocked, let vault = state?.header.vaultID else { throw ProximusError.locked }
        let generation = lockGeneration, device = deviceID
        let identity = try await Task.detached { try ApprovalKeys.identity(vault: vault, device: device, name: name) }.value
        try requireGeneration(generation); return identity
    }
    public func trustApprovalDevice(_ peer: ApprovalIdentity) async throws {
        guard isUnlocked, peer.vaultID == state?.header.vaultID, peer.deviceID != deviceID,
              contents?.devices.contains(where: { $0.id == peer.deviceID }) == true else { throw ProximusError.invalid("Pair this device to the same vault first, then compare its approval fingerprint.") }
        try peer.validate()
        let generation = lockGeneration
        try await Task.detached { try ApprovalKeys.authorize(vault: peer.vaultID, reason: "Trust the approval device whose fingerprint you compared") }.value
        try requireGeneration(generation); try ApprovalStore.trust(peer); touch()
    }
    public func setApprovalDevice(_ peer: ApprovalIdentity?, wallet: WalletMetadata) async throws {
        try requireTransferWallet(wallet)
        guard let vault = state?.header.vaultID else { throw ProximusError.locked }
        if let peer {
            guard peer.deviceID != deviceID, peer.vaultID == vault,
                  try ApprovalStore.peers(vault: vault).contains(peer), contents?.devices.contains(where: { $0.id == peer.deviceID }) == true else { throw ProximusError.authentication }
        }
        let generation = lockGeneration
        try await Task.detached { try ApprovalKeys.authorize(vault: vault, reason: peer == nil ? "Turn off paired-device approval for this wallet" : "Require this paired device to approve wallet transfers") }.value
        try requireGeneration(generation); try ApprovalStore.setPolicy(peer, wallet: wallet.id); touch()
    }
    public func makeApprovalRequest(_ plan: TransferPlan, deviceName: String) async throws -> TransferApprovalRequest {
        try requireTransferWallet(plan.wallet); try plan.validate()
        guard state?.header.vaultID == plan.vaultID, try ApprovalStore.policy(wallet: plan.wallet.id) != nil else { throw ProximusError.authentication }
        let generation = lockGeneration, device = deviceID
        let request = try await Task.detached {
            let identity = try ApprovalKeys.identity(vault: plan.vaultID, device: device, name: deviceName)
            let signature = try ApprovalKeys.sign(ApprovalKeys.message(plan, domain: "request"), vault: plan.vaultID, reason: "Request approval for this reviewed transfer")
            return TransferApprovalRequest(plan: plan, requester: identity, signature: signature)
        }.value
        try requireGeneration(generation); try plan.validate(); touch(); return request
    }
    public func validateApprovalRequest(_ request: TransferApprovalRequest) throws {
        guard isUnlocked, state?.header.vaultID == request.plan.vaultID,
              contents?.items.contains(where: { $0.wallet == request.plan.wallet }) == true,
              contents?.devices.contains(where: { $0.id == request.requester.deviceID }) == true,
              let peer = try ApprovalStore.peers(vault: request.plan.vaultID).first(where: { $0.deviceID == request.requester.deviceID }) else { throw ProximusError.invalid("Trust the sending device’s fingerprint in Device approvals and sync this wallet’s public address first.") }
        try request.validate(peer: peer, deviceID: deviceID)
    }
    public func approveTransfer(_ request: TransferApprovalRequest) async throws -> TransferApproval {
        try validateApprovalRequest(request)
        let generation = lockGeneration, device = deviceID, plan = request.plan
        let signature = try await Task.detached { try ApprovalKeys.sign(ApprovalKeys.message(plan, domain: "approval"), vault: plan.vaultID, reason: "Approve sending " + plan.chain.amount(plan.amount) + " on " + plan.chain.name) }.value
        try requireGeneration(generation); try validateApprovalRequest(request); touch()
        return TransferApproval(requestID: plan.id, planDigest: try plan.fingerprint, deviceID: device, signature: signature)
    }
    public func prepareTransfer(wallet: WalletMetadata, client: WalletRPCClient, recipient: String, amount: String) async throws -> PreparedTransfer {
        try requireTransferWallet(wallet)
        guard let vault = state?.header.vaultID, !transferringWallets.contains(wallet.id) else { throw ProximusError.unavailable("A transfer operation is already running for this wallet.") }
        transferringWallets.insert(wallet.id); defer { transferringWallets.remove(wallet.id) }
        let generation = lockGeneration
        if wallet.network == .monero {
            try await Task.detached { try ApprovalKeys.authorize(vault: vault, reason: "Ask your local Monero companion to prepare a transfer without broadcasting") }.value
            try requireGeneration(generation)
        }
        let transfer = try await client.prepare(wallet: wallet, vaultID: vault, recipient: recipient, amount: amount)
        try requireGeneration(generation); touch(); return transfer
    }
    public func sendTransfer(_ transfer: PreparedTransfer, client: WalletRPCClient, approval: TransferApproval?) async throws -> TransferReceipt {
        let plan = transfer.plan
        try requireTransferWallet(plan.wallet); try plan.validate()
        guard state?.header.vaultID == plan.vaultID, !transferringWallets.contains(plan.wallet.id),
              try DeviceKeychain.read("transfer-used/" + plan.id.uuidString) == nil else { throw ProximusError.invalid("This transfer was already submitted or is in progress. Check its transaction ID before sending again.") }
        transferringWallets.insert(plan.wallet.id); defer { transferringWallets.remove(plan.wallet.id) }
        let generation = lockGeneration, device = deviceID
        let policy = try ApprovalStore.policy(wallet: plan.wallet.id)
        if let policy { guard contents?.devices.contains(where: { $0.id == policy.deviceID }) == true else { throw ProximusError.authentication } }
        try ApprovalStore.verify(approval, plan: plan)
        try await client.revalidate(transfer); try requireGeneration(generation)
        let wire: NativeWire?
        if plan.chain.network == .monero {
            try await Task.detached { try ApprovalKeys.authorize(vault: plan.vaultID, reason: "Send " + plan.chain.amount(plan.amount) + " through your local Monero companion") }.value
            wire = nil
        } else {
            wire = try await Task.detached(priority: .userInitiated) {
                var material = try LocalWalletStore(deviceID: device, authenticationReason: "Sign the reviewed transfer of " + plan.chain.amount(plan.amount)).reveal(plan.wallet)
                defer { material.privateKey = ""; material.recovery = ""; material.secondaryPrivateKey = "" }
                guard var transaction = plan.transaction else { throw ProximusError.authentication }
                transaction.action = "sign"; transaction.privateKey = material.privateKey
                defer { transaction.privateKey = "" }
                let result = try NativeSigner.process(transaction)
                guard result.unsigned == plan.unsigned, plan.chain.network == .solana || result.fee == plan.fee.atoms else { throw ProximusError.authentication }
                return result
            }.value
        }
        try requireGeneration(generation)
        // Authentication may take long enough to expire a blockhash or change a nonce.
        try await client.revalidate(transfer); try requireGeneration(generation)
        try requireTransferWallet(plan.wallet)
        guard try ApprovalStore.policy(wallet: plan.wallet.id) == policy else { throw ProximusError.invalid("The wallet approval policy changed. Prepare a fresh transfer.") }
        try ApprovalStore.verify(approval, plan: plan)
        let transactionID = wire?.transactionId ?? plan.companionTransactionID ?? ""
        guard !transactionID.isEmpty else { throw ProximusError.authentication }
        var receipt = TransferReceipt(id: plan.id, walletID: plan.wallet.id, chain: plan.chain, transactionID: transactionID, recipient: plan.recipient, amount: plan.amount, date: Date(), status: "Submission started; confirmation unknown")
        // Persist the expected ID and consume this review BEFORE making a network request.
        // A timeout must never result in automatic signing of a replacement transfer.
        try receipt.save()
        try DeviceKeychain.write(Data(transactionID.utf8), account: "transfer-used/" + plan.id.uuidString)
        do {
            let returned = try await client.broadcast(wire, transfer: transfer)
            receipt.status = returned == transactionID ? "Submitted to node; awaiting confirmation" : "Node returned a different ID. Check the expected transaction ID before sending again."
        } catch { receipt.status = "Submission outcome unknown. Check this transaction ID before sending again." }
        // The pre-broadcast receipt survives even if the device locks during submission.
        try? receipt.save()
        touch(); return receipt
    }
}
