import SwiftUI

// Browser for clips that live on the PC: the ClipPiP clip database ("history") and the CopyQ tabs.
// Nothing here is stored on the phone; text and images are loaded from the PC server on demand.

struct LibTab: Decodable, Identifiable {
    let id: String
    let label: String
}

struct LibItem: Decodable, Identifiable {
    let key: String
    let kind: String
    let text: String
    let note: String
    let url: String
    let img: String?
    let thumb: String?
    var id: String { key }
}

private struct TabsReply: Decodable { let tabs: [LibTab] }
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

final class LibraryModel: ObservableObject {
    @Published var tabs: [LibTab] = []
    @Published var selected = UserDefaults.standard.string(forKey: "libTab") ?? "history"
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
    }

    func loadTabs() {
        monitor?.fetch("/lib/tabs") { [weak self] data, resp, err in
            guard let self = self else { return }
            if let data = data, resp?.statusCode == 200,
               let r = try? JSONDecoder().decode(TabsReply.self, from: data) {
                self.tabs = r.tabs
            } else {
                self.status = Self.describe(resp, err)
            }
        }
    }

    func select(_ id: String) {
        selected = id
        UserDefaults.standard.set(id, forKey: "libTab")
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
        return "Set the PC server URL in the Clips tab"
    }

    private func load(offset: Int, refresh: Bool) {
        guard let monitor = monitor else { return }
        let gen = generation
        loading = true
        let path = "/lib/items?tab=\(Self.enc(selected))&q=\(Self.enc(query))&offset=\(offset)&limit=\(pageSize)"
            + (refresh ? "&refresh=1" : "")
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
                self.status = "\(r.total) clips"
            } else {
                self.status = Self.describe(resp, err)
            }
        }
    }
}

/// Long press: preview of the whole clip (iOS 16+), with Copy / Open full clip actions.
struct ClipMenu: ViewModifier {
    let text: String
    let image: URL?
    let onCopy: () -> Void
    let onOpen: () -> Void

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
        Button(action: onOpen) { Label("Open full clip", systemImage: "doc.text.magnifyingglass") }
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
    let note: String
    var noteColor: Color = .secondary
    let thumb: URL?
    let full: URL?
    let isImage: Bool
    let onCopy: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 3) {
                if isImage {
                    AsyncImage(url: thumb) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(height: 110)
                    .cornerRadius(6)
                } else {
                    Text(String(text.prefix(400))).font(.callout).lineLimit(3)
                }
                if !note.isEmpty {
                    Text(note).font(.caption2).foregroundColor(noteColor).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ClipMenu(text: text, image: isImage ? full : nil, onCopy: onCopy, onOpen: onOpen))
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

struct LibraryView: View {
    @EnvironmentObject var monitor: ClipMonitor
    @StateObject private var lib = LibraryModel()
    @State private var open: OpenClip?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search clips", text: $lib.query)
                    .autocapitalization(.none).disableAutocorrection(true)
                if !lib.query.isEmpty {
                    Button { lib.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundColor(.secondary)
                }
                Button { lib.reload(refresh: true) } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(lib.tabs) { tab in
                            Button { lib.select(tab.id) } label: {
                                Text(tab.label)
                                    .font(.footnote)
                                    .fontWeight(lib.selected == tab.id ? .semibold : .regular)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 11).padding(.horizontal, 8)
                                    .background(lib.selected == tab.id ? Color.accentColor.opacity(0.22) : Color.clear)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 96)
                .background(Color(.secondarySystemBackground))
                Divider()
                List {
                    ForEach(lib.items) { item in
                        row(item).onAppear { lib.loadMoreIfNeeded(item) }
                    }
                    if lib.loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            Text(lib.status).font(.caption2).foregroundColor(.secondary).padding(4)
        }
        .onAppear { lib.attach(monitor) }
        .sheet(item: $open) { FullClipSheet(clip: $0) }
    }

    private func row(_ item: LibItem) -> some View {
        let isImage = item.kind == "image"
        let full = item.img.flatMap { monitor.serverURL($0) }
        let thumb = (item.thumb ?? item.img).flatMap { monitor.serverURL($0) }
        let copy: () -> Void = {
            if isImage, let path = item.img { monitor.copyImage(path: path) } else { monitor.copyText(item.text) }
        }
        return ClipRow(text: item.text, note: item.note, thumb: thumb, full: full, isImage: isImage,
                       onCopy: copy,
                       onOpen: {
                           open = OpenClip(id: item.key, text: item.text, note: item.note, link: item.url,
                                           image: isImage ? full : nil, copy: copy)
                       })
    }
}
