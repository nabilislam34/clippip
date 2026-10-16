import SwiftUI
import AVFoundation

@main
struct ClipPiPApp: App {
    @StateObject private var pip = PiPManager.shared
    @StateObject private var monitor = ClipMonitor()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pip)
                .environmentObject(monitor)
                .onAppear { pip.prepare(); monitor.start() }
                .onOpenURL { url in
                    // clippip://start  or  clippip://stop
                    // clippip://pc-on, clippip://pc-off, clippip://pc-toggle  (PC clips switch)
                    if url.host == "start" { pip.requestStart() }
                    else if url.host == "stop" { pip.stop() }
                    else if url.host == "pc-on" { monitor.setPCReceive("1") }
                    else if url.host == "pc-off" { monitor.setPCReceive("0") }
                    else if url.host == "pc-toggle" { monitor.setPCReceive("toggle") }
                }
                .onChange(of: phase) { p in
                    if p == .background { pip.startIfNeeded() }
                }
        }
    }
}

final class LayerView: UIView {
    var host: AVPlayerLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        host?.frame = bounds
    }
}

struct PlayerHost: UIViewRepresentable {
    let layer: AVPlayerLayer
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.host = layer
        v.layer.addSublayer(layer)
        return v
    }
    func updateUIView(_ v: LayerView, context: Context) {}
}

/// The PiP video and its pill stay on screen above every tab: the video layer has to be in the window
/// for PiP to start.
struct RootView: View {
    @EnvironmentObject var monitor: ClipMonitor

    var body: some View {
        VStack(spacing: 0) {
            PiPPill()
            TabView {
                ContentView()
                    .tabItem { Label("Clips", systemImage: "doc.on.clipboard") }
                LibraryView()
                    .tabItem { Label("Library", systemImage: "square.stack.3d.up") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
        .overlay(alignment: .bottom) {
            if !monitor.toast.isEmpty {
                Text(monitor.toast)
                    .font(.footnote).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.8)).cornerRadius(16)
                    .padding(.bottom, 70)
            }
        }
    }
}

/// PiP status: tap to start or stop. Green = running, orange = ready, grey = not ready yet.
struct PiPPill: View {
    @EnvironmentObject var pip: PiPManager

    private var colour: Color {
        pip.pipActive ? .green : (pip.pipPossible ? .orange : .gray)
    }

