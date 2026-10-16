import Combine
import Foundation

/// Transforms the user pinned to the clip long-press menu (pin them in the Edit prompt sheet:
/// hold a transform button > Pin to clip menu). Kept with their label, so the menu needs no fetch.
struct MenuTransform: Codable, Equatable, Identifiable {
    let id: String
    let label: String
}

final class MenuTransformStore: ObservableObject {
    static let shared = MenuTransformStore()
    static let maxPinned = 12
    private static let key = "menuTransforms"

    @Published private(set) var pinned: [MenuTransform] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([MenuTransform].self, from: data) {
            pinned = saved
        }
    }

    func isPinned(_ id: String) -> Bool { pinned.contains { $0.id == id } }

    func toggle(id: String, label: String) {
        if isPinned(id) {
            pinned.removeAll { $0.id == id }
        } else {
            pinned.append(MenuTransform(id: id, label: label))
            if pinned.count > Self.maxPinned { pinned.removeFirst(pinned.count - Self.maxPinned) }
        }
        if let data = try? JSONEncoder().encode(pinned) { defaults.set(data, forKey: Self.key) }
    }
}

/// What several selected clips become.
enum ClipBatch {
    /// One clip per line, in the order shown.
    static func joined(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// NovelAI randomizer: each clip is ONE option (its own commas kept, its line breaks become ", ").
    /// "||a, b|c||" picks either "a, b" or "c". A clip that already is a randomizer is unwrapped first.
    static func randomizer(_ texts: [String]) -> String {
        let options = texts.compactMap { raw -> String? in
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("||") && t.hasSuffix("||") && t.count >= 4 {
                t = String(t.dropFirst(2).dropLast(2))
            }
            let flat = t.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,")) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return flat.isEmpty ? nil : flat
        }
        return options.isEmpty ? "" : "||" + options.joined(separator: "|") + "||"
    }
}

/// The Clips tab search. Every word must match: "today", "yesterday", a date ("2026-10-15", "2026-10",
/// "10-15", "10/15") matches the clip's day, "app:chrome" matches only the source, anything else the text or note.
enum ClipSearch {
    static func matches(text: String, note: String, date: Date, query: String,
                        now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let hay = (text + " " + note).lowercased()
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return words.allSatisfy { w in
            if w == "today" { return calendar.isDate(date, inSameDayAs: now) }
            if w == "yesterday", let y = calendar.date(byAdding: .day, value: -1, to: now) {
                return calendar.isDate(date, inSameDayAs: y)
            }
            if w.hasPrefix("app:"), w.count > 4 { return note.lowercased().contains(w.dropFirst(4)) }
            let nums = w.split(whereSeparator: { $0 == "-" || $0 == "/" }).map { Int($0) }
            if nums.count >= 2, nums.count <= 3, !nums.contains(nil), !w.contains(where: { $0.isLetter }) {
                let n = nums.map { $0! }
                if n.count == 3 { return day.year == n[0] && day.month == n[1] && day.day == n[2] }
                if n[0] > 31 { return day.year == n[0] && day.month == n[1] }          // 2026-10
                if (1...12).contains(n[0]) && (1...31).contains(n[1]) { return day.month == n[0] && day.day == n[1] }
            }
            return hay.contains(w)
        }
    }
}
