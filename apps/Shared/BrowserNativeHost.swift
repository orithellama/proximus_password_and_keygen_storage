#if os(macOS)
import AppKit
import SwiftUI
import Darwin
import ProximusKit

/// Chrome starts this app executable directly. Each connection has a separate,
/// short-lived vault session and carries one request over inherited pipes.
/// There is no listener, HTTP endpoint, on-disk credential exchange, or helper vault.
@MainActor enum BrowserNativeHost {
    static private(set) var request: BrowserRequest?
    static private(set) var deadline: Date?
    private static var finished = false
    private static var inputMonitor: DispatchSourceRead?
    private static var expiry: DispatchWorkItem?
    private static var applicationDelegate: BrowserApplicationDelegate?
    static var onCancel: (() -> Void)?

    static func run() {
        Theme.registerFonts()
        let app = NSApplication.shared
        let delegate = BrowserApplicationDelegate()
        applicationDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        watchConnection()
        app.run()
    }

    static func prepare() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.dropFirst().contains(where: { $0.hasPrefix("chrome-extension:") }) else { return }
        // The exact origin is also the sole allowed_origins entry in the installed manifest.
        guard arguments.count == 2, arguments[1] == BrowserProtocol.extensionOrigin else { Darwin.exit(1) }
        signal(SIGPIPE, SIG_IGN)
        do {
            let end = Date().addingTimeInterval(5)
            let length = try BrowserMessageFrame.length(readExactly(4, before: end))
            var body = try readExactly(length, before: end)
            defer { body.resetBytes(in: 0..<body.count) }
            request = try BrowserRequest.decode(body)
            deadline = Date().addingTimeInterval(BrowserProtocol.lifetime)
        } catch { Darwin.exit(1) }
    }

    static func watchConnection() {
        guard request != nil, inputMonitor == nil else { return }
        // EOF or any second message cancels this one-shot connection.
        let monitor = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        monitor.setEventHandler { Task { @MainActor in cancel() } }
        inputMonitor = monitor
        monitor.resume()
        let timeout = DispatchWorkItem { Task { @MainActor in cancel() } }
        expiry = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline?.timeIntervalSinceNow ?? 0), execute: timeout)
    }

    static func checkActive() throws {
        guard !finished, let deadline, deadline > Date(), NSApp.isActive,
              applicationDelegate?.window?.isVisible == true,
              applicationDelegate?.window?.isMiniaturized == false else { throw ProximusError.authentication }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) == 0 else { throw ProximusError.authentication }
        try Task.checkCancellation()
    }

    static func complete(status: String, login: BrowserLogin? = nil) {
        guard !finished, let request else { return }
        finished = true
        expiry?.cancel(); inputMonitor?.cancel(); onCancel?(); onCancel = nil
        do {
            var bytes = try BrowserMessageFrame.encode(BrowserResponse(request: request, status: status, login: login))
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            try FileHandle.standardOutput.write(contentsOf: bytes)
        } catch { }
        Darwin.exit(0)
    }

    static func cancel() { complete(status: "cancelled") }

    private static func readExactly(_ size: Int, before deadline: Date) throws -> Data {
        var output = Data()
        while output.count < size {
            let milliseconds = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard milliseconds > 0 else { throw ProximusError.authentication }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, milliseconds)
            if ready == -1 && errno == EINTR { continue }
            guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else { throw ProximusError.authentication }
            var buffer = [UInt8](repeating: 0, count: size - output.count)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count == -1 && errno == EINTR { continue }
            guard count > 0 else { throw ProximusError.authentication }
            output.append(contentsOf: buffer.prefix(count))
            _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        return output
    }
}

@MainActor private final class BrowserApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let request = BrowserNativeHost.request else { BrowserNativeHost.cancel(); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Proximus - Browser approval"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: BrowserApprovalBootstrap(request: request)
            .tint(Theme.accent).font(Theme.body()).buttonStyle(ProximusButtonStyle())
            .toggleStyle(ProximusToggleStyle()).textFieldStyle(ProximusTextFieldStyle()))
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { BrowserNativeHost.cancel() }
    func windowDidMiniaturize(_ notification: Notification) { BrowserNativeHost.cancel() }
}
#endif
