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
    let paused: Bool?
}

private struct ReceiveReply: Decodable {
    let enabled: Bool
}

final class ClipMonitor: ObservableObject {
    @Published var history: [Clip] = []
    @Published var pcStatus = "PC link: not connected"
    @Published var toast = ""
    /// The PC side switch: while paused the PC does not read, store or send its copies.
    @Published var pcPaused = false
    @Published var server: String { didSet { UserDefaults.standard.set(server, forKey: "server") } }
    @Published var token: String { didSet { UserDefaults.standard.set(token, forKey: "token") } }
    @Published var autoCopy: Bool { didSet { UserDefaults.standard.set(autoCopy, forKey: "autoCopy") } }
    @Published var activateOnPC: Bool { didSet { UserDefaults.standard.set(activateOnPC, forKey: "activateOnPC") } }

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
        activateOnPC = UserDefaults.standard.object(forKey: "activateOnPC") as? Bool ?? true
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([Clip].self, from: data) {
            history = saved
        }
        // Coming back to ClipPiP itself means the app a Shortcuts automation reported is no longer in front.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in ClipOrigin.clearCurrentApp("") }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
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

    /// Copy a history item to the phone clipboard, and put it on the PC clipboard too.
    func recopy(_ clip: Clip) {
        if clip.kind == "image", let id = clip.serverId {
            copyImage(path: "/clip/file?id=\(id)")
        } else {
            copyText(clip.text)
        }
        if let id = clip.serverId { activate(key: "h\(id)", sig: "") }
    }

