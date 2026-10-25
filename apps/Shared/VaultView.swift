import SwiftUI
import ProximusKit

struct VaultView: View {
    @ObservedObject var session: VaultSession
    @State private var category: String? = "all"
    @State private var search = ""
    @State private var selected: UUID?
    @State private var editing: VaultItem?
    @State private var settings = false
    @State private var devices = false
    @State private var generator = false
    @State private var walletCreator = false
    @State private var initialized = false
    @State private var syncing = false
    @State private var error: ErrorMessage?
    var initialSelection: UUID? = nil
    var initialCategory = "all"
    private var allItems: [VaultItem] { session.contents?.items ?? [] }
    private func matches(_ item: VaultItem, category: String?) -> Bool {
        category == "all" || category == item.kind.rawValue || (category == "favorites" && item.favorite) || category == "collection:" + item.collection
    }
    private var items: [VaultItem] {
        allItems.filter { matches($0, category: category) && (search.isEmpty || [$0.title, $0.username, $0.website, $0.collection, $0.wallet?.address ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var title: String {
        if category == "all" { return "All items" }
        if category == "favorites" { return "Favorites" }
        if let kind = ItemKind(rawValue: category ?? "") { return kind.label + "s" }
        return (category ?? "All items").replacingOccurrences(of: "collection:", with: "")
    }
    var body: some View {
        NavigationSplitView { sidebar } content: { itemList } detail: { detailPane }
            .privacySensitive().errorAlert($error)
            .onAppear { if !initialized { category = initialCategory; selected = initialSelection; initialized = true } }
            .onChange(of: category) { _, _ in if let selected, !items.contains(where: { $0.id == selected }) { self.selected = nil }; search = "" }
            .onChange(of: items.map(\.id)) { _, ids in if let selected, !ids.contains(selected) { self.selected = nil } }
            .simultaneousGesture(TapGesture().onEnded { session.touch() })
            .sheet(item: $editing) { item in ItemEditor(session: session, item: item) }
            .sheet(isPresented: $settings) { SettingsView(session: session) }
            .sheet(isPresented: $devices) { DevicesView(session: session) }
            .sheet(isPresented: $generator) { GeneratorView() }
            .sheet(isPresented: $walletCreator) { WalletCreator(session: session) { id in category = "wallet"; selected = id } }
    }
    private var sidebar: some View {
        List(selection: $category) {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Brand(compact: true)
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                        Text(session.contents?.name ?? "Personal").lineLimit(1)
                    }.font(Theme.body(12)).foregroundStyle(Theme.muted)
                }.padding(.vertical, 14).listRowSeparator(.hidden)
            }
            Section("Your vault") {
                categoryRow("All items", symbol: "square.grid.2x2", value: "all")
                categoryRow("Favorites", symbol: "star", value: "favorites")
                ForEach(ItemKind.allCases) { kind in categoryRow(kind.label + "s", symbol: kind.symbol, value: kind.rawValue) }
            }
            let collections = Array(Set(allItems.map(\.collection).filter { !$0.isEmpty })).sorted()
            if !collections.isEmpty {
                Section("Folders") { ForEach(collections, id: \.self) { name in categoryRow(name, symbol: "folder", value: "collection:" + name) } }
            }
            Section("Manage") {
                Button { generator = true } label: { Label("Password generator", systemImage: "wand.and.stars").padding(.vertical, 5) }.buttonStyle(.plain)
                Button { devices = true } label: { Label("My devices", systemImage: "laptopcomputer.and.iphone").padding(.vertical, 5) }.buttonStyle(.plain)
                Button { settings = true } label: { Label("Settings", systemImage: "gearshape").padding(.vertical, 5) }.buttonStyle(.plain)
            }
            Section {
                Button { session.lock() } label: { Label("Lock vault", systemImage: "lock").padding(.vertical, 5) }.buttonStyle(.plain).keyboardShortcut("l", modifiers: [.command, .shift])
                VStack(alignment: .leading, spacing: 7) {
                    Label("Saved on this device", systemImage: "checkmark.shield").foregroundStyle(Theme.accent)
                    Text(session.syncStatus).foregroundStyle(Theme.muted)
                }.font(Theme.body(12)).padding(.vertical, 8)
            }
            Section {
                Link(destination: ProximusLinks.signUp) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Explore Proximus", systemImage: "arrow.up.right").font(Theme.body(13).weight(.medium))
                        Text("Sign up at proximus.sh").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }.labelStyle(ProximusSidebarLabel()).listStyle(.sidebar).scrollContentBackground(.hidden)
            .background(Theme.sidebar).navigationTitle("Proximus").navigationSplitViewColumnWidth(min: 220, ideal: 245)
    }
    private func categoryRow(_ title: String, symbol: String, value: String) -> some View {
        NavigationLink(value: value) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer(minLength: 4)
                Text("\(allItems.filter { matches($0, category: value) }.count)").font(Theme.body(12)).monospacedDigit().foregroundStyle(Theme.muted)
            }.padding(.vertical, 5)
        }
    }
    private var itemList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search your vault", text: $search).textFieldStyle(.plain).autocorrectionDisabled().accessibilityLabel("Search your vault")
            }.padding(12).frame(minHeight: 44).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border)).padding(.horizontal, 16).padding(.top, 16)
            HStack {
                Text("\(items.count) \(items.count == 1 ? "item" : "items")").font(Theme.body(12)).foregroundStyle(Theme.muted)
                Spacer()
                Menu { addActions } label: { Label("Add", systemImage: "plus") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().modifier(ProximusControl()).accessibilityLabel("Add to your vault")
            }.padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Theme.border)
            if items.isEmpty { emptyList }
            else {
                List(selection: $selected) {
                    ForEach(items) { item in
                        NavigationLink(value: item.id) {
                            HStack(spacing: 12) {
                                Image(systemName: item.kind.symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 38, height: 42)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(Theme.body(15).weight(.semibold)).lineLimit(1)
                                    Text(item.wallet.map { session.walletBalances[$0.id]?.chain.display ?? $0.network.coinLabel } ?? (item.username.isEmpty ? item.kind.label : item.username)).font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1)
                                    if let wallet = item.wallet, let balance = session.walletBalances[wallet.id] {
                                        Text(balance.chain.amount(balance.available)).font(Theme.body(13).weight(.medium)).foregroundStyle(Theme.accent)
                                    }
                                }
                                Spacer(minLength: 0)
                                if item.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.accent).accessibilityLabel("Favorite") }
                            }.padding(.vertical, 9)
                        }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }.background(Theme.background)
            .navigationTitle(title)
            .toolbar {
                if session.relay != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { syncing = true; Task { do { try await session.synchronize() } catch { self.error = ErrorMessage(error) }; syncing = false } } label: { Label(syncing ? "Syncing…" : "Sync", systemImage: "arrow.triangle.2.circlepath") }.disabled(syncing)
                    }
                }
            }.navigationSplitViewColumnWidth(min: 260, ideal: 310)
    }
    @ViewBuilder private var addActions: some View {
        Button { editing = VaultItem() } label: { Label("Password", systemImage: "key.horizontal") }
        Button { editing = VaultItem(kind: .note) } label: { Label("Secure note", systemImage: "note.text") }
        Button { walletCreator = true } label: { Label("Crypto wallet", systemImage: "wallet.bifold") }
    }
    private var emptyList: some View {
        VStack(spacing: 16) {
            Image(systemName: search.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 30)).foregroundStyle(Theme.accent)
            Text(search.isEmpty ? "A place for your \(category == "wallet" ? "wallets" : category == "password" ? "passwords" : "items")." : "Nothing found").font(Theme.heading(19)).multilineTextAlignment(.center)
            Text(emptyDescription).font(Theme.body(13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            if !search.isEmpty { Button("Clear search") { search = "" }.buttonStyle(ProximusButtonStyle()) }
            else if category == "wallet" { Button("Create a wallet") { walletCreator = true }.buttonStyle(ProximusButtonStyle(.primary)) }
            else if category == "note" { Button("Add a note") { editing = VaultItem(kind: .note) }.buttonStyle(ProximusButtonStyle(.primary)) }
            else if category != "favorites" && category != "passkey" { Button("Add a password") { editing = VaultItem() }.buttonStyle(ProximusButtonStyle(.primary)) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var emptyDescription: String {
        if !search.isEmpty { return "Try a name, email address, or website." }
        switch category {
        case "favorites": return "Use the star on an item to keep it close at hand."
        case "passkey": return "Create a passkey in a website’s account settings and choose Proximus to save it."
        case "wallet": return "Create a wallet or restore one you already use."
        case "note": return "Keep recovery instructions and other private information here."
        default: return "Start with an account you use every day."
        }
    }
    @ViewBuilder private var detailPane: some View {
        if let item = allItems.first(where: { $0.id == selected }) {
            ItemDetail(session: session, item: item, edit: { editing = item })
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack { ProximusMark(size: 42).foregroundStyle(Theme.accent); Spacer(); Label("On this device", systemImage: "lock.shield").font(Theme.body(12)).foregroundStyle(Theme.muted) }
                    SectionHeading(title: "Everything in its place.", subtitle: "Choose an item on the left, or start with something new.")
                    VStack(spacing: 12) {
                        ActionRow(title: "Add a password", subtitle: "Save a login for a website or app.", symbol: "key.horizontal") { editing = VaultItem() }
                        ActionRow(title: "Create a wallet", subtitle: "Keep your crypto addresses and keys together.", symbol: "wallet.bifold") { walletCreator = true }
                        ActionRow(title: "Connect another device", subtitle: "Bring your passwords to your phone or tablet.", symbol: "laptopcomputer.and.iphone") { devices = true }
                    }
                    AppCard {
                        Label("Your vault goes where you go", systemImage: "wifi.slash").font(Theme.body().weight(.semibold))
                        Text("Passwords and notes work offline. Open My devices when you want to share changes with a nearby device.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    }
                }.padding(28).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }.background(Theme.background).navigationTitle("Your vault")
        }
    }
}

struct ItemDetail: View {
    @ObservedObject var session: VaultSession
    let item: VaultItem
    var edit: () -> Void
    @State private var reveal = false
    @State private var copyNotice = false
    @State private var copied = false
    @State private var deleteNotice = false
    @State private var saving = false
    @State private var error: ErrorMessage?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.kind.symbol).font(.system(size: 25)).foregroundStyle(Theme.accent).frame(width: 58, height: 58).background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    VStack(alignment: .leading, spacing: 7) { Text(item.title).font(Theme.heading(25)); Text(item.kind.label).font(Theme.body(13)).foregroundStyle(Theme.muted) }
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { itemActions }
                    VStack(alignment: .leading) { itemActions }
                }.controlSize(.large)
                if item.kind == .password {
                    AppCard {
                        if !item.username.isEmpty { copyField("Username or email", value: item.username); Divider() }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Password").font(Theme.body(13)).foregroundStyle(Theme.muted)
                            Text(reveal ? item.password : "••••••••••••••••").font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { passwordActions }
                                VStack(alignment: .leading, spacing: 12) { passwordActions }
                            }
                        }
                        if !item.website.isEmpty { Divider(); websiteField }
                    }
                    Text("Use AutoFill to match the website before signing in. No password manager can guarantee a website is safe.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                } else if item.kind != .wallet {
                    if !item.username.isEmpty || !item.website.isEmpty {
                        AppCard { if !item.username.isEmpty { copyField("Username or email", value: item.username) }; if !item.website.isEmpty { websiteField } }
                    }
                }
                if let wallet = item.wallet { WalletDetails(session: session, metadata: wallet).id(wallet.id) }
                if let passkey = item.passkey {
                    AppCard {
                        Label(passkey.deviceID == session.deviceID ? "Ready on this device" : "Saved on another device", systemImage: "person.badge.key").foregroundStyle(Theme.accent)
                        Text("Choose “Sign in with a passkey” on the website. Approve the request with your device.")
                        DisclosureGroup("Using this passkey on other devices") { Text("Its private key stays on the device where it was created. Add a separate passkey on each device, or use the website’s cross-device sign-in option.").font(.callout).foregroundStyle(Theme.muted).padding(.top, 8) }
                    }
                }
                if !item.notes.isEmpty { AppCard { Text("Private notes").font(Theme.body(13)).foregroundStyle(Theme.muted); Text(item.notes).textSelection(.enabled) } }
                HStack { Text("Updated " + item.modifiedAt.formatted(date: .abbreviated, time: .omitted)); Spacer(); if !item.collection.isEmpty { Label(item.collection, systemImage: "folder") } }.font(Theme.body(12)).foregroundStyle(Theme.muted)
            }.padding(24).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Theme.background).navigationTitle(item.title).errorAlert($error)
            .onChange(of: item.id) { _, _ in reveal = false; copied = false }
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { copied = false } } }
            .alert("Copy password?", isPresented: $copyNotice) { Button("Cancel", role: .cancel) {}; Button("Copy for 30 seconds") { Platform.copySecret(item.password); copied = true } } message: { Text(DomainPolicy.passwordNotice(destination: nil)) }
            .confirmationDialog("Delete this item?", isPresented: $deleteNotice, titleVisibility: .visible) { Button("Delete", role: .destructive) { Task { do { try await session.delete(item) } catch { self.error = ErrorMessage(error) } } } } message: { Text(item.kind == .wallet ? "This deletes the address record and its private keys on this device. Save the wallet recovery details first. Standard vault backups cannot recover wallet keys. Older encrypted recovery kits may still contain them." : item.kind == .passkey ? "This removes the private key if it belongs to this device. Remove the corresponding passkey on the website too." : "This item will be removed from your vault. Older backups may still contain it.") }
    }
    @ViewBuilder private var itemActions: some View {
        Button(action: edit) { Label("Edit", systemImage: "pencil") }.buttonStyle(ProximusButtonStyle())
        Button {
            saving = true
            Task { do { var updated = item; updated.favorite.toggle(); try await session.save(updated) } catch { self.error = ErrorMessage(error) }; saving = false }
        } label: { Label(item.favorite ? "Favorited" : "Favorite", systemImage: item.favorite ? "star.fill" : "star") }.buttonStyle(ProximusButtonStyle()).disabled(saving)
        Menu { Button("Delete item", role: .destructive) { deleteNotice = true } } label: { Label("More", systemImage: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().modifier(ProximusControl())
    }
    @ViewBuilder private var passwordActions: some View {
        Button { copyNotice = true } label: { Label(copied ? "Copied" : "Copy password", systemImage: copied ? "checkmark" : "doc.on.doc") }.buttonStyle(ProximusButtonStyle(.primary))
        Button { reveal.toggle() } label: { Label(reveal ? "Hide" : "Show", systemImage: reveal ? "eye.slash" : "eye") }.buttonStyle(ProximusButtonStyle())
    }
    private func copyField(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.body(13)).foregroundStyle(Theme.muted)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            CopyValueButton(value: value, title: "Copy username").buttonStyle(ProximusButtonStyle())
        }
    }
    private var websiteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Website").font(Theme.body(13)).foregroundStyle(Theme.muted)
            Text((try? DomainPolicy.origin(item.website)) ?? item.website).textSelection(.enabled)
            if let origin = try? DomainPolicy.origin(item.website), let url = URL(string: origin) { Link(destination: url) { Label("Open website", systemImage: "arrow.up.right.square") }.buttonStyle(ProximusButtonStyle()) }
        }
    }
}

