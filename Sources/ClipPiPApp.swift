import SwiftUI
import AVFoundation

@main
struct ClipPiPApp: App {
    @StateObject private var pip = PiPManager.shared
    @StateObject private var monitor = ClipMonitor()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
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

struct ContentView: View {
    @EnvironmentObject var pip: PiPManager
    @EnvironmentObject var monitor: ClipMonitor

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("PC server")) {
                    TextField("http://<pc-ip>:5051", text: $monitor.server)
                        .autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                    TextField("token", text: $monitor.token)
                        .autocapitalization(.none).disableAutocorrection(true)
                }
                Section(header: Text("Background monitor")) {
                    PlayerHost(layer: pip.playerLayer).frame(height: 90)
                    Text(pip.status).font(.footnote)
                    Button(pip.pipActive ? "Stop PiP" : "Start PiP") {
                        pip.pipActive ? pip.stop() : pip.startIfNeeded()
                    }.disabled(!pip.pipPossible && !pip.pipActive)
                }
                Section(header: Text("Clips (tap to copy)"), footer: Text(monitor.pcStatus)) {
                    ForEach(monitor.history) { c in
                        Button { monitor.recopy(c) } label: {
                            VStack(alignment: .leading) {
                                Text(c.text).lineLimit(2)
                                Text(c.note).font(.caption)
                                    .foregroundColor(c.fromPC ? .blue : (c.note == "sent" ? .green : .red))
                            }
                        }
                    }
                }
            }
            .navigationTitle("ClipPiP")
        }
        .navigationViewStyle(.stack)
    }
}
