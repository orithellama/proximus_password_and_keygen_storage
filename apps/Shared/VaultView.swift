import SwiftUI
import ProximusKit

struct VaultView: View {
    @ObservedObject var session: VaultSession
    @State private var category: String? = "all"
    @State private var search = ""
    @State private var selected: UUID?
    @State private var editing: VaultItem?
    @State private var settings = false
    @State private var pairing = false
    @State private var nearby = false
    @State private var generator = false
    @State private var walletCreator = false
    @State private var approvals = false
    @State private var error: ErrorMessage?
    var initialSelection: UUID? = nil
    var initialCategory = "all"
    private var items: [VaultItem] {
        (session.contents?.items ?? []).filter { item in
            (category == "all" || category == item.kind.rawValue || (category == "favorites" && item.favorite) || category == "collection:" + item.collection)
            && (search.isEmpty || [item.title, item.username, item.website, item.collection].contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        NavigationSplitView { sidebar } content: { itemList } detail: { detailPane }
        .privacySensitive().errorAlert($error)
        .onAppear { if selected == nil { selected = initialSelection; category = initialCategory } }
        .simultaneousGesture(TapGesture().onEnded { session.touch() })
        .sheet(item: $editing) { item in ItemEditor(session: session, item: item) }
        .sheet(isPresented: $settings) { SettingsView(session: session) }
        .sheet(isPresented: $pairing) { PairingView(session: session, isHost: true) }
        .sheet(isPresented: $nearby) { NearbySyncView(session: session) }
        .sheet(isPresented: $generator) { GeneratorView() }
        .sheet(isPresented: $walletCreator) { WalletCreator(session: session) { id in selected = id; category = "wallet" } }
        .sheet(isPresented: $approvals) { DeviceApprovalsView(session: session) }
    }
    private var sidebar: some View {
            List(selection: $category) {
                Section { Brand(compact: true).padding(.vertical, 14).listRowSeparator(.hidden) }
                Section("Your vault") {
                    Label("All items", systemImage: "square.grid.2x2").tag("all")
                    Label("Favorites", systemImage: "star").tag("favorites")
                    ForEach(ItemKind.allCases) { kind in Label(kind.label + "s", systemImage: kind.symbol).tag(kind.rawValue) }
                }
                if let contents = session.contents {
                    Section("Collections") {
                        ForEach(Array(Set(contents.items.map(\.collection).filter { !$0.isEmpty })).sorted(), id: \.self) { name in Label(name, systemImage: "folder").tag("collection:" + name) }
                    }
                }
                Section("Tools") {
                    Button { generator = true } label: { Label("Password generator", systemImage: "wand.and.stars") }.buttonStyle(.plain)
                    Button { pairing = true } label: { Label("Pair a device", systemImage: "qrcode") }.buttonStyle(.plain)
                    Button { nearby = true } label: { Label("Nearby sync", systemImage: "antenna.radiowaves.left.and.right") }.buttonStyle(.plain)
                    Button { approvals = true } label: { Label("Device approvals", systemImage: "checkmark.shield") }.buttonStyle(.plain)
                    Button { settings = true } label: { Label("Settings & backup", systemImage: "gearshape") }.buttonStyle(.plain)
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Encrypted on this device", systemImage: "lock.shield").font(.caption.bold()).foregroundStyle(Theme.accent)
                        Text(session.syncStatus).font(.caption).foregroundStyle(.secondary)
                        if session.hasRecoveryBackup { Text(session.recoveryStatus).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }
                Section {
                    Link(destination: ProximusLinks.signUp) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Sign up for Proximus", systemImage: "arrow.up.right")
                                .font(Theme.body(12).weight(.medium))
                            Text("proximus.sh").font(Theme.body(11)).foregroundStyle(Theme.muted)
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            }.labelStyle(ProximusSidebarLabel()).scrollContentBackground(.hidden).background(Theme.sidebar).navigationTitle("Proximus").navigationSplitViewColumnWidth(min: 220, ideal: 240)

    }
    private var itemList: some View {
            List(selection: $selected) {
                if items.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No items yet" : "No matching items", systemImage: search.isEmpty ? "key.horizontal" : "magnifyingglass", description: Text(search.isEmpty ? "Add a password or secure note. Create passkeys through your browser’s sign-up or security settings." : "Search by title, username, or website."))
                }
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.kind.symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 40, height: 40).background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(Theme.body(13).weight(.medium)).lineLimit(1)
                            Text(item.wallet.map { session.walletBalances[$0.id]?.chain.display ?? $0.network.coinLabel } ?? (item.username.isEmpty ? item.kind.label : item.username)).font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
                            if let wallet = item.wallet, let balance = session.walletBalances[wallet.id] {
                                Text(balance.chain.amount(balance.available)).font(Theme.body(12).weight(.medium)).foregroundStyle(Theme.accent)
                            }
                        }
                        Spacer()
                        if item.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 6).tag(item.id)
                }
            }.scrollContentBackground(.hidden).background(Theme.background).searchable(text: $search, prompt: "Search your vault")
                .navigationTitle(category == "all" ? "All items" : category == "favorites" ? "Favorites" : (category ?? "all").replacingOccurrences(of: "collection:", with: "").capitalized)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if session.relay != nil { Button { Task { do { try await session.synchronize() } catch { self.error = ErrorMessage(error) } } } label: { Image(systemName: "arrow.triangle.2.circlepath") }.help("Sync encrypted vault") }
                        Menu { Button("Password") { editing = VaultItem() }; Button("Secure note") { editing = VaultItem(kind: .note) }; Button("Crypto wallet") { walletCreator = true } } label: { Image(systemName: "plus") }
                        Button { session.lock() } label: { Image(systemName: "lock") }.help("Lock vault")
                    }
                }.navigationSplitViewColumnWidth(min: 280, ideal: 340)

    }
    @ViewBuilder private var detailPane: some View {
            if let item = session.contents?.items.first(where: { $0.id == selected }) {
                ItemDetail(session: session, item: item, edit: { editing = item })
            } else {
                VStack(spacing: 20) {
                    ProximusMark(size: 64).foregroundStyle(Theme.accent)
                    Text("Your private vault").font(Theme.heading(24))
                    Text("Select an item to see its details.").font(Theme.body()).foregroundStyle(Theme.muted)
                    Text("Your vault works without an internet connection.").font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            }

    }

}

