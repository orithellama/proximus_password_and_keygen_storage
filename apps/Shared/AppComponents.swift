import SwiftUI
import LocalAuthentication

enum AppPresentation {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static var unlockName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "device authentication"
        }
    }
    static var unlockSymbol: String {
        #if os(macOS)
        return "touchid"
        #else
        return unlockName == "Face ID" ? "faceid" : "touchid"
        #endif
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border))
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.heading(24)).foregroundStyle(Theme.foreground)
            if !subtitle.isEmpty { Text(subtitle).font(Theme.body()).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct ActionRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(Theme.body().weight(.semibold)).foregroundStyle(Theme.foreground)
                    Text(subtitle).font(Theme.body(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border))
        }.buttonStyle(.plain)
    }
}

struct StepIndicator: View {
    let labels: [String]
    let current: Int
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(index <= current ? Theme.accent : Theme.border).frame(height: 3)
                    Text("\(index + 1). " + label).font(Theme.body(12).weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? Theme.foreground : Theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Step \(current + 1) of \(labels.count): \(labels[current])")
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.body(13).weight(.semibold)).foregroundStyle(Theme.foreground)
            content.textFieldStyle(.plain).padding(12).frame(minHeight: 44)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border))
        }
    }
}

/// Public values only. Secret copying keeps its separate confirmation flow.
struct CopyValueButton: View {
    let value: String
    var title = "Copy"
    @State private var copied = false
    var body: some View {
        Button {
            Platform.copyPublic(value); copied = true
        } label: { Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc") }
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { copied = false } } }
            .onChange(of: value) { _, _ in copied = false }
    }
}

struct ProximusForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(Theme.background).buttonStyle(ProximusButtonStyle())
            .textFieldStyle(ProximusTextFieldStyle()).toggleStyle(ProximusToggleStyle())
    }
}

struct ProximusSection<Content: View>: View {
    let title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(Theme.body(14).weight(.semibold)).foregroundStyle(Theme.muted) }
            AppCard { content }
        }
    }
}

struct ProximusPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.body(13).weight(.semibold))
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    Button { selection = options[index].0 } label: {
                        if selection == options[index].0 { Label(options[index].1, systemImage: "checkmark") }
                        else { Text(options[index].1) }
                    }
                }
            } label: {
                HStack { Text(options.first { $0.0 == selection }?.1 ?? title); Spacer(); Image(systemName: "chevron.down").font(.caption) }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).modifier(ProximusControl()).accessibilityLabel(title)
        }
    }
}

extension View {
    func appForm() -> some View {
        background(Theme.background).buttonStyle(ProximusButtonStyle())
    }
}