    var body: some View {
        Button {
            pip.pipActive ? pip.stop() : pip.startIfNeeded()
        } label: {
            HStack(spacing: 8) {
                PlayerHost(layer: pip.playerLayer).frame(width: 32, height: 18).cornerRadius(3)
                Circle().fill(colour).frame(width: 8, height: 8)
                Text(pip.status).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                Text(pip.pipActive ? "Stop" : "Start").font(.caption).fontWeight(.semibold)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(colour.opacity(0.18))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!pip.pipPossible && !pip.pipActive)
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

/// One clip as a card: colour bar on the left for where it came from, two lines of the text, an icon and
/// its age, and a small thumbnail for an image clip.
struct ClipCard: View {
    let text: String
    var name: String = ""
    let colour: Color
    let icon: String
    let badge: String
    var thumb: URL? = nil
    var isImage = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if !name.isEmpty {
                    Text(name).font(.caption).fontWeight(.semibold).lineLimit(1)
                }
                Text(isImage ? "Image" : String(text.prefix(300)))
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Image(systemName: icon)
                    Text(badge).lineLimit(1)
                }
                .font(.caption2).foregroundColor(.secondary)
            }
            if isImage {
                AsyncImage(url: thumb) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 44, height: 44)
                .clipped()
                .cornerRadius(6)
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .leading) { colour.frame(width: 5) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

/// The Clips tab: nothing but the feed (search, pinned strip, cards).
struct ContentView: View {
    @EnvironmentObject var monitor: ClipMonitor
    @State private var open: OpenClip?
    @State private var filter = ""
    @State private var editing: EditedText?
    @ObservedObject private var pins = PinStore.shared
    @FocusState private var searchFocused: Bool

    @State private var selecting = false
    @State private var picked: [UUID] = []

    private var shown: [Clip] {
        guard !filter.trimmingCharacters(in: .whitespaces).isEmpty else { return monitor.history }
        return monitor.history.filter { c in
            ClipSearch.matches(text: c.text, note: c.note, date: c.date, query: filter)
        }
    }

    private var pickedTexts: [String] {
        picked.compactMap { id in monitor.history.first { $0.id == id } }.filter { $0.kind != "image" }.map { $0.text }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search (today, 10-15, app:chrome)", text: $filter)
                    .autocapitalization(.none).disableAutocorrection(true)
                    .focused($searchFocused)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundColor(.secondary)
                }
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    picked = []
                }
                .font(.footnote)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    if !pins.pins.isEmpty && filter.isEmpty {
                        pinStrip
                    }
                    if shown.isEmpty {
                        emptyState
                    }
                    ForEach(shown) { c in
                        card(c)
                            .modifier(Selectable(active: selecting, selected: picked.contains(c.id)) {
                                if let i = picked.firstIndex(of: c.id) { picked.remove(at: i) } else { picked.append(c.id) }
                            })
                    }
                    Text(monitor.pcStatus)
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            if selecting {
                SelectionBar(count: picked.count,
                             onCopy: { monitor.copyText(ClipBatch.joined(pickedTexts)) },
                             onRandomizer: {
                                 monitor.copyText(ClipBatch.randomizer(pickedTexts), quiet: true)
                                 monitor.flash("Copied randomizer of \(pickedTexts.count)")
                             },
                             onPin: {
                                 for id in picked {
                                     if let c = monitor.history.first(where: { $0.id == id }), !pins.isPinned(pinId(c)) {
                                         let isImage = c.kind == "image" && c.serverId != nil
                                         pins.toggle(Pin(id: pinId(c), kind: isImage ? "image" : "text", text: c.text, name: "",
                                                         img: isImage ? "/clip/file?id=\(c.serverId ?? 0)" : nil,
                                                         thumb: isImage ? "/clip/thumb?id=\(c.serverId ?? 0)" : nil))
                                     }
                                 }
                                 monitor.flash("Pinned \(picked.count)")
                             },
                             onDone: { selecting = false; picked = [] })
            }
        }
        .sheet(item: $open) { FullClipSheet(clip: $0) }
        .sheet(item: $editing) { TransformSheet(text: $0.text, monitor: monitor).environmentObject(monitor) }
        .onAppear {
            // the keyboard launch check in CI starts the app with this argument to bring a keyboard up
            if ProcessInfo.processInfo.arguments.contains("-focusSearch") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { searchFocused = true }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").font(.largeTitle).foregroundColor(.secondary)
            Text(filter.isEmpty ? "Copy something on the PC and it lands here" : "No clip matches that search")
                .font(.callout)
            if monitor.server.isEmpty {
                Text("Set the PC server in the Settings tab first").font(.caption).foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var pinStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pins.pins) { p in
                    pinCard(p)
                }
            }
        }
    }

    private static func tapFeedback() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func card(_ c: Clip) -> some View {
        let isImage = c.kind == "image" && c.serverId != nil
        let full = isImage ? monitor.serverURL("/clip/file?id=\(c.serverId ?? 0)") : nil
        let thumb = isImage ? monitor.serverURL("/clip/thumb?id=\(c.serverId ?? 0)") : nil
        let failed = !c.fromPC && c.note != "sent"
        let colour: Color = c.fromPC ? .blue : (failed ? .red : .green)
        let icon = c.fromPC ? "desktopcomputer" : (failed ? "exclamationmark.triangle" : "iphone")
        let badge = RelativeTime.short(c.date) + (failed ? "  " + c.note : "")
        let note = "\(c.note)  \(Self.stamp.string(from: c.date))"
        let copy: () -> Void = { monitor.recopy(c) }
        return Button {
            Self.tapFeedback()
            copy()
        } label: {
            ClipCard(text: c.text, colour: colour, icon: icon, badge: badge, thumb: thumb, isImage: isImage)
        }
        .buttonStyle(.plain)
        .modifier(ClipMenu(text: c.text, image: isImage ? full : nil, onCopy: copy,
                           onOpen: {
                               open = OpenClip(id: c.id.uuidString, text: c.text, note: note, link: "",
                                               image: full, copy: copy)
                           },
                           onDelete: { monitor.remove(c) },
                           onTransform: isImage ? nil : { editing = EditedText(text: c.text) },
                           onQuick: isImage ? nil : { t in
                               QuickTransform.run(t.id, label: t.label, text: c.text, monitor: monitor)
                           },
                           pinned: pins.isPinned(pinId(c)),
                           onPin: {
                               pins.toggle(Pin(id: pinId(c), kind: isImage ? "image" : "text", text: c.text, name: "",
                                               img: isImage ? "/clip/file?id=\(c.serverId ?? 0)" : nil,
                                               thumb: isImage ? "/clip/thumb?id=\(c.serverId ?? 0)" : nil))
                           }))
    }

    private func pinId(_ c: Clip) -> String {
        c.serverId.map { "h\($0)" } ?? PinStore.textId(c.text)
    }

    /// A pinned clip: tap copies it (and puts it on the PC clipboard, like any other clip), hold to unpin.
    private func pinCard(_ p: Pin) -> some View {
        let isImage = p.kind == "image" && p.img != nil
        let full = isImage ? p.img.flatMap { monitor.serverURL($0) } : nil
        let thumb = isImage ? (p.thumb ?? p.img).flatMap { monitor.serverURL($0) } : nil
        let copy: () -> Void = {
            if isImage, let path = p.img {
                monitor.copyImage(path: path)
                if p.id.hasPrefix("h") { monitor.activate(key: p.id, sig: "") }
            } else {
                monitor.copyText(p.text)
                if monitor.activateOnPC {
                    monitor.post("/clip/push", json: ["text": p.text, "copy": true, "save": false]) { _, _ in }
                }
            }
        }
        return Button {
            Self.tapFeedback()
            copy()
        } label: {
            ClipCard(text: p.text, name: p.name, colour: .orange, icon: "pin.fill", badge: "pinned",
                     thumb: thumb, isImage: isImage)
                .frame(width: 170)
        }
        .buttonStyle(.plain)
        .modifier(ClipMenu(text: p.text, image: isImage ? full : nil, onCopy: copy,
                           onOpen: {
                               open = OpenClip(id: "pin-" + p.id, text: p.text, note: "", link: "", image: full, copy: copy)
                           },
                           onTransform: isImage ? nil : { editing = EditedText(text: p.text) },
                           onQuick: isImage ? nil : { t in
                               QuickTransform.run(t.id, label: t.label, text: p.text, monitor: monitor)
                           },
                           pinned: true,
                           onPin: { pins.unpin(p.id) }))
    }
}

