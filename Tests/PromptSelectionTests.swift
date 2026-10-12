import Foundation
import XCTest

/// The transform sheet's selection helpers and its favourites cache. Both are pure
/// (or UserDefaults only), so they run without a server, a clipboard or a view.
final class PromptSelectionTests: XCTestCase {

    private func picked(_ text: String, _ r: NSRange?) -> String? {
        guard let r = r else { return nil }
        return (text as NSString).substring(with: r)
    }

    // MARK: line

    func testLinePicksTheCaretsLine() {
        let t = "1girl, solo\nmakise kurisu\nsmile"
        XCTAssertEqual(picked(t, PromptSelection.line(in: t, caret: 0)), "1girl, solo")
        XCTAssertEqual(picked(t, PromptSelection.line(in: t, caret: 15)), "makise kurisu")
        XCTAssertEqual(picked(t, PromptSelection.line(in: t, caret: t.utf16.count - 1)), "smile")
    }

    func testLineDropsTheTrailingNewline() {
        let t = "1girl\nsolo\n"
        XCTAssertEqual(picked(t, PromptSelection.line(in: t, caret: 2)), "1girl")
        XCTAssertFalse((picked(t, PromptSelection.line(in: t, caret: 7)) ?? "").hasSuffix("\n"))
    }

    func testLineHandlesEmptyAndOutOfRange() {
        XCTAssertNil(PromptSelection.line(in: "", caret: 0))
        let t = "1girl"
        XCTAssertEqual(picked(t, PromptSelection.line(in: t, caret: 999)), "1girl")
        XCTAssertEqual(picked(t, PromptSelection.line(in: t, caret: -5)), "1girl")
    }

    func testLineOfABlankLineIsNil() {
        let t = "1girl\n\nsolo"
        XCTAssertNil(PromptSelection.line(in: t, caret: 6))
    }

    // MARK: tag

    func testTagPicksTheCaretsTag() {
        let t = "1girl, makise kurisu, long hair"
        XCTAssertEqual(picked(t, PromptSelection.tag(in: t, caret: 0)), "1girl")
        XCTAssertEqual(picked(t, PromptSelection.tag(in: t, caret: 10)), "makise kurisu")
        XCTAssertEqual(picked(t, PromptSelection.tag(in: t, caret: 25)), "long hair")
    }

    func testTagExcludesThePaddingAndTheCommas() {
        let t = "1girl,    solo   , smile"
        let r = PromptSelection.tag(in: t, caret: 11)
        XCTAssertEqual(picked(t, r), "solo")
        XCTAssertEqual(r?.location, 10)
    }

    func testTagStopsAtNewlines() {
        let t = "0.6::sciamano240::\n1girl, solo"
        XCTAssertEqual(picked(t, PromptSelection.tag(in: t, caret: 3)), "0.6::sciamano240::")
        XCTAssertEqual(picked(t, PromptSelection.tag(in: t, caret: 20)), "1girl")
    }

    func testTagKeepsWeightAndPrefixSyntax() {
        let t = "1.2::source#ass grab::, kissing"
        XCTAssertEqual(picked(t, PromptSelection.tag(in: t, caret: 5)), "1.2::source#ass grab::")
    }

    func testTagHandlesEmptyAndSeparatorOnly() {
        XCTAssertNil(PromptSelection.tag(in: "", caret: 0))
        XCTAssertNil(PromptSelection.tag(in: ",,,", caret: 1))
        XCTAssertNil(PromptSelection.tag(in: "1girl,   , solo", caret: 7))
    }

    func testTagHandlesNonAscii() {
        let t = "\u{521D}\u{97F3}\u{30DF}\u{30AF}, smile"
        XCTAssertEqual(picked(t, PromptSelection.tag(in: t, caret: 1)), "\u{521D}\u{97F3}\u{30DF}\u{30AF}")
    }

    // MARK: favourites

    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "clippip.tests." + name)!
        d.removePersistentDomain(forName: "clippip.tests." + name)
        return d
    }

    func testTopIsMostUsedFirst() {
        let d = scratchDefaults(#function)
        TransformFavourites.bump("weight1", store: d)
        TransformFavourites.bump("weight1", store: d)
        TransformFavourites.bump("pipesWrap", store: d)
        XCTAssertEqual(TransformFavourites.top(["pipesWrap", "weight1", "neg2"], store: d),
                       ["weight1", "pipesWrap"])
    }

    func testTopSkipsUnusedAndRespectsTheLimit() {
        let d = scratchDefaults(#function)
        for id in ["a", "b", "c", "d", "e", "f", "g"] { TransformFavourites.bump(id, store: d) }
        let top = TransformFavourites.top(["a", "b", "c", "d", "e", "f", "g", "unused"], limit: 5, store: d)
        XCTAssertEqual(top.count, 5)
        XCTAssertFalse(top.contains("unused"))
    }

    func testTopIsEmptyBeforeAnythingIsUsed() {
        let d = scratchDefaults(#function)
        XCTAssertTrue(TransformFavourites.top(["weight1", "neg2"], store: d).isEmpty)
    }

    func testCountsAreTrimmedAndNeverGrowWithoutBound() {
        let d = scratchDefaults(#function)
        for i in 0..<80 {
            TransformFavourites.bump("id\(i)", store: d)
            if i % 3 == 0 { TransformFavourites.bump("id\(i)", store: d) }
        }
        XCTAssertLessThanOrEqual(TransformFavourites.counts(d).count, TransformFavourites.trimAt)
    }
}
