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
                    if url.host == "start" { pip.requestStart() }
                    else if url.host == "stop" { pip.stop() }
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
                }
                Section(header: Text("Clips (tap to copy, hold to preview)"),
                        footer: Text("\(monitor.pcStatus)\nClipPiP \(Self.version)")) {
                    ForEach(monitor.history) { c in
                        row(c)
                    }
                }
            }
            .navigationTitle("ClipPiP")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .sheet(item: $open) { FullClipSheet(clip: $0) }
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
                       })
    }
}