/// The Settings tab: PC server, the PC clips switches, exclusions, the keyboard link and the version.
struct SettingsView: View {
    @EnvironmentObject var monitor: ClipMonitor

    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    var body: some View {
        Form {
            Section(header: Text("PC server"), footer: Text(monitor.pcStatus)) {
                TextField("http://<pc-ip>:5051", text: $monitor.server)
                    .autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                TextField("token", text: $monitor.token)
                    .autocapitalization(.none).disableAutocorrection(true)
            }
            Section(header: Text("PC clips")) {
                Toggle("Put PC copies on this phone's clipboard", isOn: $monitor.autoCopy)
                Toggle("Tapping a clip also puts it on the PC clipboard", isOn: $monitor.activateOnPC)
                Button(monitor.pcPaused ? "PC clips are OFF: turn on" : "PC clips are ON: turn off") {
                    monitor.setPCReceive("toggle")
                }
                .foregroundColor(monitor.pcPaused ? .red : .accentColor)
                .disabled(monitor.server.isEmpty)
            }
            ExclusionSections()
            Section(header: Text("Exclusions page"),
                    footer: Text("The same settings as above, as the PC's page in the browser.")) {
                if let url = monitor.serverURL("/pc/exclude/ui") {
                    Link("Open the exclusions page", destination: url)
                } else {
                    Text("Set the PC server first").foregroundColor(.secondary)
                }
            }
            Section(header: Text("Keyboard"),
                    footer: Text("Add the keyboard in Settings > General > Keyboard > Keyboards > Add New Keyboard > ClipPiP, turn on Allow Full Access, tap this button, then open the keyboard once.")) {
                Button("Link the ClipPiP keyboard") { monitor.linkKeyboard() }
                    .disabled(monitor.server.isEmpty)
            }
            Section {
                HStack {
                    Text("ClipPiP")
                    Spacer()
                    Text(Self.version).foregroundColor(.secondary)
                }
            }
        }
    }
}

/// A clip opened in the transform sheet. Identifiable so .sheet(item:) can drive it.
struct EditedText: Identifiable {
    let id = UUID()
    let text: String
}
