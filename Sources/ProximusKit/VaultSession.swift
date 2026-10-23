import Foundation
import Combine

@MainActor public final class VaultSession: ObservableObject {
    public let repository: VaultRepository
    public let deviceID: UUID
    @Published public private(set) var state: VaultState?
    @Published public private(set) var contents: VaultContents?
    @Published public private(set) var relay: RelayConfiguration?
    @Published public private(set) var syncStatus = "Local only"
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
    public func create(passphrase: String, recovery: String, name: String, deviceName: String, rememberRecovery: Bool) async throws {
        let generation = lockGeneration
        let secret = try VaultCrypto.decodeRecovery(recovery)
        let contents = VaultContents(name: name, devices: [PairedDevice(id: deviceID, name: deviceName)])
        let repository = repository
        let (state, key) = try await Task.detached(priority: .userInitiated) { try repository.create(passphrase: passphrase, recovery: secret, contents: contents) }.value
        if rememberRecovery { try DeviceKeychain.write(secret, account: "recovery/" + state.header.vaultID.uuidString) }
        self.state = state
        guard generation == lockGeneration else { throw ProximusError.locked }
        try activate(key: key, state: state)
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
        lockTask?.cancel(); lockTask = nil
        key?.erase(); key = nil; contents = nil; conflictingHead = nil
    }
    public func reload() throws {
        guard let key else { throw ProximusError.locked }
        let current = try repository.state()
        contents = try key.withData { try repository.contents(state: current, key: $0) }; state = current
    }
    public func save(_ item: VaultItem) async throws {
        guard var contents else { throw ProximusError.locked }
        var item = try item.validated(); item.modifiedAt = Date()
        if let index = contents.items.firstIndex(where: { $0.id == item.id }) { contents.items[index] = item } else { contents.items.append(item) }
        try persist(contents)
        if indexEnabled { await refreshIndex(contents.items) }
    }
    public func delete(_ item: VaultItem) async throws {
        guard var contents else { throw ProximusError.locked }
        contents.items.removeAll { $0.id == item.id }; try persist(contents)
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
    private func persist(_ contents: VaultContents) throws {
        guard let key, let state else { throw ProximusError.locked }
        self.state = try key.withData { try repository.save(contents, key: $0, expected: state) }
        self.contents = contents; touch()
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
        conflictingHead = nil; try reload(); try await synchronize()
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
