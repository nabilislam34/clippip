import ObjectiveC
import UIKit

/// Works out which app a copy was made in. iOS has no public API for that, so three hints are sent
/// to the server with every clip and the server keeps the best one:
///   1. what iOS itself recorded as the copying app (private, may not be readable: then nothing is sent),
///   2. the app a Shortcuts automation said is open ("Set Current App" / "Clear Current App"),
///   3. the web sites named inside a copied web page fragment.
enum ClipOrigin {

    // MARK: 2. the app the Shortcuts automations reported

    static let appKey = "currentApp"
    static let appAtKey = "currentAppAt"
    /// A reported app is dropped after this long, in case its "is closed" automation never ran.
    static let maxAge: TimeInterval = 30 * 60

    static func setCurrentApp(_ name: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        let app = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { clearCurrentApp("", defaults: defaults); return }
        defaults.set(String(app.prefix(60)), forKey: appKey)
        defaults.set(now.timeIntervalSince1970, forKey: appAtKey)
    }

    /// Clears the reported app, but only when it is still `name`: going from Reddit to a browser runs
    /// "browser opened" and "Reddit closed" in either order. An empty name always clears.
    static func clearCurrentApp(_ name: String, defaults: UserDefaults = .standard) {
        let app = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = defaults.string(forKey: appKey) ?? ""
        guard app.isEmpty || current.caseInsensitiveCompare(String(app.prefix(60))) == .orderedSame else { return }
        defaults.removeObject(forKey: appKey)
        defaults.removeObject(forKey: appAtKey)
    }

    static func currentApp(defaults: UserDefaults = .standard, now: Date = Date()) -> String? {
        guard let app = defaults.string(forKey: appKey), !app.isEmpty else { return nil }
        let age = now.timeIntervalSince1970 - defaults.double(forKey: appAtKey)
        return age >= 0 && age <= maxAge ? app : nil
    }

    // MARK: 3. sites inside a copied web page fragment

    private static let hostPattern = try? NSRegularExpression(
        pattern: "(?:href|src)\\s*=\\s*[\"']https?://([^/\"'?#:\\s<>]+)", options: [.caseInsensitive])

