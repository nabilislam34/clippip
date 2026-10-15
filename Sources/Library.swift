import SwiftUI
import UniformTypeIdentifiers

// Browser for clips that live on the PC: the ClipPiP clip database ("history") and the CopyQ tabs.
// Nothing here is stored on the phone; text and images are loaded from the PC server on demand.

struct LibTab: Decodable, Identifiable {
    let id: String
    let label: String
    /// id of the tab this one is nested under (a CopyQ subtab, or a Ditto subgroup). nil = top level.
    let parent: String?
}

struct LibTag: Decodable, Identifiable {
    let tag: String
    let count: Int
    var id: String { tag }
}

struct LibItem: Decodable, Identifiable {
    let key: String
    let kind: String
    let text: String
    let name: String?
    let note: String?
    let tags: [String]?
    let url: String?
    let sig: String?
    let src: String?        // PC app a clip came from (pc clips only)
    let img: String?
    let thumb: String?
    var id: String { key }
}

private struct TabsReply: Decodable { let tabs: [LibTab] }
private struct TagsReply: Decodable { let tags: [LibTag] }
private struct ItemsReply: Decodable { let total: Int; let items: [LibItem] }

/// A clip opened full screen (long press > Open full clip).
struct OpenClip: Identifiable {
    let id: String
    let text: String
    let note: String
    let link: String
    let image: URL?
    let copy: () -> Void
}

/// A delete waiting for the user's yes. `force` = the clip is pinned in CopyQ and the user is asked again.
struct DeleteAsk: Identifiable {
    let id = UUID()
    let item: LibItem
    let force: Bool
}

