import SwiftUI
import ProximusKit

struct PairingView: View {
    @ObservedObject var session: VaultSession
    let isHost: Bool
    var initialLink = ""
    @StateObject private var pairing = PairingSession()
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var scanning = false
    @State private var error: ErrorMessage?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "iphone.and.arrow.forward").font(.system(size: 40)).foregroundStyle(Theme.accent)
                    Text(isHost ? "Your vault, on another device." : "Bring your vault with you.").font(.largeTitle.bold())
                    Text("Open Proximus on both devices and keep them nearby with Wi-Fi turned on. No router or internet connection is required.").foregroundStyle(.secondary)
                    #if os(macOS)
                    if isHost {
                        DisclosureGroup("Install on your iPhone or iPad") {
                            Text("Connect your device to this Mac and approve Trust This Computer. Enable Developer Mode, then run ./install --phone from your cloned repository. The installer uses your Apple signing team to build, install, and open the phone app. Scan this QR code after installation.").font(.callout).padding(.top, 6)
                        }
                    }
                    #endif
                    if pairing.complete {
                        Label("Device paired", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                        Text("Passwords and notes are available. Passkey private keys stay on their original device. Register a separate passkey on each device where the website supports it.")
                    } else if !pairing.confirmationCode.isEmpty {
                        if !pairing.peerName.isEmpty { Text("Requested by " + pairing.peerName).font(.headline) }
                        Text(pairing.confirmationCode).font(.system(size: 44, weight: .semibold, design: .monospaced)).frame(maxWidth: .infinity).padding().background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                        Text("The numbers must match on both devices. Approve only the device you intend to give vault access to.")
                        Button("The codes match - approve device") { pairing.confirm() }.buttonStyle(ProximusPrimaryButton()).disabled(!pairing.canConfirm)
                    } else if isHost, !pairing.invitationLink.isEmpty {
                        QRCodeView(value: pairing.invitationLink).frame(maxWidth: .infinity)
                        Button("Copy pairing link") { Platform.copySecret(pairing.invitationLink) }
                        Text("This invitation expires in two minutes and can be used once. No vault password or private key is in this QR code.").font(.caption).foregroundStyle(.secondary)
                    } else if !isHost {
                        #if os(iOS)
                        Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }.buttonStyle(ProximusPrimaryButton())
                        #endif
                        TextField("Or paste the pairing link", text: $link).textFieldStyle(.roundedBorder)
                        Button("Connect to device") { join() }.disabled(link.isEmpty || !pairing.status.isEmpty)
                    }
                    if !pairing.status.isEmpty { Text(pairing.status).font(.callout).foregroundStyle(.secondary) }
                    if let failure = pairing.failure { Text(failure).foregroundStyle(.red); Button("Close and try a fresh code") { dismiss() } }
                    Text("Pairing grants access to passwords and notes. A paired device must support Secure Enclave for device unlock.").font(.caption).foregroundStyle(.secondary)
                }.padding(28)
            }.navigationTitle("Pair device").toolbar { ToolbarItem(placement: .cancellationAction) { Button(pairing.complete ? "Done" : "Cancel") { pairing.cancel(); dismiss() } } }
        }.frame(idealWidth: 540, idealHeight: 740).errorAlert($error)
            .task { link = initialLink; if isHost { do { try pairing.host { id, name in try session.pairingBundle(device: id, name: name) } } catch { self.error = ErrorMessage(error) } } }
            .onDisappear { pairing.cancel() }
            .onChange(of: session.isUnlocked) { _, unlocked in if isHost && !unlocked { pairing.cancel(); dismiss() } }
            #if os(iOS)
            .sheet(isPresented: $scanning) {
                NavigationStack { QRScanner(onCode: { value in link = value; scanning = false; join() }, onError: { value in scanning = false; error = ErrorMessage(ProximusError.unavailable(value)) }).ignoresSafeArea(edges: .bottom).navigationTitle("Scan pairing code").toolbar { Button("Cancel") { scanning = false } } }
            }
            #endif
    }
    private func join() { do { try pairing.join(link: link, deviceID: session.deviceID, name: Platform.deviceName) { bundle in try session.installPairing(bundle) } } catch { self.error = ErrorMessage(error) } }
}