    /// A tapped clip also becomes the PC clipboard. The PC already has the clip, so only its key is sent.
    func activate(key: String, sig: String) {
        guard activateOnPC else { return }
        post("/lib/activate", json: ["key": key, "sig": sig]) { [weak self] ok, _ in
            if !ok { self?.flash("Copied on the phone only (PC did not take it)") }
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
        let types = pb.types.joined(separator: ",")
        let hints = ClipOrigin.headers(for: pb)
        if pb.hasStrings, let s = pb.string, !s.isEmpty {
            let body = "text=" + Self.encode(s)
            send(Data(body.utf8), type: "application/x-www-form-urlencoded", label: s, kind: "text",
                 link: Self.sourceURL(pb), types: types, hints: hints)
        } else if pb.hasImages, let img = pb.image, let png = img.pngData() {
            send(png, type: "image/png", label: "[image \(png.count / 1024) KB]", kind: "image",
                 link: Self.sourceURL(pb), types: types, hints: hints)
        }
    }

    /// Where a copy came from. iOS never says which app copied, but a copy made in a browser carries
    /// the page inside a web archive, and a copied link or web image carries its own URL.
    private static func sourceURL(_ pb: UIPasteboard) -> String? {
        for type in ["com.apple.webarchive", "Apple Web Archive pasteboard type"] {
            guard let data = pb.data(forPasteboardType: type) else { continue }
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            if let root = plist as? [String: Any],
               let main = root["WebMainResource"] as? [String: Any],
               let url = main["WebResourceURL"] as? String,
               !url.isEmpty, !url.hasPrefix("about:") {
                return url
            }
        }
        if let data = pb.data(forPasteboardType: "public.html"),
           let html = String(data: data.prefix(200_000), encoding: .utf8),
           let start = html.range(of: "<!--source-url:"),
           let end = html.range(of: "-->", range: start.upperBound..<html.endIndex) {
            let url = String(html[start.upperBound..<end.lowerBound])
            if !url.isEmpty { return url }
        }
        if pb.hasURLs, let url = pb.url?.absoluteString { return url }
        return nil
    }

    /// Header values must be plain ASCII.
    private static func headerSafe(_ s: String, max: Int) -> String? {
        let allowed = CharacterSet(charactersIn: "!"..."~")
        guard let out = s.addingPercentEncoding(withAllowedCharacters: allowed), !out.isEmpty else { return nil }
        return String(out.prefix(max))
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    private func send(_ body: Data, type: String, label: String, kind: String, link: String?, types: String,
                      hints: [String: String]) {
        guard let url = serverURL("/set") else {
            record(label, "set the server URL first", fromPC: false, kind: kind); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        req.setValue(UIDevice.current.model, forHTTPHeaderField: "X-Device")
        if let link = link, let safe = Self.headerSafe(link, max: 2000) {
            req.setValue(safe, forHTTPHeaderField: "X-Clip-Url")
        }
        if let safe = Self.headerSafe(types, max: 900) {
            req.setValue(safe, forHTTPHeaderField: "X-Clip-Types")
        }
        // Which app the copy was made in, see ClipOrigin.
        for (name, value) in hints {
            if let safe = Self.headerSafe(value, max: name == "X-Clip-Probe" ? 2500 : 400) {
                req.setValue(safe, forHTTPHeaderField: name)
            }
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
        // wait=6: the server holds the request until the PC clipboard changes (long poll), so a PC copy
        // arrives in about 50 ms instead of waiting for the next 1 s tick. An older server ignores it.
        guard !polling, let url = serverURL("/poll?seq=\(pcSeq)&wait=6") else { return }
        polling = true
        let startedAt = Date()
        var req = URLRequest(url: url, timeoutInterval: 15)
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
                    let paused = r.paused ?? false
                    if self.pcPaused != paused { self.pcPaused = paused }
                    self.setPCStatus(paused ? "PC link: connected, PC clips are switched off" : "PC link: connected")
                    self.pcSeq = r.seq
                    if r.changed { self.received(r) }
                    // answered after a real wait or with a clip: ask again at once so nothing sits for a tick
                    if r.changed || Date().timeIntervalSince(startedAt) > 1.0 {
                        DispatchQueue.main.async { self.poll() }
                    }
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
        persist()
    }

    /// Remove a clip from the phone's list. Its copy on the PC is only hidden there, never erased.
    func remove(_ clip: Clip) {
        history.removeAll { $0.id == clip.id }
        persist()
        if let id = clip.serverId {
            post("/lib/delete", json: ["key": "h\(id)", "sig": ""]) { _, _ in }
        }
    }

    /// POST JSON to the server; the completion (success, server message) runs on the main thread.
    func post(_ path: String, json: [String: Any], done: @escaping (Bool, String) -> Void) {
        guard let url = serverURL(path), let body = try? JSONSerialization.data(withJSONObject: json) else {
            done(false, "no server"); return
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        session.dataTask(with: req) { data, resp, err in
            var message = err?.localizedDescription ?? ""
            if let data = data,
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let e = obj["error"] as? String {
                message = e
            }
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok, message) }
        }.resume()
    }

    /// Like post(), but hands back the decoded JSON body: the transform sheet needs the result.
    func postJSON(_ path: String, json: [String: Any],
                  done: @escaping (Bool, [String: Any]?, String) -> Void) {
        guard let url = serverURL(path), let body = try? JSONSerialization.data(withJSONObject: json) else {
            done(false, nil, "no server"); return
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        session.dataTask(with: req) { data, resp, err in
            var message = err?.localizedDescription ?? ""
            var obj: [String: Any]?
            if let data = data {
                obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let e = obj?["error"] as? String { message = e }
            }
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok, obj, message) }
        }.resume()
    }

    /// Switch PC clips on or off on the PC side. `mode` is "1", "0" or "toggle".
    func setPCReceive(_ mode: String) {
        fetch("/pc/receive?on=\(mode)") { [weak self] data, resp, _ in
            guard let self = self else { return }
            if let data = data, resp?.statusCode == 200,
               let r = try? JSONDecoder().decode(ReceiveReply.self, from: data) {
                self.pcPaused = !r.enabled
                self.flash(r.enabled ? "PC clips ON" : "PC clips OFF")
            } else {
                self.flash("PC server did not answer")
            }
        }
    }

    /// Hands the server URL and token to the ClipPiP keyboard through the clipboard (the keyboard picks it up
    /// the next time it opens). Not sent to the PC.
    func linkKeyboard() {
        let setup: [String: String] = ["server": server, "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: setup) else { return }
        copyText("clippip-setup:" + data.base64EncodedString(), quiet: true)
        flash("Now open the ClipPiP keyboard once")
    }

    private func persist() {
        let snapshot = history
        saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.historyURL, options: .atomic)
            }
        }
    }
}
