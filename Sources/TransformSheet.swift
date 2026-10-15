import SwiftUI

/// The prompt-edit sheet: the clip as raw editable text, with the PC's transforms
/// as buttons. The laptop owns the transforms (`prompt_transforms.py`), so the
/// button list comes from `GET /transforms` and new ones need no app rebuild.
///
/// Nothing commits until Copy or Save: every transform only changes the text in
/// this sheet, and Undo walks back through the chain.

struct TransformSpec: Identifiable, Decodable, Equatable {
    let id: String
    let label: String
    let group: String
    let group_label: String
    let scope: String

    /// A transform that needs the caret, not just the selected substring.
    var isDocument: Bool { scope == "document" }
}

private struct TransformList: Decodable {
    let transforms: [TransformSpec]
}

private struct TransformResult: Decodable {
    let ok: Bool?
    let text: String?
    let start: Int?
    let end: Int?
    let changed: Bool?
    let error: String?
}

final class TransformModel: ObservableObject {
    @Published var text: String
    @Published var specs: [TransformSpec] = []
    @Published var busy = false
    @Published var error = ""
    @Published var selection: NSRange?          // nil = act on the whole text

    /// Previous versions, newest last. Capped so a long session cannot grow forever.
    private var undoStack: [(String, NSRange?)] = []
    private static let undoLimit = 40
    private let original: String
    private weak var monitor: ClipMonitor?

    init(text: String, monitor: ClipMonitor?) {
        self.text = text
        self.original = text
        self.monitor = monitor
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var isChanged: Bool { text != original }

    var favourites: [TransformSpec] {
        let ids = TransformFavourites.top(specs.map { $0.id })
        return ids.compactMap { id in specs.first { $0.id == id } }
    }

    /// Group order is the server's order, not alphabetical.
    var groups: [(key: String, label: String, items: [TransformSpec])] {
        var seen: [String] = []
        for s in specs where !seen.contains(s.group) { seen.append(s.group) }
        return seen.map { g in
            (key: g,
             label: specs.first { $0.group == g }?.group_label ?? g,
             items: specs.filter { $0.group == g })
        }
    }

    func loadSpecs() {
        guard specs.isEmpty else { return }
        monitor?.fetch("/transforms", timeout: 15) { [weak self] data, resp, err in
            guard let self = self else { return }
            guard let data = data, resp?.statusCode == 200,
                  let list = try? JSONDecoder().decode(TransformList.self, from: data) else {
                self.error = err?.localizedDescription ?? "Could not reach the PC server"
                return
            }
            self.specs = list.transforms
            self.error = ""
        }
    }

    func apply(_ spec: TransformSpec) {
        guard !busy, let monitor = monitor else { return }
        busy = true
        error = ""
        let before = (text, selection)
        var payload: [String: Any] = ["action": spec.id, "text": text]
        if let sel = selection {
            payload["start"] = sel.location
            payload["end"] = sel.location + sel.length
        }
        monitor.postJSON("/transform", json: payload) { [weak self] ok, obj, message in
            guard let self = self else { return }
            self.busy = false
            guard ok, let obj = obj,
                  let result = try? JSONDecoder().decode(TransformResult.self,
                                                         from: JSONSerialization.data(withJSONObject: obj)),
                  let newText = result.text else {
                self.error = message.isEmpty ? "Transform failed" : message
                return
            }
            if result.changed == false {
                self.error = "Nothing to change"
                return
            }
            self.undoStack.append(before)
            if self.undoStack.count > Self.undoLimit { self.undoStack.removeFirst() }
            self.text = newText
            if let s = result.start, let e = result.end, e > s, e <= newText.utf16.count {
                self.selection = NSRange(location: s, length: e - s)
            } else {
                self.selection = nil
            }
            TransformFavourites.bump(spec.id)
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        text = last.0
        selection = last.1
        error = ""
    }

    func reset() {
        guard isChanged else { return }
        undoStack.append((text, selection))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        text = original
        selection = nil
    }

    /// Copy = the PC clipboard (and this phone's), Save = a new clip in the store.
    func commit(copy: Bool, save: Bool, done: @escaping (Bool) -> Void) {
        guard !busy, let monitor = monitor else { done(false); return }
        let out = text
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Nothing to commit"
            done(false)
            return
        }
        busy = true
        if copy { monitor.copyText(out, quiet: true) }     // the phone's clipboard, right away
        monitor.postJSON("/clip/push", json: ["text": out, "copy": copy, "save": save]) { [weak self] ok, _, message in
            guard let self = self else { return }
            self.busy = false
            if ok {
                monitor.flash(save ? (copy ? "Copied and saved" : "Saved") : "Copied")
            } else {
                // the phone clipboard already has it, so this is only about the PC
                self.error = message.isEmpty ? "The PC did not take it" : message
            }
            done(ok)
        }
    }

    /// Select the line the caret sits in: iOS text selection is clumsy with a thumb.
    func selectLine() {
        selection = PromptSelection.line(in: text, caret: selection?.location ?? 0)
    }

    /// Select the comma separated tag the caret sits in (the cursor-jumper, ported).
    func selectTag() {
        selection = PromptSelection.tag(in: text, caret: selection?.location ?? 0)
    }

    var selectionLabel: String {
        guard let s = selection, s.length > 0 else { return "whole clip" }
        let ns = text as NSString
        guard s.location + s.length <= ns.length else { return "whole clip" }
        let picked = ns.substring(with: s).replacingOccurrences(of: "\n", with: " ")
        return picked.count > 28 ? String(picked.prefix(28)) + "..." : picked
    }
}

struct TransformSheet: View {
    @StateObject private var model: TransformModel
    @ObservedObject private var menuStore = MenuTransformStore.shared
    @EnvironmentObject private var monitor: ClipMonitor
    @Environment(\.dismiss) private var dismiss