final class LibraryModel: ObservableObject {
    @Published var tabs: [LibTab] = []
    /// ids of the group tabs whose children are shown in the sidebar.
    @Published var expanded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "libOpenTabs") ?? [])
    @Published var tags: [LibTag] = []
    @Published var selected = UserDefaults.standard.string(forKey: "libTab") ?? "history"
    @Published var tag = ""
    @Published var items: [LibItem] = []
    @Published var total = 0
    @Published var status = ""
    @Published var loading = false
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }

    private weak var monitor: ClipMonitor?
    private var generation = 0
    private var pending: DispatchWorkItem?
    private let pageSize = 60

    func attach(_ m: ClipMonitor) {
        monitor = m
        if tabs.isEmpty { loadTabs() }
        if items.isEmpty { reload() }
        if tags.isEmpty { loadTags() }
    }

    func loadTabs() {
        monitor?.fetch("/lib/tabs") { [weak self] data, resp, err in
            guard let self = self else { return }
            if let data = data, resp?.statusCode == 200,
               let r = try? JSONDecoder().decode(TabsReply.self, from: data) {
                self.tabs = self.ordered(r.tabs)
                self.parentIds = Set(r.tabs.compactMap { $0.parent })
                self.openAncestors(of: self.selected)
            } else {
                self.status = Self.describe(resp, err)
            }
        }
    }

    func loadTags() {
        let tab = selected
        monitor?.fetch("/lib/tags?tab=\(Self.enc(tab))", timeout: 90) { [weak self] data, resp, _ in
            guard let self = self, tab == self.selected else { return }
            if let data = data, resp?.statusCode == 200,
               let r = try? JSONDecoder().decode(TagsReply.self, from: data) {
                self.tags = r.tags
            } else {
                self.tags = []
            }
        }
    }

    /// Tabs with children, so the sidebar can draw a chevron on them.
    @Published var parentIds: Set<String> = []

    /// The sidebar rows: a child is listed right under its parent and only while that parent is open.
    /// Text typed in the sidebar's filter box: only tabs whose name matches are listed (flat, groups ignored).
    @Published var tabFilter = ""

    var visibleTabs: [(tab: LibTab, depth: Int)] {
        if !tabFilter.trimmingCharacters(in: .whitespaces).isEmpty {
            return tabs.filter { TabOrder.matches($0.label, tabFilter) }.map { (tab: $0, depth: 0) }
        }
        var byParent: [String: [LibTab]] = [:]
        var roots: [LibTab] = []
        for t in tabs {
            if let p = t.parent, p != t.id, tabs.contains(where: { $0.id == p }) {
                byParent[p, default: []].append(t)
            } else {
                roots.append(t)
            }
        }
        var out: [(LibTab, Int)] = []
        func walk(_ list: [LibTab], _ depth: Int) {
            for t in list {
                out.append((t, depth))
                if expanded.contains(t.id), depth < 6, let kids = byParent[t.id] {
                    walk(kids, depth + 1)
                }
            }
        }
        walk(roots, 0)
        return out.map { (tab: $0.0, depth: $0.1) }
    }

    /// The sidebar order the user set by dragging a tab onto another one (kept on the phone).
    private var order: [String] = UserDefaults.standard.stringArray(forKey: "libTabOrder") ?? []

    private func ordered(_ list: [LibTab]) -> [LibTab] {
        let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return TabOrder.apply(list.map { $0.id }, order: order).compactMap { byId[$0] }
    }

    /// Drop tab `id` on tab `target` in the sidebar. Children stay under their own group.
    func moveTab(_ id: String, onto target: String) {
        let ids = TabOrder.move(id, onto: target, in: tabs.map { $0.id })
        guard ids != tabs.map({ $0.id }) else { return }
        order = ids
        UserDefaults.standard.set(ids, forKey: "libTabOrder")
        tabs = ordered(tabs)
    }

    /// A clip dropped on a sidebar tab: history clips move to an "ai ..." tab, anything else is copied into a CopyQ tab.
    func file(key: String, sig: String, to dest: String) {
        let label = tabs.first { $0.id == dest }?.label ?? dest
        guard TabOrder.canDropClip(key: key, on: dest) else {
            monitor?.flash("Can't put clips in \(label)")
            return
        }
        monitor?.post("/lib/file", json: ["key": key, "sig": sig, "dest": dest]) { [weak self] ok, msg in
            guard let self = self else { return }
            if ok {
                self.monitor?.flash("Put in \(label)")
                self.reload()
            } else {
                self.monitor?.flash(msg.isEmpty ? "Could not put it in \(label)" : msg)
            }
        }
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        UserDefaults.standard.set(Array(expanded), forKey: "libOpenTabs")
    }

    /// Opens every group above a tab, so a restored selection is not hidden inside a closed group.
    func openAncestors(of id: String) {
        var at = tabs.first(where: { $0.id == id })?.parent
        var guardCount = 0
        while let p = at, guardCount < 8 {
            expanded.insert(p)
            at = tabs.first(where: { $0.id == p })?.parent
            guardCount += 1
        }
        UserDefaults.standard.set(Array(expanded), forKey: "libOpenTabs")
    }

    func select(_ id: String) {
        selected = id
        tag = ""
        tags = []
        UserDefaults.standard.set(id, forKey: "libTab")
        reload()
        loadTags()
    }

    func setTag(_ t: String) {
        tag = t
        reload()
    }

    func reload(refresh: Bool = false) {
        if tabs.isEmpty { loadTabs() }
        generation += 1
        load(offset: 0, refresh: refresh)
    }

    func loadMoreIfNeeded(_ item: LibItem) {
        guard !loading, items.count < total, item.key == items.last?.key else { return }
        load(offset: items.count, refresh: false)
    }

    func rename(_ item: LibItem, to name: String) {
        monitor?.post("/lib/rename", json: ["key": item.key, "sig": item.sig ?? "", "name": name]) { [weak self] ok, msg in
            guard let self = self else { return }
            if ok {
                self.monitor?.flash("Renamed")
            } else {
                self.monitor?.flash(msg == "changed" ? "That clip changed on the PC, list refreshed" : "Rename failed")
            }
            self.reload(refresh: !ok)
        }
    }

    /// `pinned` is called when CopyQ refused because the clip is pinned there.
    func delete(_ item: LibItem, force: Bool, pinned: @escaping () -> Void) {
        monitor?.post("/lib/delete", json: ["key": item.key, "sig": item.sig ?? "", "force": force]) { [weak self] ok, msg in
            guard let self = self else { return }
            if ok {
                self.monitor?.flash("Deleted")
                self.reload()
            } else if msg == "pinned" {
                pinned()
            } else {
                self.monitor?.flash(msg == "changed" ? "That clip changed on the PC, list refreshed" : "Delete failed")
                self.reload(refresh: true)
            }
        }
    }

    /// Stop taking PC copies from the app this clip came from.
    func blockSource(of item: LibItem) {
        monitor?.post("/lib/block", json: ["key": item.key]) { [weak self] ok, _ in
            self?.monitor?.flash(ok ? "Blocked \(item.src ?? "that app")" : "Could not block that source")
        }
    }

    private func scheduleSearch() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    private static func describe(_ resp: HTTPURLResponse?, _ err: Error?) -> String {
        if let err = err { return err.localizedDescription }
        if let resp = resp { return resp.statusCode == 401 ? "wrong token" : "PC server said HTTP \(resp.statusCode)" }
        return "Set the PC server URL in the Settings tab"
    }

    private func load(offset: Int, refresh: Bool) {
        guard let monitor = monitor else { return }
        let gen = generation
        loading = true
        let path = "/lib/items?tab=\(Self.enc(selected))&q=\(Self.enc(query))&tag=\(Self.enc(tag))"
            + "&offset=\(offset)&limit=\(pageSize)" + (refresh ? "&refresh=1" : "")
        monitor.fetch(path, timeout: 90) { [weak self] data, resp, err in
            guard let self = self, gen == self.generation else { return }
            self.loading = false
            if let data = data, resp?.statusCode == 200,
               let r = try? JSONDecoder().decode(ItemsReply.self, from: data) {
                if offset == 0 {
                    self.items = r.items
                } else {
                    let have = Set(self.items.map { $0.key })
                    self.items += r.items.filter { !have.contains($0.key) }
                }
                self.total = r.items.isEmpty ? self.items.count : r.total
                self.status = "\(r.total) clips" + (self.tag.isEmpty ? "" : "  #\(self.tag)")
            } else {
                self.status = Self.describe(resp, err)
            }
        }
    }
}

