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

/// The PiP video and its button stay on screen above both tabs, so PiP can start from either one.
struct RootView: View {
    @EnvironmentObject var pip: PiPManager
    @EnvironmentObject var monitor: ClipMonitor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PlayerHost(layer: pip.playerLayer).frame(width: 80, height: 45)
                Text(pip.status).font(.caption).lineLimit(2)
                Spacer()
                Button(pip.pipActive ? "Stop PiP" : "Start PiP") {
                    pip.pipActive ? pip.stop() : pip.startIfNeeded()
                }.disabled(!pip.pipPossible && !pip.pipActive)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            TabView {
                ContentView()
                    .tabItem { Label("Clips", systemImage: "doc.on.clipboard") }
                LibraryView()
                    .tabItem { Label("Library", systemImage: "square.stack.3d.up") }
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

struct ContentView: View {
    @EnvironmentObject var monitor: ClipMonitor
    @State private var open: OpenClip?
    @State private var filter = ""
    @State private var editing: EditedText?
    @ObservedObject private var pins = PinStore.shared
    @FocusState private var searchFocused: Bool

    private var shown: [Clip] {
        let words = filter.lowercased().split(separator: " ")
        guard !words.isEmpty else { return monitor.history }
        return monitor.history.filter { c in
            let hay = (c.text + " " + c.note).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("PC server")) {
                    TextField("http://<pc-ip>:5051", text: $monitor.server)
                        .autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                    TextField("token", text: $monitor.token)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Toggle("Put PC copies on this phone's clipboard", isOn: $monitor.autoCopy)
                    Toggle("Tapping a clip also puts it on the PC clipboard", isOn: $monitor.activateOnPC)
                    Button(monitor.pcPaused ? "PC clips are OFF: turn on" : "PC clips are ON: turn off") {
                        monitor.setPCReceive("toggle")
                    }
                    .foregroundColor(monitor.pcPaused ? .red : .accentColor)
                    .disabled(monitor.server.isEmpty)
                }
                Section(footer: Text("Add the keyboard in Settings > General > Keyboard > Keyboards > Add New Keyboard > ClipPiP, turn on Allow Full Access, tap this button, then open the keyboard once.")) {
                    Button("Link the ClipPiP keyboard") { monitor.linkKeyboard() }
                        .disabled(monitor.server.isEmpty)
                }
                if !pins.pins.isEmpty {
                    Section(header: Text("Pinned (hold to unpin)")) {
                        ForEach(pins.pins) { p in
                            pinRow(p)
                        }
                    }
                }
                Section(header: Text("Clips (tap to copy, hold for more)"),
                        footer: Text("\(monitor.pcStatus)\nClipPiP \(Self.version)")) {
                    TextField("Search these clips", text: $filter)
                        .autocapitalization(.none).disableAutocorrection(true)
                        .focused($searchFocused)
                    ForEach(shown) { c in
                        row(c)
                    }
                }
            }
            .navigationTitle("ClipPiP")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .sheet(item: $open) { FullClipSheet(clip: $0) }
        .sheet(item: $editing) { TransformSheet(text: $0.text, monitor: monitor).environmentObject(monitor) }
        .onAppear {
            // the keyboard launch check in CI starts the app with this argument to bring a keyboard up
            if ProcessInfo.processInfo.arguments.contains("-focusSearch") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { searchFocused = true }
            }
        }
    }

    private func row(_ c: Clip) -> some View {
        let isImage = c.kind == "image" && c.serverId != nil
        let full = isImage ? monitor.serverURL("/clip/file?id=\(c.serverId ?? 0)") : nil
        let thumb = isImage ? monitor.serverURL("/clip/thumb?id=\(c.serverId ?? 0)") : nil
        let note = "\(c.note)  \(Self.stamp.string(from: c.date))"
        return ClipRow(text: c.text, note: note,
                       noteColor: c.fromPC ? .blue : (c.note == "sent" ? .green : .red),
                       thumb: thumb, full: full, isImage: isImage,
                       onCopy: { monitor.recopy(c) },
                       onOpen: {
                           open = OpenClip(id: c.id.uuidString, text: c.text, note: note, link: "",
                                           image: full, copy: { monitor.recopy(c) })
                       },
                       onDelete: { monitor.remove(c) },
                       onTransform: isImage ? nil : { editing = EditedText(text: c.text) },
                       pinned: pins.isPinned(pinId(c)),
                       onPin: {
                           pins.toggle(Pin(id: pinId(c), kind: isImage ? "image" : "text", text: c.text, name: "",
                                           img: isImage ? "/clip/file?id=\(c.serverId ?? 0)" : nil,
                                           thumb: isImage ? "/clip/thumb?id=\(c.serverId ?? 0)" : nil))
                       })
    }

    private func pinId(_ c: Clip) -> String {
        c.serverId.map { "h\($0)" } ?? PinStore.textId(c.text)
    }

    /// A pinned clip: tap copies it (and puts it on the PC clipboard, like any other clip), hold to unpin.
    private func pinRow(_ p: Pin) -> some View {
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
        return ClipRow(text: p.text, name: p.name, note: "", thumb: thumb, full: full, isImage: isImage,
                       onCopy: copy,
                       onOpen: {
                           open = OpenClip(id: "pin-" + p.id, text: p.text, note: "", link: "", image: full, copy: copy)
                       },
                       onTransform: isImage ? nil : { editing = EditedText(text: p.text) },
                       pinned: true,
                       onPin: { pins.unpin(p.id) })
    }
}

/// A clip opened in the transform sheet. Identifiable so .sheet(item:) can drive it.
struct EditedText: Identifiable {
    let id = UUID()
    let text: String
}