    init(text: String, monitor: ClipMonitor?) {
        _model = StateObject(wrappedValue: TransformModel(text: text, monitor: monitor))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                editor
                Divider()
                controls
            }
            .navigationTitle("Edit prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Undo") { model.undo() }.disabled(!model.canUndo)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { model.loadSpecs() }
    }

    private var editor: some View {
        VStack(spacing: 4) {
            SelectableTextEditor(text: $model.text, selection: $model.selection)
                .frame(minHeight: 150, maxHeight: 260)
                .padding(.horizontal, 6)
            HStack(spacing: 8) {
                Text("Acting on: \(model.selectionLabel)")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Button("Line") { model.selectLine() }.font(.caption)
                Button("Tag") { model.selectTag() }.font(.caption)
                Button("All") { model.selection = nil }.font(.caption)
            }
            .padding(.horizontal, 12)
            if !model.error.isEmpty {
                Text(model.error).font(.caption).foregroundColor(.red)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 6)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.specs.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading transforms from the PC...")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                }
                if !model.favourites.isEmpty {
                    group("Most used", model.favourites)
                }
                ForEach(model.groups, id: \.key) { g in
                    group(g.label, g.items)
                }
            }
            .padding(.vertical, 12)
        }
        .safeAreaInset(edge: .bottom) { commitBar }
    }

    private func group(_ title: String, _ items: [TransformSpec]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { spec in
                        Button(menuStore.isPinned(spec.id) ? "\u{1F4CC} " + spec.label : spec.label) { model.apply(spec) }
                            .font(.footnote)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.14))
                            .foregroundColor(.accentColor)
                            .cornerRadius(9)
                            .disabled(model.busy)
                            .contextMenu {
                                Button(menuStore.isPinned(spec.id) ? "Unpin from clip menu" : "Pin to clip menu") {
                                    menuStore.toggle(id: spec.id, label: spec.label)
                                }
                            }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var commitBar: some View {
        HStack(spacing: 10) {
            Button("Reset") { model.reset() }
                .disabled(!model.isChanged)
            Spacer()
            Button("Save") { model.commit(copy: false, save: true) { _ in } }
            Button("Copy") {
                model.commit(copy: true, save: false) { ok in if ok { dismiss() } }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
    }
}

/// UITextView wrapper: SwiftUI's TextEditor cannot report or set the selected range,
/// and the transforms need it.
struct SelectableTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange?

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        v.autocapitalizationType = .none
        v.autocorrectionType = .no
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.spellCheckingType = .no
        v.delegate = context.coordinator
        v.text = text
        v.backgroundColor = .secondarySystemBackground
        v.layer.cornerRadius = 8
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text {
            v.text = text
        }
        // only push a selection the model set, never fight the user's own caret
        if let s = selection, s.location + s.length <= (v.text as NSString).length,
           v.selectedRange != s, !context.coordinator.editing {
            v.selectedRange = s
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: SelectableTextEditor
        var editing = false

        init(_ parent: SelectableTextEditor) { self.parent = parent }

        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
        }

        func textViewDidChangeSelection(_ v: UITextView) {
            let r = v.selectedRange
            parent.selection = r.length > 0 ? r : NSRange(location: r.location, length: 0)
        }

        func textViewDidBeginEditing(_ v: UITextView) { editing = true }
        func textViewDidEndEditing(_ v: UITextView) { editing = false }
    }
}
