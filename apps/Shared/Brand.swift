import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ProximusLinks {
    static let signUp = URL(string: "https://www.proximus.sh/sign-up")!
    static let source = URL(string: "https://github.com/orithellama/proximus_password_and_keygen_storage")!
    static let installation = URL(string: "https://github.com/orithellama/proximus_password_and_keygen_storage#install-proximus")!
}

enum Theme {
    static let cornerRadius: CGFloat = 12
    static let mint = Color(red: 151/255, green: 252/255, blue: 228/255)
    static let ink = Color(red: 7/255, green: 39/255, blue: 35/255)
    static let accent = adaptive(light: 0x072723, dark: 0xA3EBD9)
    static let background = adaptive(light: 0xF6F8F9, dark: 0x141A19)
    static let panel = adaptive(light: 0xECF0F3, dark: 0x161D1C)
    static let sidebar = adaptive(light: 0xECF0F3, dark: 0x111716)
    static let border = adaptive(light: 0xD9DFE3, dark: 0x2C3534)
    static let foreground = adaptive(light: 0x1F2328, dark: 0xE6E6E6)
    static let muted = adaptive(light: 0x626971, dark: 0xABB5B1)
    static func body(_ size: CGFloat = 15) -> Font { .custom("SpaceGroteskLight-Regular", size: size, relativeTo: .body) }
    static func heading(_ size: CGFloat = 24) -> Font { .custom("Sora-Regular", size: size, relativeTo: .title).weight(.medium) }
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1)
        })
        #endif
    }
    static func registerFonts() {
        for name in ["SpaceGrotesk", "Sora"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
}

struct ProximusMark: View {
    var size: CGFloat = 28
    private var image: Image? {
        guard let url = Bundle.main.url(forResource: "ProximusWings", withExtension: "png") else { return nil }
        #if os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }; return Image(nsImage: image)
        #else
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }; return Image(uiImage: image)
        #endif
    }
    var body: some View { Group { if let image { image.renderingMode(.template).resizable().scaledToFit() } }.frame(width: size, height: size * 490/530).accessibilityHidden(true) }
}

struct Brand: View {
    var compact = false
    var body: some View {
        HStack(spacing: 9) {
            ProximusMark(size: compact ? 24 : 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("PROXIMUS").font(Theme.heading(compact ? 17 : 21)).tracking(-0.7)
                if !compact { Text("Your private vault").font(Theme.body(13)).foregroundStyle(Theme.muted) }
            }
        }.foregroundStyle(Theme.foreground)
    }
}

/// One control family for every app action; emphasis changes color, never geometry.
struct ProximusButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary }
    var emphasis: Emphasis = .secondary
    init(_ emphasis: Emphasis = .secondary) { self.emphasis = emphasis }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ProximusControl(emphasis: emphasis, pressed: configuration.isPressed, destructive: configuration.role == .destructive))
    }
}

struct ProximusControl: ViewModifier {
    var emphasis: ProximusButtonStyle.Emphasis = .secondary
    var pressed = false
    var destructive = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content.font(Theme.body(14).weight(.semibold)).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 11).frame(minHeight: 44)
            .foregroundStyle(destructive ? Color.red : emphasis == .primary ? (scheme == .dark ? Theme.ink : Theme.mint) : Theme.accent)
            .background(emphasis == .primary ? Theme.accent : Theme.accent.opacity(pressed ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(destructive ? Color.red.opacity(0.5) : emphasis == .primary ? Theme.accent : Theme.accent.opacity(0.3)))
            .opacity(enabled ? (pressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

struct ProximusTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).padding(12).frame(minHeight: 44)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border))
    }
}

struct ProximusToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.multilineTextAlignment(.leading).foregroundStyle(Theme.foreground)
                Spacer(minLength: 8)
                Image(systemName: configuration.isOn ? "checkmark" : "minus")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(configuration.isOn ? Theme.ink : Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(configuration.isOn ? Theme.mint : Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border))
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct ProximusSidebarLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Theme.accent).frame(width: 18)
            configuration.title
        }
    }
}
