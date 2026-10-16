import Foundation
import XCTest

/// Multi-select output, the Clips tab search, and the clip-menu transform pins.
final class ClipBatchTests: XCTestCase {

    func testRandomizerKeepsEachClipAsOneOption() {
        XCTAssertEqual(ClipBatch.randomizer(["red hair, long hair", "blue hair"]), "||red hair, long hair|blue hair||")
    }

    func testRandomizerFlattensLinesAndUnwrapsOldRandomizers() {
        XCTAssertEqual(ClipBatch.randomizer(["a,\nb", "||c|d||", "  ", "e"]), "||a, b|c|d|e||")
        XCTAssertEqual(ClipBatch.randomizer([]), "")
        XCTAssertEqual(ClipBatch.randomizer(["日本 タグ"]), "||日本 タグ||")
    }

    func testJoinedIsOneClipPerLine() {
        XCTAssertEqual(ClipBatch.joined([" a ", "", "b\n"]), "a\nb")
    }

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func hit(_ q: String, date: Date? = nil, note: String = "sent", text: String = "1girl, solo") -> Bool {
        ClipSearch.matches(text: text, note: note, date: date ?? day(2026, 10, 15), query: q,
                           now: day(2026, 10, 15, 18), calendar: cal)
    }

    func testDateWords() {
        XCTAssertTrue(hit("today"))
        XCTAssertFalse(hit("today", date: day(2026, 10, 14)))
        XCTAssertTrue(hit("yesterday", date: day(2026, 10, 14)))
        XCTAssertTrue(hit("2026-10-15"))
        XCTAssertFalse(hit("2026-10-16"))
        XCTAssertTrue(hit("2026-10"))
        XCTAssertTrue(hit("10-15"))
        XCTAssertTrue(hit("10/15"))
        XCTAssertFalse(hit("10-14"))
    }

    func testAppAndTextWords() {
        XCTAssertTrue(hit("app:chrome", note: "from PC chrome.exe"))
        XCTAssertFalse(hit("app:chrome", note: "sent"))
        XCTAssertTrue(hit("solo today"))
        XCTAssertFalse(hit("solo yesterday"))
        XCTAssertTrue(hit(""))
        XCTAssertTrue(hit("s-123", text: "x s-1234567.png"))     // not a date: plain text match
    }

    func testMenuTransformPins() {
        let d = UserDefaults(suiteName: "clipbatch-test-\(UUID().uuidString)")!
        let store = MenuTransformStore(defaults: d)
        store.toggle(id: "weight1", label: "1.0::")
        store.toggle(id: "neg2", label: "-2::")
        XCTAssertEqual(store.pinned.map { $0.id }, ["weight1", "neg2"])
        store.toggle(id: "weight1", label: "1.0::")
        XCTAssertEqual(store.pinned.map { $0.id }, ["neg2"])
        XCTAssertEqual(MenuTransformStore(defaults: d).pinned.map { $0.id }, ["neg2"])   // saved
    }
}
