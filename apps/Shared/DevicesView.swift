import SwiftUI
import ProximusKit

struct DevicesView: View {
    @ObservedObject var session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var syncing = false
    @State private var approvals = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SectionHeading(title: "Your vault, with you.", subtitle: "Connect a device once. Sync nearby whenever you make changes.")
                    AppCard {
                        ForEach(session.contents?.devices ?? []) { device in
                            HStack(spacing: 14) {
                                Image(systemName: device.id == session.deviceID ? "checkmark.circle.fill" : "laptopcomputer.and.iphone").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(device.name).font(Theme.body().weight(.semibold))
                                    Text(device.id == session.deviceID ? "You’re using this device" : "Connected to this vault").font(Theme.body(13)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                            }.padding(.vertical, 6)
                        }
                    }
                    VStack(spacing: 12) {
                        ActionRow(title: "Add a device", subtitle: "Connect your phone, tablet, or another Mac.", symbol: "plus.circle") { pairing = true }
                        ActionRow(title: "Sync nearby", subtitle: "Share the latest passwords and notes with a connected device.", symbol: "arrow.triangle.2.circlepath") { syncing = true }
                    }
                    Text("Keep Wi-Fi on and Proximus open on both devices. Nearby sync works without an internet connection.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    DisclosureGroup("Extra protection for crypto transfers") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("You can require another device to approve a transfer before this app sends it. Set this up separately from vault sharing.").font(.callout).foregroundStyle(Theme.muted)
                            Button("Set up device approvals") { approvals = true }.buttonStyle(ProximusButtonStyle())
                        }.padding(.top, 12)
                    }
                    DisclosureGroup("If you lose a connected device") {
                        Text("A connected device has a copy of your vault. Removing its name cannot revoke that copy. Change passwords that may be exposed and move to a new vault. Wallet keys and passkeys stay on their original device unless you separately restore wallet keys from a recovery kit.")
                            .font(Theme.body(13)).foregroundStyle(Theme.muted).padding(.top, 10)
                    }
                }.padding(24)
            }.background(Theme.background).navigationTitle("My devices")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(idealWidth: 600, idealHeight: 720)
            .sheet(isPresented: $pairing) { PairingView(session: session, isHost: true) }
            .sheet(isPresented: $syncing) { NearbySyncView(session: session) }
            .sheet(isPresented: $approvals) { DeviceApprovalsView(session: session) }
    }
}