    /// The distinct sites that links and images in the html point at, in order of appearance.
    static func hosts(inHTML html: String, limit: Int = 12) -> [String] {
        guard let pattern = hostPattern else { return [] }
        let text = html as NSString
        var out: [String] = []
        for match in pattern.matches(in: html, options: [], range: NSRange(location: 0, length: text.length)) {
            let host = text.substring(with: match.range(at: 1)).lowercased()
            if !host.isEmpty, !out.contains(host) { out.append(host) }
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: 1. what iOS recorded (private)

    // New key names in 1.7: an "off" left behind by the old lookup must not switch this one off.
    static let busyKey = "originLookupBusy2"
    static let offKey = "originLookupOff2"
    /// The description is sent with the first few clips of a launch, so one lost request does not lose it.
    static var probesLeft = 3
    /// A lookup slower than this turns the lookup off: it runs on the main thread with every copy.
    static let slowLimit: TimeInterval = 1.0
    private static let generalName = "com.apple.UIKit.pboard.general"

    /// The clipboard's item collection (PBItemCollection), asked from the system clipboard service the
    /// way UIKit does it itself. UIPasteboard keeps no reference to it, so it cannot be read off `pb`.
    private static func collection(named name: String) -> NSObject? {
        guard let cls = NSClassFromString("PBServerConnection"),
              let meta = cls as AnyObject as? NSObjectProtocol else { return nil }
        let make = NSSelectorFromString("defaultConnection")
        guard meta.responds(to: make),
              let connection = meta.perform(make)?.takeUnretainedValue() as? NSObject else { return nil }
        let ask = NSSelectorFromString("pasteboardWithName:error:")
        guard connection.responds(to: ask) else { return nil }
        return connection.perform(ask, with: name as NSString, with: nil)?.takeUnretainedValue() as? NSObject
    }

    private static let bundleGetters = ["originatorBundleID", "_originatorBundleID", "originatorBundleIdentifier"]
    private static let nameGetters = ["originatorLocalizedName", "_originatorLocalizedName", "originatorName"]
    private static let probeWords = ["origin", "collection", "bundle", "source", "owner", "remote", "metadata"]

    /// Calls a getter only when the object really has it, it takes no arguments and it returns an object.
    private static func object(_ target: NSObject, _ getter: String) -> NSObject? {
        let sel = NSSelectorFromString(getter)
        guard target.responds(to: sel),
              let cls = object_getClass(target),
              let method = class_getInstanceMethod(cls, sel),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let returns = method_copyReturnType(method)
        defer { free(returns) }
        guard returns.pointee == 64 else { return nil }      // 64 is "@", an object
        return target.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    private static func text(_ target: NSObject, _ getters: [String]) -> String? {
        for getter in getters {
            if let value = object(target, getter) as? NSString, value.length > 0 { return value as String }
        }
        return nil
    }

    /// Method and stored field names of a class (and its parents up to NSObject) that contain a probe word.
    private static func names(of start: AnyClass?, extraWords: [String] = []) -> [String] {
        let words = probeWords + extraWords
        var out: [String] = []
        var cls: AnyClass? = start
        var depth = 0
        while let c = cls, c != NSObject.self, depth < 4 {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(c, &count) {
                for i in 0..<Int(count) { out.append(NSStringFromSelector(method_getName(methods[i]))) }
                free(methods)
            }
            count = 0
            if let ivars = class_copyIvarList(c, &count) {
                for i in 0..<Int(count) {
                    if let name = ivar_getName(ivars[i]) { out.append("iv:" + String(cString: name)) }
                }
                free(ivars)
            }
            cls = class_getSuperclass(c)
            depth += 1
        }
        var seen = Set<String>()
        return out.filter { name in
            let low = name.lowercased()
            return words.contains { low.contains($0) } && seen.insert(name).inserted
        }
    }

    /// The copying app as iOS recorded it, plus (once per launch) a description of what the clipboard
    /// object offers, so a wrong guess at the private names can be corrected from the server log.
    /// If the app died inside this code last time, it turns itself off for good.
    static func origin(_ pb: UIPasteboard, defaults: UserDefaults = .standard)
        -> (bundle: String?, name: String?, probe: String?) {
        if defaults.bool(forKey: busyKey) {
            defaults.set(true, forKey: offKey)
            defaults.set(false, forKey: busyKey)
        }
        if defaults.bool(forKey: offKey) {
            let note: String? = probesLeft > 0 ? "off: stopped inside the origin lookup last time" : nil
            probesLeft -= 1
            return (nil, nil, note)
        }
        defaults.set(true, forKey: busyKey)
        defaults.synchronize()
        defer {
            defaults.set(false, forKey: busyKey)
            defaults.synchronize()
        }

        var targets: [NSObject] = [pb]
        let board = pb.name.rawValue.isEmpty ? generalName : pb.name.rawValue
        let began = Date()
        if let found = collection(named: board) { targets.append(found) }
        let took = Date().timeIntervalSince(began)
        if took > slowLimit { defaults.set(true, forKey: offKey) }
        var bundle: String?
        var name: String?
        for target in targets {
            if bundle == nil { bundle = text(target, bundleGetters) }
            if name == nil { name = text(target, nameGetters) }
        }

        var probe: String?
        if probesLeft > 0 {
            probesLeft -= 1
            var parts = ["ios=" + UIDevice.current.systemVersion,
                         "conn=" + (NSClassFromString("PBServerConnection") == nil ? "missing" : "ok"),
                         "board=" + board, "ms=" + String(Int(took * 1000)),
                         "pb=" + NSStringFromClass(object_getClass(pb) ?? UIPasteboard.self),
                         "found=" + (bundle ?? "-") + "/" + (name ?? "-"),
                         "m=" + names(of: object_getClass(pb)).joined(separator: ",")]
            if targets.count > 1 {
                parts.append("col=" + NSStringFromClass(object_getClass(targets[1]) ?? NSObject.self))
                parts.append("cm=" + names(of: object_getClass(targets[1]), extraWords: ["name", "team"])
                    .joined(separator: ","))
            }
            probe = String(parts.joined(separator: ";").prefix(2400))
        }
        return (bundle, name, probe)
    }

    // MARK: everything together

    /// Extra request headers for a clip that was just copied on the phone.
    static func headers(for pb: UIPasteboard, defaults: UserDefaults = .standard) -> [String: String] {
        var out: [String: String] = [:]
        if let app = currentApp(defaults: defaults) { out["X-Clip-App"] = app }
        if let data = pb.data(forPasteboardType: "public.html") {
            let found = hosts(inHTML: String(decoding: data.prefix(200_000), as: UTF8.self))
            if !found.isEmpty { out["X-Clip-Hosts"] = found.joined(separator: ",") }
        }
        let recorded = origin(pb, defaults: defaults)
        if let bundle = recorded.bundle { out["X-Clip-Origin"] = bundle }
        if let name = recorded.name { out["X-Clip-Origin-Name"] = name }
        if let probe = recorded.probe { out["X-Clip-Probe"] = probe }
        return out
    }
}
