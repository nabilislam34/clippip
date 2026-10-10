import UIKit

struct Clip: Identifiable, Codable {
    var id = UUID()
    var text: String
    var date: Date
    var note: String
    var fromPC: Bool
    var kind = "text"       // "text" or "image"
    var serverId: Int?      // row id in the PC clip database; images are loaded from the PC by this id
}

private struct PollResponse: Decodable {
    let seq: Int
    let changed: Bool
    let text: String?
    let kind: String?
    let id: Int?
}

final class ClipMonitor: ObservableObject {
    @Published var history: [Clip] = []
    @Published var pcStatus = "PC link: not connected"
    @Published var toast = ""
    @Published var server: String { didSet { UserDefaults.standard.set(server, forKey: "server") } }
    @Published var token: String { didSet { UserDefaults.standard.set(token, forKey: "token") } }
    @Published var autoCopy: Bool { didSet { UserDefaults.standard.set(autoCopy, forKey: "autoCopy") } }

    private var timer: Timer?
    private var pollTimer: Timer?
    private var lastChange = UIPasteboard.general.changeCount
    private var pcSeq = -1
    private var polling = false
    private let session = URLSession(configuration: .ephemeral)
    private let saveQueue = DispatchQueue(label: "clippip.history")
    private static let maxHistory = 200

    private static let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        server = UserDefaults.standard.string(forKey: "server") ?? ""
        token = UserDefaults.standard.string(forKey: "token") ?? ""
        autoCopy = UserDefaults.standard.object(forKey: "autoCopy") as? Bool ?? true
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([Clip].self, from: data) {
            history = saved
        }
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

    // MARK: server access

    /// Full URL for a server path such as "/lib/tabs" or "/clip/file?id=3" (the token is added here).
    func serverURL(_ path: String) -> URL? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        let t = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: base + path + (path.contains("?") ? "&" : "?") + "token=" + t)
    }

    /// GET a server path; the completion runs on the main thread.
    func fetch(_ path: String, timeout: TimeInterval = 20,
               done: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        guard let url = serverURL(path) else { done(nil, nil, nil); return }
        session.dataTask(with: URLRequest(url: url, timeoutInterval: timeout)) { data, resp, err in
            DispatchQueue.main.async { done(data, resp as? HTTPURLResponse, err) }
        }.resume()
    }

    // MARK: copying to the phone clipboard (never re-sent to the PC)

    func copyText(_ text: String, quiet: Bool = false) {
        UIPasteboard.general.string = text
        lastChange = UIPasteboard.general.changeCount
        if !quiet { flash("Copied") }
    }

    func copyImage(path: String, quiet: Bool = false) {
        fetch(path, timeout: 60) { [weak self] data, resp, _ in
            guard let self = self else { return }
            guard let data = data, resp?.statusCode == 200, let img = UIImage(data: data) else {
                if !quiet { self.flash("Image not available (is the PC server reachable?)") }
                return
            }
            UIPasteboard.general.image = img
            self.lastChange = UIPasteboard.general.changeCount
            if !quiet { self.flash("Image copied") }
        }
    }

    /// Copy a history item to the phone clipboard.
    func recopy(_ clip: Clip) {
        if clip.kind == "image", let id = clip.serverId {
            copyImage(path: "/clip/file?id=\(id)")
        } else {
            copyText(clip.text)
        }
    }

    func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.toast == message { self?.toast = "" }
        }
    }

    // MARK: phone -> PC

    private func tick() {
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if pb.hasStrings, let s = pb.string, !s.isEmpty {
            let link = pb.hasURLs ? pb.url?.absoluteString : nil
            let body = "text=" + Self.encode(s)
            send(Data(body.utf8), type: "application/x-www-form-urlencoded", label: s, kind: "text", link: link)
        } else if pb.hasImages, let img = pb.image, let png = img.pngData() {
            send(png, type: "image/png", label: "[image \(png.count / 1024) KB]", kind: "image", link: nil)
        }
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    private func send(_ body: Data, type: String, label: String, kind: String, link: String?) {
        guard let url = serverURL("/set") else {
            record(label, "set the server URL first", fromPC: false, kind: kind); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        req.setValue(UIDevice.current.model, forHTTPHeaderField: "X-Device")
        if let link = link, link.count < 2000, link.canBeConverted(to: .ascii) {
            req.setValue(link, forHTTPHeaderField: "X-Clip-Url")
        }
        req.httpBody = body
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        session.dataTask(with: req) { [weak self] _, resp, err in
            let note: String
            var clipId: Int?
            if let err = err { note = "failed: \(err.localizedDescription)" }
            else if let h = resp as? HTTPURLResponse {
                note = h.statusCode == 200 ? "sent" : "HTTP \(h.statusCode)"
                clipId = h.value(forHTTPHeaderField: "X-Clip-Id").flatMap { Int($0) }
            }
            else { note = "no response" }
            DispatchQueue.main.async { self?.record(label, note, fromPC: false, kind: kind, serverId: clipId) }
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }.resume()
    }

    // MARK: PC -> phone

    private func poll() {
        guard !polling, let url = serverURL("/poll?seq=\(pcSeq)") else { return }
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
                    if r.changed { self.received(r) }
                } else {
                    self.setPCStatus("PC link: bad reply (restart the PC server?)")
                }
            }
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }.resume()
    }

    private func received(_ r: PollResponse) {
        if (r.kind ?? "text") == "image" {
            guard let id = r.id else { return }
            record("[image from PC]", "from PC", fromPC: true, kind: "image", serverId: id)
            if autoCopy { copyImage(path: "/clip/file?id=\(id)", quiet: true) }
        } else if let text = r.text, !text.isEmpty {
            // The server never sends back what this phone copied, so everything here is a real PC copy.
            record(text, "from PC", fromPC: true, serverId: r.id)
            if autoCopy { copyText(text, quiet: true) }
        }
    }

    private func setPCStatus(_ s: String) {
        if pcStatus != s { pcStatus = s }
    }

    private func record(_ text: String, _ note: String, fromPC: Bool, kind: String = "text", serverId: Int? = nil) {
        history.insert(Clip(text: String(text.prefix(50000)), date: Date(), note: note, fromPC: fromPC,
                            kind: kind, serverId: serverId), at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
        let snapshot = history
        saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.historyURL, options: .atomic)
            }
        }
    }
}
