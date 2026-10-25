import SwiftUI
import UniformTypeIdentifiers
import ProximusKit

struct TransferCodeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(_ text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= 3 * 1024 * 1024, let value = String(data: data, encoding: .utf8) else { throw ProximusError.invalid("Invalid approval file.") }
        text = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct TransferCodeOutput: View {
    let code: String
    let filename: String
    @State private var exporting = false
    @State private var error: ErrorMessage?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if code.utf8.count <= 1800 { QRCodeView(value: code).frame(width: 210, height: 210).accessibilityLabel("Proximus approval exchange QR code") }
            else { Text("This request is too large for a QR code. Export the file and send it to the other device with AirDrop, or copy its code.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                CopyValueButton(value: code, title: "Copy code")
                Button("Export file…") { exporting = true }
            }
            Text("Contains public transfer or device identity data, never recovery phrases or private keys.").font(.caption).foregroundStyle(.secondary)
        }.fileExporter(isPresented: $exporting, document: TransferCodeDocument(code), contentType: .plainText, defaultFilename: filename) { result in if case .failure(let failure) = result { error = ErrorMessage(failure) } }.errorAlert($error)
    }
}

struct TransferCodeInput: View {
    let title: String
    var receive: (String) throws -> Void
    @State private var text = ""
    @State private var importing = false
    @State private var scanning = false
    @State private var error: ErrorMessage?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Paste " + title.lowercased(), text: $text).textFieldStyle(ProximusTextFieldStyle())
            HStack {
                Button("Open code") { accept(text) }.disabled(text.isEmpty || text.utf8.count > 3 * 1024 * 1024)
                Button("Import file…") { importing = true }
                #if os(iOS)
                Button("Scan QR") { scanning = true }
                #endif
            }
        }.fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try BoundedFile.read(url, limit: 3 * 1024 * 1024)
                guard let value = String(data: data, encoding: .utf8) else { throw ProximusError.invalid("This is not a Proximus approval file.") }
                accept(value)
            } catch { self.error = ErrorMessage(error) }
        }.errorAlert($error)
        #if os(iOS)
        .sheet(isPresented: $scanning) { NavigationStack {
            QRScanner(requiredPrefix: "proximus-", onCode: { value in scanning = false; accept(value) }, onError: { value in scanning = false; error = ErrorMessage(ProximusError.invalid(value)) })
                .navigationTitle(title).toolbar { Button("Cancel") { scanning = false } }
        } }
        #endif
    }
    private func accept(_ value: String) { do { try receive(value.trimmingCharacters(in: .whitespacesAndNewlines)); text = "" } catch { self.error = ErrorMessage(error) } }
}

struct TransferReviewFields: View {
    let plan: TransferPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(plan.chain.amount(plan.amount)).font(Theme.heading(28)).foregroundStyle(Theme.accent)
            LabeledContent("Chain", value: plan.chain.display)
            if plan.chain.network == .evm { LabeledContent("Chain ID", value: plan.chain.identity) }
            address("From", plan.wallet.address)
            address("To", plan.recipient)
            LabeledContent(plan.feeLabel, value: plan.chain.amount(plan.fee))
            if let total = try? plan.total { LabeledContent("Amount + fee", value: plan.chain.amount(total)) }
            LabeledContent("Review expires", value: plan.expiresAt.formatted(date: .omitted, time: .standard))
            if plan.chain.network == .monero { Text("Your local Monero companion prepared and signed this transaction without broadcasting. Device approval gates relay. Proximus relies on the companion for Monero construction and fee reporting.").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Transfer fingerprint") { Text((try? plan.fingerprint) ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }
    }
    private func address(_ title: String, _ address: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(address).font(.system(.callout, design: .monospaced)).textSelection(.enabled) } }
}