/// Long press: preview of the whole clip (iOS 16+), with Copy / Open / Rename / Delete actions.
struct ClipMenu: ViewModifier {
    let text: String
    let image: URL?
    let onCopy: () -> Void
    let onOpen: () -> Void
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var blockLabel: String = ""
    var onBlock: (() -> Void)? = nil
    var onTransform: (() -> Void)? = nil
    /// Text clips: the transforms pinned to this menu (Edit prompt sheet > hold a transform > Pin to clip menu).
    var onQuick: ((MenuTransform) -> Void)? = nil
    var pinned: Bool = false
    var onPin: (() -> Void)? = nil
    @ObservedObject var quick = MenuTransformStore.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.contextMenu(menuItems: { actions }, preview: { preview })
        } else {
            content.contextMenu { actions }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
        if let onQuick = onQuick, !quick.pinned.isEmpty {
            ForEach(quick.pinned) { t in
                Button { onQuick(t) } label: { Label("Copy as " + t.label, systemImage: "wand.and.stars") }
            }
            Divider()
        }
        Button(action: onOpen) { Label("Open full clip", systemImage: "doc.text.magnifyingglass") }
        if let onPin = onPin {
            Button(action: onPin) { Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") }
        }
        if let onTransform = onTransform {
            Button(action: onTransform) { Label("Edit prompt", systemImage: "wand.and.stars") }
        }
        if let onRename = onRename {
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
        }
        if let onBlock = onBlock {
            Button(action: onBlock) { Label(blockLabel, systemImage: "nosign") }
        }
        if let onDelete = onDelete {
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = image {
            AsyncImage(url: image) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                ProgressView().frame(width: 200, height: 200)
            }
        } else {
            ScrollView {
                Text(String(text.prefix(6000)))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(width: 340, height: 460)
        }
    }
}

/// One clip in a list: tap copies, long press previews.
struct ClipRow: View {
    let text: String
    var name: String = ""
    let note: String
    var tags: [String] = []
    var noteColor: Color = .secondary
    let thumb: URL?
    let full: URL?
    let isImage: Bool
    let onCopy: () -> Void
    let onOpen: () -> Void
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var blockLabel: String = ""
    var onBlock: (() -> Void)? = nil
    var onTransform: (() -> Void)? = nil
    var pinned: Bool = false
    var onPin: (() -> Void)? = nil
    var onQuick: ((MenuTransform) -> Void)? = nil

    var body: some View {
        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 3) {
                if !name.isEmpty {
                    Text(name).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                }
                if pinned {
                    Label("Pinned", systemImage: "pin.fill").font(.caption2).foregroundColor(.orange)
                }
                if isImage {
                    AsyncImage(url: thumb) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(height: 110)
                    .cornerRadius(6)
                } else {
                    Text(String(text.prefix(400))).font(.callout).lineLimit(name.isEmpty ? 3 : 2)
                }
                if !tags.isEmpty {
                    Text(tags.map { "#" + $0 }.joined(separator: "  "))
                        .font(.caption2).foregroundColor(.orange).lineLimit(1)
                }
                if !note.isEmpty {
                    Text(note).font(.caption2).foregroundColor(noteColor).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ClipMenu(text: text, image: isImage ? full : nil, onCopy: onCopy, onOpen: onOpen,
                           onRename: onRename, onDelete: onDelete, blockLabel: blockLabel, onBlock: onBlock,
                           onTransform: onTransform, onQuick: onQuick, pinned: pinned, onPin: onPin))
    }
}

/// Runs one PC transform over a whole clip and copies the result (the long-press quick transforms).
enum QuickTransform {
    static func run(_ id: String, label: String, text: String, monitor: ClipMonitor) {
        monitor.postJSON("/transform", json: ["action": id, "text": text]) { ok, obj, message in
            guard ok, let out = obj?["text"] as? String else {
                monitor.flash(message.isEmpty ? "\(label) failed" : message)
                return
            }
            if (obj?["changed"] as? Bool) == false {
                monitor.flash("\(label): nothing to change")
                return
            }
            monitor.copyText(out, quiet: true)
            monitor.flash("Copied: \(label)")
        }
    }
}

/// Select mode: a check circle in front of the row, a tap toggles it instead of copying.
struct Selectable: ViewModifier {
    let active: Bool
    let selected: Bool
    let toggle: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                content.allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
        } else {
            content
        }
    }
}

