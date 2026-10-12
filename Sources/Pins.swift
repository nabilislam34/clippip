import Combine
import Foundation

/// A clip the user pinned. The pin is a copy kept on the phone, so a pinned text clip still works
/// when the PC is off (a pinned image is loaded from the PC by its path).
struct Pin: Codable, Identifiable, Equatable {
    /// The Library key of the clip ("h12", a CopyQ or Ditto key), or "t:<hash>" for a clip with no PC row.
    let id: String
    var kind: String
    var text: String
    var name: String
    var img: String?
    var thumb: String?
}

/// The pinned clips, newest first, kept in UserDefaults. No timers, no network.
final class PinStore: ObservableObject {
    static let shared = PinStore()
    static let maxPins = 100
    static let maxText = 50_000
    private static let key = "pinnedClips"

    @Published private(set) var pins: [Pin] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Pin].self, from: data) {
            pins = saved
        }
    }

    func isPinned(_ id: String) -> Bool {
        pins.contains { $0.id == id }
    }

    /// Pins the clip, or unpins it when it is already pinned.
    func toggle(_ pin: Pin) {
        if isPinned(pin.id) {
            unpin(pin.id)
            return
        }
        var kept = pin
        kept.text = String(pin.text.prefix(Self.maxText))
        pins.insert(kept, at: 0)
        if pins.count > Self.maxPins { pins.removeLast(pins.count - Self.maxPins) }
        save()
    }

    func unpin(_ id: String) {
        pins.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: Self.key) }
    }

    /// A stable id for a clip that has no PC row (the same text always gives the same id).
    static func textId(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "t:" + String(hash, radix: 16)
    }
}