struct ItemDetail: View {
    @ObservedObject var session: VaultSession
    let item: VaultItem
    var edit: () -> Void
    @State private var reveal = false
    @State private var copyNotice = false
    @State private var deleteNotice = false
    @State private var error: ErrorMessage?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    Image(systemName: item.kind.symbol).font(.system(size: 30)).foregroundStyle(Theme.accent).padding(20).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                    Spacer()
                    Button { edit() } label: { Label("Edit", systemImage: "pencil") }
                }
                VStack(alignment: .leading, spacing: 8) { Text(item.title).font(Theme.heading(26)); Text(item.kind.label).font(Theme.body(13)).foregroundStyle(Theme.muted) }
                if !item.username.isEmpty { field("Username", value: item.username) }
                if !item.website.isEmpty { field("Website", value: (try? DomainPolicy.origin(item.website)) ?? item.website) }
                if item.kind == .password {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Password").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(reveal ? item.password : "••••••••••••••••").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.help(reveal ? "Hide password" : "Reveal password")
                            Button { copyNotice = true } label: { Image(systemName: "doc.on.doc") }.help("Copy password")
                        }
                    }.padding().background(Theme.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                    Text("Use AutoFill for a checked website match. Copied passwords can be read by other software.").font(.caption).foregroundStyle(.secondary)
                }
                if let wallet = item.wallet { WalletDetails(session: session, metadata: wallet).id(wallet.id) }
                if let passkey = item.passkey {
                    Label(passkey.deviceID == session.deviceID ? "Private key stays in this device’s Secure Enclave" : "Private key is held on another device", systemImage: "cpu").foregroundStyle(Theme.accent)
                    Text("Use a supported browser’s passkey flow to sign in. Pairing and backups copy this record, but cannot copy its private key. Register a separate passkey on each device or use the website’s cross-device sign-in option.").font(.callout).foregroundStyle(.secondary)
                }
                if !item.notes.isEmpty { field("Private notes", value: item.notes) }
                if !item.collection.isEmpty { field("Collection", value: item.collection) }
                Divider()
                Text("Updated " + item.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Button("Delete item", role: .destructive) { deleteNotice = true }
            }.padding(28).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Theme.background).navigationTitle(item.title).errorAlert($error)
            .onChange(of: item.id) { _, _ in reveal = false }
            .alert("Copy password?", isPresented: $copyNotice) { Button("Cancel", role: .cancel) {}; Button("Copy for 30 seconds") { Platform.copySecret(item.password) } } message: { Text(DomainPolicy.passwordNotice(destination: nil)) }
            .confirmationDialog("Delete this item?", isPresented: $deleteNotice, titleVisibility: .visible) { Button("Delete", role: .destructive) { Task { do { try await session.delete(item) } catch { self.error = ErrorMessage(error) } } } } message: { Text(item.kind == .wallet ? "This deletes the address record and its private keys on this device. Make sure you have backed up the wallet recovery details. Standard vault exports cannot recover wallet keys. Older encrypted recovery kits may still contain them. Address records on other devices do not contain the keys." : item.kind == .passkey ? "This removes the local private key when it belongs to this device. Remove the corresponding passkey on the website too. Older encrypted snapshots can still contain record metadata." : "The item is removed from the current vault. Older encrypted snapshots and exported backups may retain it.") }
    }
    private func field(_ label: String, value: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
}

