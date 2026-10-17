import Foundation

/// Fixes applied to a copied clip before it is kept or sent (Settings > Auto actions):
/// danbooru tags lose their underscores (`long_hair, blue_eyes` -> `long hair, blue eyes`) and
/// character tags get weighted (`hatsune_miku` -> `1.5::hatsune miku::`).
/// Anything that looks like a path, url, filename, code or an already weighted prompt is left alone.
enum AutoActions {

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    // `__` and long digit runs: NAI gen filenames. Lowercase-dot-letter: file extensions and domains.
    private static let skip = re(#"__|\d{6,}|://|[/\\@{}\[\]<>=;"`]|::|[A-Za-z0-9]\.[A-Za-z]|^clippip-setup:"#)
    private static let parenNoSpace = re(#"(?<=[^\s_])\("#)
    private static let spaces = re(#"\s+"#)
    // Only an underscore between letters/digits (or after a paren): `^_^`, `>_<`, `x_x` keep theirs.
    private static let underscore = re(#"(?<=[A-Za-z0-9])_(?=[A-Za-z0-9(])|(?<=\))_(?=[A-Za-z0-9])"#)

    private static func sub(_ r: NSRegularExpression, _ s: String, _ with: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    /// The danbooru spelling of a tag: `Reina(Tekken)` / `reina \(tekken\)` -> `reina_(tekken)`.
    static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        t = t.replacingOccurrences(of: "\\(", with: "(").replacingOccurrences(of: "\\)", with: ")")
        t = sub(parenNoSpace, t, "_(")
        return sub(spaces, t, "_")
    }

    static func apply(_ text: String, chars: Set<String>, strip: Bool, weight: Bool) -> String {
        guard strip || weight, !text.isEmpty, text.count <= 4000,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n"),
              skip.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else { return text }
        let parts = text.components(separatedBy: ",")
        let tags = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // tag-sized pieces only: a sentence with commas is not a tag list
        if tags.contains(where: { $0.count > 60 || $0.split(whereSeparator: { $0.isWhitespace }).count > 4 }) {
            return text
        }
        // a lone word with no `_` or `(` is just a word (link, alice), never a tag copy
        if tags.count == 1, !tags[0].contains("_"), !tags[0].contains("(") { return text }
        let out = parts.enumerated().map { i, part -> String in
            let t = tags[i]
            guard !t.isEmpty else { return part }
            let lead = String(part.prefix(while: { $0.isWhitespace }))
            let tail = String(part.reversed().prefix(while: { $0.isWhitespace }).reversed())
            let n = normalize(t)
            if weight, chars.contains(n) {
                return lead + "1.5::" + n.replacingOccurrences(of: "_", with: " ") + "::" + tail
            }
            // danbooru tags are lowercase: IMG_8589 / SOME_CONSTANT are not tags
            if strip, t.count > 3, t == t.lowercased() { return lead + sub(underscore, t, " ") + tail }
            return part
        }
        return out.joined(separator: ",")
    }
}

/// The bundled danbooru + waifulist character tags (123k), loaded once off the main thread.
/// Until it is loaded, clips pass through unweighted.
final class CharacterTags {
    static let shared = CharacterTags()
    private let lock = NSLock()
    private var loaded: Set<String>?
    private var loading = false

    var tags: Set<String>? {
        lock.lock(); defer { lock.unlock() }
        if loaded == nil && !loading {
            loading = true
            DispatchQueue.global(qos: .utility).async { self.load() }
        }
        return loaded
    }

    private func load() {
        var set = Set<String>()
        if let url = Bundle.main.url(forResource: "character_tags", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            set = Set(text.components(separatedBy: .newlines).filter { !$0.isEmpty })
        }
        lock.lock(); loaded = set; lock.unlock()
    }
}
