import Foundation
import XCTest

/// Sidebar order, pinned clips first, and the drag payloads of the Library.
final class TabOrderTests: XCTestCase {

    func testNoSavedOrderKeepsTheServerOrder() {
        XCTAssertEqual(TabOrder.apply(["a", "b", "c"], order: []), ["a", "b", "c"])
    }

    func testSavedOrderFirstNewTabsAtTheEnd() {
        XCTAssertEqual(TabOrder.apply(["a", "b", "c", "new"], order: ["c", "a", "b"]), ["c", "a", "b", "new"])
    }

    func testSavedIdsTheServerDroppedAreIgnored() {
        XCTAssertEqual(TabOrder.apply(["a", "c"], order: ["gone", "c", "a"]), ["c", "a"])
    }

    func testDuplicateIdsInTheSavedOrderUseTheFirst() {
        XCTAssertEqual(TabOrder.apply(["a", "b"], order: ["b", "a", "b"]), ["b", "a"])
    }

    func testMoveDownLandsAfterTheTarget() {
        XCTAssertEqual(TabOrder.move("a", onto: "c", in: ["a", "b", "c", "d"]), ["b", "c", "a", "d"])
    }

    func testMoveUpLandsBeforeTheTarget() {
        XCTAssertEqual(TabOrder.move("d", onto: "b", in: ["a", "b", "c", "d"]), ["a", "d", "b", "c"])
    }

    func testMoveOntoItselfOrAnUnknownTabChangesNothing() {
        XCTAssertEqual(TabOrder.move("a", onto: "a", in: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(TabOrder.move("x", onto: "a", in: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(TabOrder.move("a", onto: "x", in: ["a", "b"]), ["a", "b"])
    }

    func testPinnedFirstKeepsBothOrders() {
        let out = TabOrder.pinnedFirst([1, 2, 3, 4, 5]) { $0 % 2 == 0 }
        XCTAssertEqual(out, [2, 4, 1, 3, 5])
    }

    func testPayloadsRoundTrip() {
        XCTAssertEqual(TabOrder.parse(TabOrder.tabPayload("pr&ompt presets/uc")), .tab("pr&ompt presets/uc"))
        XCTAssertEqual(TabOrder.parse(TabOrder.clipPayload(key: "h12", sig: "")), .clip(key: "h12", sig: ""))
        XCTAssertEqual(TabOrder.parse(TabOrder.clipPayload(key: "c&clothes#3", sig: "ab12")),
                       .clip(key: "c&clothes#3", sig: "ab12"))
    }

    func testOrdinaryTextIsNotAPayload() {
        XCTAssertNil(TabOrder.parse("1girl, solo"))
        XCTAssertNil(TabOrder.parse("clippip-tab\n"))
        XCTAssertNil(TabOrder.parse("clippip-clip\nh1"))
    }

    func testDropTargets() {
        XCTAssertTrue(TabOrder.canDropClip(key: "h5", on: "history:ai:file paths"))
        XCTAssertFalse(TabOrder.canDropClip(key: "c&clothes#3", on: "history:ai:file paths"))
        XCTAssertTrue(TabOrder.canDropClip(key: "h5", on: "&clothes"))
        XCTAssertTrue(TabOrder.canDropClip(key: "d3553#9", on: "temp"))
        XCTAssertFalse(TabOrder.canDropClip(key: "h5", on: "history"))
        XCTAssertFalse(TabOrder.canDropClip(key: "h5", on: "history:ios"))
        XCTAssertFalse(TabOrder.canDropClip(key: "h5", on: "history:app:reddit"))
        XCTAssertFalse(TabOrder.canDropClip(key: "h5", on: "ditto:3553"))
        XCTAssertFalse(TabOrder.canDropClip(key: "h5", on: "*"))
    }
}