struct ItemEditor: View {
    @ObservedObject var session: VaultSession
    @State var item: VaultItem
    @Environment(\.dismiss) private var dismiss
    @State private var error: ErrorMessage?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Item") { TextField("Title", text: $item.title); if item.kind != .wallet { TextField("Username", text: $item.username) }; if item.kind != .passkey && item.kind != .wallet { TextField("HTTPS website", text: $item.website) } }
                if item.kind == .password {
                    Section("Password") {
                        SecureField("Password", text: $item.password)
                        Button("Generate a random 24-character password") { do { item.password = try VaultCrypto.password() } catch { self.error = ErrorMessage(error) } }
                        Text("One unique password per account. Longer random passwords resist guessing better than predictable substitutions.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Private notes") { TextEditor(text: $item.notes).frame(minHeight: 100) }
                Section { Toggle("Favorite", isOn: $item.favorite); TextField("Collection", text: $item.collection) }
            }.formStyle(.grouped).navigationTitle(item.kind.label)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { busy = true; Task { do { try await session.save(item); dismiss() } catch { self.error = ErrorMessage(error) }; busy = false } }.disabled(busy || item.title.isEmpty) }
                }
        }.frame(idealWidth: 560, idealHeight: 620).errorAlert($error).privacySensitive()
    }
}

struct GeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var length = 24.0
    @State private var symbols = true
    @State private var password = ""
    @State private var error: ErrorMessage?
    @State private var copyNotice = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(password).font(.system(.title3, design: .monospaced)).textSelection(.enabled).padding(.vertical)
                    Button("Generate another") { generate() }
                    Button("Copy password") { copyNotice = true }
                }
                Section("Random password") {
                    Slider(value: $length, in: 12...128, step: 1) { Text("Length") }
                    Text("\(Int(length)) characters")
                    Toggle("Include symbols", isOn: $symbols)
                    Text("Generated with the operating system’s cryptographic random source. Every allowed character has an equal chance of selection. Use a different password on every website.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Saved settings") {
                    Button("Save these generator settings") { UserDefaults.standard.set(length, forKey: "generator-length"); UserDefaults.standard.set(symbols, forKey: "generator-symbols") }
                    Button("Load saved settings") { let value = UserDefaults.standard.double(forKey: "generator-length"); if (12...128).contains(value) { length = value; symbols = UserDefaults.standard.bool(forKey: "generator-symbols") } }
                }
            }.formStyle(.grouped).navigationTitle("Password generator").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(idealWidth: 500, idealHeight: 550).onAppear { generate() }.onChange(of: length) { _, _ in generate() }.onChange(of: symbols) { _, _ in generate() }.errorAlert($error)
            .alert("Copy password?", isPresented: $copyNotice) { Button("Cancel", role: .cancel) {}; Button("Copy for 30 seconds") { Platform.copySecret(password) } } message: { Text(DomainPolicy.passwordNotice(destination: nil)) }
    }
    private func generate() { do { password = try VaultCrypto.password(length: Int(length), symbols: symbols) } catch { self.error = ErrorMessage(error) } }
}