struct ItemEditor: View {
    @ObservedObject var session: VaultSession
    @State var item: VaultItem
    @Environment(\.dismiss) private var dismiss
    @State private var error: ErrorMessage?
    @State private var busy = false
    @State private var generated = false
    private var isNew: Bool { session.contents?.items.contains(where: { $0.id == item.id }) != true }
    var body: some View {
        NavigationStack {
            ProximusForm {
                ProximusSection("\(item.kind.label) details") {
                    TextField(item.kind == .password ? "Name, e.g. Apple or Gmail" : "Name", text: $item.title)
                    if item.kind == .password || item.kind == .passkey { TextField("Username or email", text: $item.username).autocorrectionDisabled() }
                    if item.kind == .password { TextField("Website, e.g. https://example.com", text: $item.website).autocorrectionDisabled() }
                if item.kind == .password { Text("Use the name you’ll recognize when you search for this account.").font(.caption).foregroundStyle(Theme.muted) }
                }
                if item.kind == .password {
                    ProximusSection("Password") {
                        SecureField("Enter or generate a password", text: $item.password)
                        Button { do { item.password = try VaultCrypto.password(); generated = true } catch { self.error = ErrorMessage(error) } } label: { Label(generated ? "Generate another password" : "Generate a strong password", systemImage: "wand.and.stars") }
                        Text(generated ? "A random 24-character password is ready to save. If this is an existing account, also change its password on the website." : "Saving a password here does not change it on the website.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                ProximusSection(item.kind == .note ? "Your note" : "Notes (optional)") { TextEditor(text: $item.notes).scrollContentBackground(.hidden).padding(12).frame(minHeight: 120).background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerRadius)).overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border)) }
                ProximusSection("Organize") { Toggle("Add to favorites", isOn: $item.favorite); TextField("Folder (optional)", text: $item.collection) }
                if busy { ProgressView("Saving…") }
            }.appForm().navigationTitle((isNew ? "Add " : "Edit ") + item.kind.label.lowercased())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { busy = true; Task { do { try await session.save(item); dismiss() } catch { self.error = ErrorMessage(error) }; busy = false } }.disabled(busy || item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }.frame(idealWidth: 560, idealHeight: 650).errorAlert($error).privacySensitive().interactiveDismissDisabled(busy)
    }
}

struct GeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var length = 24.0
    @State private var symbols = true
    @State private var password = ""
    @State private var error: ErrorMessage?
    @State private var copyNotice = false
    @State private var copied = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SectionHeading(title: "One account. One password.", subtitle: "Create a unique password, then save it with your login.")
                    AppCard {
                        Text(password).font(.system(.title3, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        ViewThatFits(in: .horizontal) { HStack { generatorActions }; VStack(alignment: .leading) { generatorActions } }
                    }
                    AppCard {
                        HStack { Text("Length"); Spacer(); Text("\(Int(length)) characters").foregroundStyle(Theme.accent).monospacedDigit() }
                        Slider(value: Binding(get: { length }, set: { length = $0.rounded() }), in: 12...128) { Text("Password length") }.labelsHidden()
                        Toggle("Include symbols, like ! and #", isOn: $symbols)
                        Text("These preferences are remembered on this device.").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Text("Random, unique passwords are harder to guess. When changing an existing password, update it on the website and save it in your vault.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                }.padding(24)
            }.background(Theme.background).navigationTitle("Password generator").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(idealWidth: 540, idealHeight: 570).privacySensitive()
            .onAppear { let saved = UserDefaults.standard.double(forKey: "generator-length"); if (12...128).contains(saved) { length = saved; symbols = UserDefaults.standard.bool(forKey: "generator-symbols") }; generate() }
            .onChange(of: length) { _, _ in rememberAndGenerate() }.onChange(of: symbols) { _, _ in rememberAndGenerate() }.errorAlert($error)
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { copied = false } } }
            .alert("Copy password?", isPresented: $copyNotice) { Button("Cancel", role: .cancel) {}; Button("Copy for 30 seconds") { Platform.copySecret(password); copied = true } } message: { Text(DomainPolicy.passwordNotice(destination: nil)) }
    }
    @ViewBuilder private var generatorActions: some View {
        Button { copyNotice = true } label: { Label(copied ? "Copied" : "Copy password", systemImage: copied ? "checkmark" : "doc.on.doc") }.buttonStyle(ProximusButtonStyle(.primary))
        Button { generate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }.buttonStyle(ProximusButtonStyle())
    }
    private func rememberAndGenerate() { UserDefaults.standard.set(length, forKey: "generator-length"); UserDefaults.standard.set(symbols, forKey: "generator-symbols"); generate() }
    private func generate() { do { password = try VaultCrypto.password(length: Int(length), symbols: symbols); copied = false } catch { self.error = ErrorMessage(error) } }
}
