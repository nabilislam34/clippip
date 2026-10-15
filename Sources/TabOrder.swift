import Foundation

/// The Library sidebar order the user set by dragging tabs, and the other small pure helpers of the
/// Library (pinned clips first, what a drag carries). No UI here, so the tests can run it directly.
enum TabOrder {
    /// `ids` in the user's order: ids found in `order` come first in that order, every other id keeps
    /// its server position after them (a tab the PC adds later shows up at the end).
    static func apply(_ ids: [String], order: [String]) -> [String] {
        var rank: [String: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }
        return ids.enumerated()
            .sorted { a, b in
                (rank[a.element] ?? order.count + a.offset) < (rank[b.element] ?? order.count + b.offset)
            }
            .map { $0.element }
    }

    /// Drop tab `id` on tab `target`: dragged down it lands after the target, dragged up before it.
    static func move(_ id: String, onto target: String, in ids: [String]) -> [String] {
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return ids }
        var out = ids
        out.remove(at: from)
        out.insert(id, at: to)      // after the removal, index `to` is right after the target when moving down
        return out
    }

    /// Pinned clips first, each group keeps its own order.
    static func pinnedFirst<T>(_ items: [T], isPinned: (T) -> Bool) -> [T] {
        items.filter(isPinned) + items.filter { !isPinned($0) }
    }

    // What a drag carries, as plain text: "clippip-tab\n<id>" or "clippip-clip\n<key>\n<sig>".
    static func tabPayload(_ id: String) -> String { "clippip-tab\n" + id }
    static func clipPayload(key: String, sig: String) -> String { "clippip-clip\n" + key + "\n" + sig }

    enum Drop: Equatable {
        case tab(String)
        case clip(key: String, sig: String)
    }

    static func parse(_ payload: String) -> Drop? {
        let parts = payload.components(separatedBy: "\n")
        if parts.count == 2, parts[0] == "clippip-tab", !parts[1].isEmpty { return .tab(parts[1]) }
        if parts.count == 3, parts[0] == "clippip-clip", !parts[1].isEmpty { return .clip(key: parts[1], sig: parts[2]) }
        return nil
    }

    /// Where a clip from the Library can be dropped: history clips onto "ai ..." tabs (moved there),
    /// any text or image clip onto a CopyQ tab (a copy is added). The fixed history views and Ditto are not targets.
    static func canDropClip(key: String, on tab: String) -> Bool {
        if tab.hasPrefix("history:ai:") { return key.hasPrefix("h") }
        if tab == "history" || tab.hasPrefix("history:") || tab.hasPrefix("ditto:") || tab == "*" { return false }
        return true
    }
}
