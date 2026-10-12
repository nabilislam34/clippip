import Foundation

/// Selecting text with a thumb is clumsy, so the transform sheet offers "Line" and
/// "Tag" buttons instead. Both are pure functions of (text, caret) so they can be
/// tested without a server, a clipboard or a view.
enum PromptSelection {

    /// The line the caret sits in, without its trailing newline.
    static func line(in text: String, caret: Int) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let at = max(0, min(caret, ns.length - 1))
        var r = ns.lineRange(for: NSRange(location: at, length: 0))
        while r.length > 0, ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1)) == "\n" {
            r.length -= 1
        }
        return r.length > 0 ? r : nil
    }

    /// The comma or newline separated tag the caret sits in, without the padding.
    static func tag(in text: String, caret: Int) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let at = max(0, min(caret, ns.length - 1))
        let breaks: Set<Character> = [",", "\n"]

        func char(_ i: Int) -> Character? {
            guard i >= 0, i < ns.length else { return nil }
            return ns.substring(with: NSRange(location: i, length: 1)).first
        }

        var start = at
        while start > 0, let c = char(start - 1), !breaks.contains(c) { start -= 1 }
        var end = at
        while end < ns.length, let c = char(end), !breaks.contains(c) { end += 1 }
        while start < end, char(start) == " " { start += 1 }
        while end > start, char(end - 1) == " " { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}

/// Which transforms this phone uses most, so the sheet can put them first.
/// Counts live in UserDefaults only: a wrong count is cosmetic, never data loss.
enum TransformFavourites {
    static let key = "transformUses"
    static let keep = 40          // the cache is trimmed to this, so it cannot grow forever
    static let trimAt = 60

    static func counts(_ store: UserDefaults = .standard) -> [String: Int] {
        (store.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    static func bump(_ id: String, store: UserDefaults = .standard) {
        var c = counts(store)
        c[id, default: 0] += 1
        if c.count > trimAt {
            let kept = c.sorted { $0.value > $1.value }.prefix(keep).map { ($0.key, $0.value) }
            c = Dictionary(uniqueKeysWithValues: kept)
        }
        store.set(c, forKey: key)
    }

    /// The most used ids, most used first; ties break on the id so the order is stable.
    static func top(_ ids: [String], limit: Int = 5, store: UserDefaults = .standard) -> [String] {
        let c = counts(store)
        return ids.filter { (c[$0] ?? 0) > 0 }
            .sorted { a, b in
                let (ca, cb) = (c[a] ?? 0, c[b] ?? 0)
                return ca == cb ? a < b : ca > cb
            }
            .prefix(limit)
            .map { $0 }
    }
}