/// The bar under a list in select mode.
struct SelectionBar: View {
    let count: Int
    let onCopy: () -> Void
    let onRandomizer: () -> Void
    let onPin: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("\(count) selected").foregroundColor(.secondary)
            Spacer(minLength: 4)
            Button("Copy", action: onCopy).disabled(count == 0)
            Button("Randomizer", action: onRandomizer).disabled(count == 0)
            Button("Pin", action: onPin).disabled(count == 0)
            Button("Done", action: onDone).font(.footnote.weight(.semibold))
        }
        .font(.footnote)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}

struct FullClipSheet: View {
    let clip: OpenClip
    @Environment(\.dismiss) private var dismiss
    private static let shown = 20000

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let image = clip.image {
                        AsyncImage(url: image) { img in
                            img.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                        }
                    } else {
                        Text(String(clip.text.prefix(Self.shown))).font(.callout).textSelection(.enabled)
                        if clip.text.count > Self.shown {
                            Text("Showing the first \(Self.shown) of \(clip.text.count) characters. Copy takes all of it.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    if !clip.note.isEmpty {
                        Text(clip.note).font(.caption).foregroundColor(.secondary)
                    }
                    if !clip.link.isEmpty {
                        Text(clip.link).font(.caption).foregroundColor(.blue).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Copy") { clip.copy(); dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct RenameSheet: View {
    let item: LibItem
    let save: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(item: LibItem, save: @escaping (String) -> Void) {
        self.item = item
        self.save = save
        _name = State(initialValue: item.name ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Name"), footer: Text("Leave empty to remove the name. Search finds clips by name.")) {
                    TextField("Clip name", text: $name).disableAutocorrection(true)
                }
                Section(header: Text("Clip")) {
                    Text(String(item.text.prefix(300))).font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(name); dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct LibraryView: View {
    @EnvironmentObject var monitor: ClipMonitor
    @StateObject private var lib = LibraryModel()
    @ObservedObject private var pins = PinStore.shared
    @State private var open: OpenClip?
    @State private var renaming: LibItem?
    @State private var ask: DeleteAsk?
    @State private var editing: EditedText?
    @State private var dropTarget: String?
    @State private var selecting = false
    @State private var picked: [String] = []        // keys, in the order tapped

    private func togglePick(_ key: String) {
        if let i = picked.firstIndex(of: key) { picked.remove(at: i) } else { picked.append(key) }
    }

    private var pickedTexts: [String] {
        picked.compactMap { k in lib.items.first { $0.key == k } }.filter { $0.kind != "image" }.map { $0.text }
    }

    /// Pinned clips at the top of every tab (issue #8), the rest in the server's order.
    private var shownItems: [LibItem] {
        TabOrder.pinnedFirst(lib.items) { pins.isPinned($0.key) }
    }

    /// A tab or a clip dropped on a sidebar tab.
    private func drop(_ providers: [NSItemProvider], on target: String) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let text = obj as? String, let what = TabOrder.parse(text) else { return }
            DispatchQueue.main.async {
                switch what {
                case .tab(let id): lib.moveTab(id, onto: target)
                case .clip(let key, let sig): lib.file(key: key, sig: sig, to: target)
                }
            }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search text, name or tag", text: $lib.query)
                    .autocapitalization(.none).disableAutocorrection(true)
                if !lib.query.isEmpty {
                    Button { lib.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundColor(.secondary)
                }
                if !lib.tags.isEmpty {
                    Menu {
                        Button("All tags") { lib.setTag("") }
                        ForEach(lib.tags.prefix(80)) { t in
                            Button("\(t.tag) (\(t.count))") { lib.setTag(t.tag) }
                        }
                    } label: {
                        Image(systemName: lib.tag.isEmpty ? "tag" : "tag.fill")
                    }
                }
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    picked = []
                }
                .font(.footnote)
                Button { lib.reload(refresh: true); lib.loadTags() } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                HStack(spacing: 2) {
                    TextField("Find tab", text: $lib.tabFilter)
                        .font(.footnote)
                        .autocapitalization(.none).disableAutocorrection(true)
                    if !lib.tabFilter.isEmpty {
                        Button { lib.tabFilter = "" } label: { Image(systemName: "xmark.circle.fill").font(.footnote) }
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(lib.visibleTabs, id: \.tab.id) { row in
                            HStack(spacing: 0) {
                                if lib.parentIds.contains(row.tab.id) {
                                    Button { lib.toggle(row.tab.id) } label: {
                                        Image(systemName: lib.expanded.contains(row.tab.id) ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                            .frame(width: 14)
                                            .padding(.vertical, 11)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Spacer().frame(width: 14)
                                }
                                Button { lib.select(row.tab.id) } label: {
                                    Text(row.tab.label)
                                        .font(.footnote)
                                        .fontWeight(lib.selected == row.tab.id ? .semibold : .regular)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 11).padding(.trailing, 6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.leading, CGFloat(row.depth) * 10)
                            .background(dropTarget == row.tab.id ? Color.orange.opacity(0.35)
                                        : (lib.selected == row.tab.id ? Color.accentColor.opacity(0.22) : Color.clear))
                            .onDrag { NSItemProvider(object: TabOrder.tabPayload(row.tab.id) as NSString) }
                            .onDrop(of: [UTType.plainText], isTargeted: Binding(
                                get: { dropTarget == row.tab.id },
                                set: { on in
                                    if on { dropTarget = row.tab.id } else if dropTarget == row.tab.id { dropTarget = nil }
                                })) { providers in
                                drop(providers, on: row.tab.id)
                            }
                        }
                    }
                }
                }
                .frame(width: 124)   // wider than before: nested tabs are indented
                .background(Color(.secondarySystemBackground))
                Divider()
                List {
                    ForEach(shownItems) { item in
                        row(item)
                            .modifier(Selectable(active: selecting, selected: picked.contains(item.key)) {
                                togglePick(item.key)
                            })
                            .onAppear { lib.loadMoreIfNeeded(item) }
                            .onDrag { NSItemProvider(object: TabOrder.clipPayload(key: item.key, sig: item.sig ?? "") as NSString) }
                    }
                    if lib.loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
                .listStyle(.plain)
                .sheet(item: $renaming) { item in
                    RenameSheet(item: item) { lib.rename(item, to: $0) }
                }
            }
            if selecting {
                SelectionBar(count: picked.count,
                             onCopy: { monitor.copyText(ClipBatch.joined(pickedTexts)) },
                             onRandomizer: {
                                 monitor.copyText(ClipBatch.randomizer(pickedTexts), quiet: true)
                                 monitor.flash("Copied randomizer of \(pickedTexts.count)")
                             },
                             onPin: {
                                 for k in picked where !pins.isPinned(k) {
                                     if let item = lib.items.first(where: { $0.key == k }) {
                                         pins.toggle(Pin(id: item.key, kind: item.kind, text: item.text,
                                                         name: item.name ?? "", img: item.img, thumb: item.thumb ?? item.img))
                                     }
                                 }
                                 monitor.flash("Pinned \(picked.count)")
                             },
                             onDone: { selecting = false; picked = [] })
            }
            Divider()
            Text(lib.status).font(.caption2).foregroundColor(.secondary).padding(4)
        }
        .onAppear { lib.attach(monitor) }
        .sheet(item: $open) { FullClipSheet(clip: $0) }
        .sheet(item: $editing) { TransformSheet(text: $0.text, monitor: monitor).environmentObject(monitor) }
        .alert(ask?.force == true ? "This clip is pinned in CopyQ" : "Delete this clip?",
               isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }),
               presenting: ask) { a in
            Button(a.force ? "Delete anyway" : "Delete", role: .destructive) {
                lib.delete(a.item, force: a.force) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        ask = DeleteAsk(item: a.item, force: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { a in
            Text(String(a.item.text.prefix(140)))
        }
    }

    private func row(_ item: LibItem) -> some View {
        let isImage = item.kind == "image"
        let full = item.img.flatMap { monitor.serverURL($0) }
        let thumb = (item.thumb ?? item.img).flatMap { monitor.serverURL($0) }
        let note = item.note ?? ""
        let copy: () -> Void = {
            if isImage, let path = item.img { monitor.copyImage(path: path) } else { monitor.copyText(item.text) }
            monitor.activate(key: item.key, sig: item.sig ?? "")
        }
        return ClipRow(text: item.text, name: item.name ?? "", note: note, tags: item.tags ?? [],
                       thumb: thumb, full: full, isImage: isImage,
                       onCopy: copy,
                       onOpen: {
                           open = OpenClip(id: item.key, text: item.text, note: note, link: item.url ?? "",
                                           image: isImage ? full : nil, copy: copy)
                       },
                       onRename: { renaming = item },
                       onDelete: { ask = DeleteAsk(item: item, force: false) },
                       blockLabel: "Block clips from \(item.src ?? "")",
                       onBlock: (item.src ?? "").isEmpty ? nil : { lib.blockSource(of: item) },
                       onTransform: isImage ? nil : { editing = EditedText(text: item.text) },
                       pinned: pins.isPinned(item.key),
                       onPin: {
                           pins.toggle(Pin(id: item.key, kind: item.kind, text: item.text, name: item.name ?? "",
                                           img: item.img, thumb: item.thumb ?? item.img))
                       },
                       onQuick: isImage ? nil : { t in
                           QuickTransform.run(t.id, label: t.label, text: item.text, monitor: monitor)
                       })
    }
}
