import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ProximusLinks {
    static let signUp = URL(string: "https://www.proximus.sh/sign-up")!
}

enum Theme {
    static let mint = Color(red: 151/255, green: 252/255, blue: 228/255)
    static let ink = Color(red: 7/255, green: 39/255, blue: 35/255)
    static let accent = adaptive(light: 0x072723, dark: 0xA3EBD9)
    static let background = adaptive(light: 0xF6F8F9, dark: 0x141A19)
    static let panel = adaptive(light: 0xECF0F3, dark: 0x161D1C)
    static let sidebar = adaptive(light: 0xECF0F3, dark: 0x111716)
    static let border = adaptive(light: 0xD9DFE3, dark: 0x2C3534)
    static let foreground = adaptive(light: 0x1F2328, dark: 0xE6E6E6)
    static let muted = adaptive(light: 0x6D7078, dark: 0x969696)
    static func body(_ size: CGFloat = 14) -> Font { .custom("SpaceGroteskLight-Regular", size: size, relativeTo: .body) }
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
                if !compact { Text("Passwords").font(Theme.body(13)).foregroundStyle(Theme.muted) }
            }
        }.foregroundStyle(Theme.foreground)
    }
}

struct ProximusPrimaryButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.body(13).weight(.medium)).padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(scheme == .dark ? Theme.ink : Theme.mint)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.86 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.12), radius: 4, x: 2, y: 3)
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
