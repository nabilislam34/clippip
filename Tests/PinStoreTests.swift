import Foundation
import XCTest

/// Pinned clips: pin, unpin, order, the cap, and surviving a relaunch (a second store on the same defaults).
final class PinStoreTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "clippip.pins." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func pin(_ id: String, _ text: String = "x") -> Pin {
        Pin(id: id, kind: "text", text: text, name: "", img: nil, thumb: nil)
    }

    func testToggleAddsThenRemoves() {
        let store = PinStore(defaults: defaults)
        store.toggle(pin("h1"))
        XCTAssertTrue(store.isPinned("h1"))
        store.toggle(pin("h1"))
        XCTAssertFalse(store.isPinned("h1"))
        XCTAssertTrue(store.pins.isEmpty)
    }

    func testNewestFirstAndSurvivesARelaunch() {
        let store = PinStore(defaults: defaults)
        store.toggle(pin("h1", "one"))
        store.toggle(pin("h2", "日本語 two\nline"))
        XCTAssertEqual(store.pins.map { $0.id }, ["h2", "h1"])
        let again = PinStore(defaults: defaults)
        XCTAssertEqual(again.pins, store.pins)
        again.unpin("h2")
        XCTAssertEqual(PinStore(defaults: defaults).pins.map { $0.id }, ["h1"])
    }

    func testCapAndLongText() {
        let store = PinStore(defaults: defaults)
        for n in 0..<(PinStore.maxPins + 5) { store.toggle(pin("h\(n)")) }
        XCTAssertEqual(store.pins.count, PinStore.maxPins)
        XCTAssertEqual(store.pins.first?.id, "h\(PinStore.maxPins + 4)")
        store.toggle(pin("big", String(repeating: "a", count: PinStore.maxText + 10)))
        XCTAssertEqual(store.pins.first?.text.count, PinStore.maxText)
    }

    func testTextIdIsStable() {
        XCTAssertEqual(PinStore.textId("1girl, solo"), PinStore.textId("1girl, solo"))
        XCTAssertNotEqual(PinStore.textId("1girl, solo"), PinStore.textId("1girl, solo "))
        XCTAssertTrue(PinStore.textId("").hasPrefix("t:"))
    }
}
