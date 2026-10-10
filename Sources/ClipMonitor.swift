import UIKit

struct Clip: Identifiable {
    let id = UUID()
    let text: String
    let date: Date
    var note: String
    var fromPC: Bool
}

private struct PollResponse: Decodable {
    let seq: Int
    let changed: Bool
    let text: String?
}

final class ClipMonitor: ObservableObject {
    @Published var history: [Clip] = []
    @Published var pcStatus = "PC link: not connected"
    @Published var server: String { didSet { UserDefaults.standard.set(server, forKey: "server") } }
    @Published var token: String { didSet { UserDefaults.standard.set(token, forKey: "token") } }

    private var timer: Timer?
    private var pollTimer: Timer?
    private var lastChange = UIPasteboard.general.changeCount
    private var pcSeq = -1
    private var polling = false
    private var lastSentText: String?
    private let session = URLSession(configuration: .ephemeral)

    init() {
        server = UserDefaults.standard.string(forKey: "server") ?? ""
        token = UserDefaults.standard.string(forKey: "token") ?? ""
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let p = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(p, forMode: .common)
        pollTimer = p
    }

    /// Copy a history item to the phone clipboard without re-sending it to the PC.
    func recopy(_ clip: Clip) {
        UIPasteboard.general.string = clip.text
        lastChange = UIPasteboard.general.changeCount
        lastSentText = clip.text
    }

    // MARK: phone -> PC

    private func tick() {
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if pb.hasStrings, let s = pb.string, !s.isEmpty {
            lastSentText = s
            let body = "text=" + Self.encode(s)
            send(Data(body.utf8), type: "application/x-www-form-urlencoded", label: s)
        } else if pb.hasImages, let img = pb.image, let png = img.pngData() {
            send(png, type: "image/png", label: "[image \(png.count / 1024) KB]")
        }
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    private func endpoint(_ path: String, extra: String = "") -> URL? {
        guard !server.isEmpty else { return nil }
        let t = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: server + path + "?token=" + t + extra)
    }

    private func send(_ body: Data, type: String, label: String) {
        guard let url = endpoint("/set") else {
            record(label, "set the server URL first", fromPC: false); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        session.dataTask(with: req) { [weak self] _, resp, err in
            let note: String
            if let err = err { note = "failed: \(err.localizedDescription)" }
            else if let h = resp as? HTTPURLResponse { note = h.statusCode == 200 ? "sent" : "HTTP \(h.statusCode)" }
            else { note = "no response" }
            DispatchQueue.main.async { self?.record(label, note, fromPC: false) }
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }.resume()
    }

    // MARK: PC -> phone

    private func poll() {
        guard !polling, let url = endpoint("/poll", extra: "&seq=\(pcSeq)") else { return }
        polling = true
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        session.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polling = false
                if let err = err {
                    self.setPCStatus("PC link: \(err.localizedDescription)")
                } else if let h = resp as? HTTPURLResponse, h.statusCode == 401 {
                    self.setPCStatus("PC link: wrong token")
                } else if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                    self.setPCStatus("PC link: HTTP \(h.statusCode) (restart the PC server?)")
                } else if let data = data, let r = try? JSONDecoder().decode(PollResponse.self, from: data) {
                    self.setPCStatus("PC link: connected")
                    self.pcSeq = r.seq
                    if r.changed, let text = r.text, !text.isEmpty,
                       text != self.lastSentText, text != self.history.first(where: { $0.fromPC })?.text {
                        self.record(text, "from PC", fromPC: true)
                    }
                } else {
                    self.setPCStatus("PC link: bad reply (restart the PC server?)")
                }
            }
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }.resume()
    }

    private func setPCStatus(_ s: String) {
        if pcStatus != s { pcStatus = s }
    }

    private func record(_ text: String, _ note: String, fromPC: Bool) {
        history.insert(Clip(text: String(text.prefix(50000)), date: Date(), note: note, fromPC: fromPC), at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
    }
}
