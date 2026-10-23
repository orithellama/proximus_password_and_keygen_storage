import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import ProximusKit
#if os(iOS)
import UIKit
import AVFoundation
#else
import AppKit
#endif

enum Platform {
    #if os(macOS)
    @MainActor private static var secretClipboardChange: Int?
    @MainActor private static var clipboardTerminationObserver: NSObjectProtocol?
    #endif
    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
    @MainActor static func copySecret(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)])
        #else
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
        let change = board.changeCount
        secretClipboardChange = change
        if clipboardTerminationObserver == nil {
            clipboardTerminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if NSPasteboard.general.changeCount == secretClipboardChange { NSPasteboard.general.clearContents() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if board.changeCount == change { board.clearContents() } }
        #endif
    }
    @MainActor static func copyPublic(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct VaultDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

func readImport(_ url: URL) throws -> Data {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= VaultCrypto.maximumPayload * 2 else { throw ProximusError.invalid("This file is too large.") }
    return try BoundedFile.read(url, limit: VaultCrypto.maximumPayload * 2)
}

struct QRCodeView: View {
    let value: String
    private var qr: CGImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
    var body: some View {
        Group { if let qr { Image(decorative: qr, scale: 1).interpolation(.none).resizable().scaledToFit() } else { Text("QR code unavailable. Copy the pairing link.") } }
            .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 18)).frame(maxWidth: 300, maxHeight: 300)
            .accessibilityLabel("Device pairing QR code")
    }
}

#if os(iOS)
struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let controller = ScannerController(); controller.onCode = onCode; controller.onError = onError; return controller }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: ScannerController, coordinator: ()) { uiViewController.stop() }
}
final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "org.proximus.qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            if !allowed { DispatchQueue.main.async { self.onError?("Allow camera access in Settings or paste the pairing link.") }; return }
            self.queue.async { self.configure() }
        }
    }
    private func configure() {
        do {
            guard let camera = AVCaptureDevice.default(for: .video) else { throw ProximusError.unavailable("No camera is available.") }
            let input = try AVCaptureDeviceInput(device: camera), output = AVCaptureMetadataOutput()
            guard capture.canAddInput(input), capture.canAddOutput(output) else { throw ProximusError.unavailable("Camera setup failed.") }
            capture.addInput(input); capture.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.capture); layer.videoGravity = .resizeAspectFill; layer.frame = self.view.bounds
                self.view.layer.addSublayer(layer); self.preview = layer
            }
            capture.startRunning()
        } catch { DispatchQueue.main.async { self.onError?(error.localizedDescription) } }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { queue.async { self.capture.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, value.hasPrefix("proximus://pair?") else { return }
        delivered = true; stop(); onCode?(value)
    }
}
#endif
