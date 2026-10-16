import SwiftUI

/// Which PC copies never reach the phone, edited right in the Settings tab.
/// Same PC routes the old browser page used: GET /pc/exclude (?set= / ?list=&add= / &remove=) and /pc/block.
final class ExclusionModel: ObservableObject {
    @Published var toggles: [(key: String, on: Bool)] = []
    @Published var lists: [String: [String]] = [:]
    @Published var blocked: [String] = []
    @Published var apps: [(app: String, clips: Int)] = []
    @Published var recent: [String] = []
    @Published var status = ""

    static let listKeys = ["allow_paths", "text", "regex"]
    private weak var monitor: ClipMonitor?

    static func label(_ key: String) -> (String, String) {
        switch key {
        case "file_paths": return ("File path text", "text that is only file paths (paths in always-pass folders still go)")
        case "copied_files": return ("Copied files", "files copied in Explorer or DOpus")
        case "logs": return ("Logs and errors", "tracebacks, error text, terminal output")
        case "commands": return ("Commands and code", "shell commands and code snippets")
        case "searches": return ("Everything searches", "search strings copied from Everything")
        case "allow_paths": return ("Always-pass folders", "a path containing one of these is never blocked")
        case "text": return ("Blocked text", "clips containing this text")
        case "regex": return ("Blocked patterns (regex)", "clips matching this pattern, case ignored")
        default: return (key, "")
        }
    }

    func attach(_ m: ClipMonitor) {
        monitor = m
        load()
    }

    func load() { call("/pc/exclude") }

    func toggle(_ key: String) { call("/pc/exclude?set=\(Self.enc(key))&on=toggle") }

    func add(_ value: String, to list: String) {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        call("/pc/exclude?list=\(Self.enc(list))&add=\(Self.enc(v))")
    }

    func remove(_ value: String, from list: String) {
        call("/pc/exclude?list=\(Self.enc(list))&remove=\(Self.enc(value))")
    }

    func block(_ app: String) {
        let a = app.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        monitor?.fetch("/pc/block?add=\(Self.enc(a))") { [weak self] _, _, _ in self?.load() }
    }

    func unblock(_ app: String) {
        monitor?.fetch("/pc/block?remove=\(Self.enc(app))") { [weak self] _, _, _ in self?.load() }
    }

    private func call(_ path: String) {
        monitor?.fetch(path) { [weak self] data, resp, err in
            guard let self = self else { return }
            guard let data = data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.status = err?.localizedDescription ?? "Could not reach the PC server"
                return
            }
            if let e = obj["error"] as? String {
                self.status = e
                if resp?.statusCode != 200 { self.load() }
                return
            }
            self.apply(obj)
        }
    }

    private func apply(_ obj: [String: Any]) {
        status = ""
        if let ex = obj["exclude"] as? [String: Any] {
            let order = ["file_paths", "copied_files", "logs", "commands", "searches"]
            let keys = ex.keys.filter { ex[$0] is Bool }
                .sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            toggles = keys.map { (key: $0, on: ex[$0] as? Bool ?? false) }
            for k in Self.listKeys { lists[k] = ex[k] as? [String] ?? [] }
        }
        if let b = obj["blocked_apps"] as? [String] { blocked = b }
        if let a = obj["apps"] as? [[String: Any]] {
            apps = a.compactMap { d in (d["app"] as? String).map { (app: $0, clips: d["clips"] as? Int ?? 0) } }
        }
        if let r = obj["recent"] as? [[String: Any]] {
            recent = r.prefix(15).map { d in
                [d["ts"] as? String, d["rule"] as? String, d["preview"] as? String]
                    .compactMap { $0 }.joined(separator: "  ")
            }
        }
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

/// The exclusions sections inside the Settings form.
struct ExclusionSections: View {
    @EnvironmentObject var monitor: ClipMonitor
    @StateObject private var model = ExclusionModel()
    @State private var drafts: [String: String] = [:]
    @State private var appDraft = ""

    var body: some View {
        Group {
            Section(header: Text("Keep these PC copies off the phone"),
                    footer: Text(model.status.isEmpty ? "Changes apply on the PC right away." : model.status)) {
                ForEach(model.toggles, id: \.key) { t in
                    let l = ExclusionModel.label(t.key)
                    Toggle(isOn: Binding(get: { t.on }, set: { _ in model.toggle(t.key) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.0)
                            if !l.1.isEmpty { Text(l.1).font(.caption2).foregroundColor(.secondary) }
                        }
                    }
                }
            }
            Section(header: Text("Blocked apps"), footer: Text("Tap a recent source to block it. Swipe a blocked app to unblock.")) {
                ForEach(model.blocked, id: \.self) { a in
                    Text(a).swipeActions { Button("Unblock", role: .destructive) { model.unblock(a) } }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.apps.filter { !model.blocked.contains($0.app) }, id: \.app) { a in
                            Button("\(a.app) (\(a.clips))") { model.block(a.app) }
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.14))
                                .cornerRadius(8)
                                .buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    TextField("app.exe", text: $appDraft).autocapitalization(.none).disableAutocorrection(true)
                    Button("Block") { model.block(appDraft); appDraft = "" }.disabled(appDraft.isEmpty)
                }
            }
            ForEach(ExclusionModel.listKeys, id: \.self) { key in
                let l = ExclusionModel.label(key)
                Section(header: Text(l.0), footer: Text(l.1)) {
                    ForEach(model.lists[key] ?? [], id: \.self) { v in
                        Text(v).font(.footnote)
                            .swipeActions { Button("Remove", role: .destructive) { model.remove(v, from: key) } }
                    }
                    HStack {
                        TextField("add", text: Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 }))
                            .autocapitalization(.none).disableAutocorrection(true)
                        Button("Add") { model.add(drafts[key] ?? "", to: key); drafts[key] = "" }
                            .disabled((drafts[key] ?? "").isEmpty)
                    }
                }
            }
            if !model.recent.isEmpty {
                Section(header: Text("Recently kept off the phone")) {
                    ForEach(Array(model.recent.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).lineLimit(2)
                    }
                }
            }
        }
        .onAppear { model.attach(monitor) }
    }
}
