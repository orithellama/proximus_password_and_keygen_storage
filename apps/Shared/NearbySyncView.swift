import SwiftUI
import ProximusKit

struct NearbySyncView: View {
    @ObservedObject var session: VaultSession
    @StateObject private var nearby = NearbySyncSession()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var error: ErrorMessage?
    @State private var merge = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 38)).foregroundStyle(Theme.accent)
                Text("Sync with a nearby device").font(Theme.heading(26))
                Text("1. Unlock Proximus on your other device.\n2. Open My devices → Sync nearby there too.\n3. Keep both apps open until sync finishes.").lineSpacing(6)
                Text("Keep Wi-Fi on. You don’t need internet or the same Wi-Fi network.").font(.callout).foregroundStyle(Theme.muted)
                if !nearby.complete && nearby.failure == nil { ProgressView() }
                Text(nearby.status).font(Theme.body().weight(.medium))
                if let failure = nearby.failure { Text(failure).foregroundStyle(.secondary) }
                if session.conflictingHead != nil {
                    Button("Review conflict: keep both versions") { merge = true }.buttonStyle(ProximusButtonStyle(.primary))
                }
                if nearby.complete || nearby.failure != nil { Button("Sync again") { start() }.buttonStyle(ProximusButtonStyle()) }
                Spacer()
                Text("Only devices that already have this vault can authenticate. To add a new device, use My devices → Add a device first.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).background(Theme.background)
                .navigationTitle("Sync nearby")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { nearby.cancel(); dismiss() } } }
        }.frame(idealWidth: 520, idealHeight: 470).errorAlert($error)
            .task { start() }
            .onDisappear { nearby.cancel() }
            .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { nearby.cancel(); dismiss() } }
            .onChange(of: phase) { _, phase in if phase == .background { nearby.cancel(); dismiss() } }
            .confirmationDialog("Keep both versions?", isPresented: $merge, titleVisibility: .visible) {
                Button("Merge changes") { Task { do { try await session.mergeConflict(); start() } catch { self.error = ErrorMessage(error) } } }
            } message: { Text("Different versions will both be kept. Items deleted on only one device can reappear. Review the merged vault, then run Nearby sync on both devices again.") }
    }
    private func start() { nearby.cancel(); do { try nearby.start(session: session) } catch { self.error = ErrorMessage(error) } }
}
