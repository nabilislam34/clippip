import Foundation
import XCTest

/// Auto actions: underscore strip and character weight, and everything they must leave alone.
/// Cases come from real clips in the PC clip db and the CopyQ &clipboard tab.
final class AutoActionsTests: XCTestCase {

    private let chars: Set<String> = ["hatsune_miku", "reina_(tekken)", "mikasa_ackerman", "power_(chainsaw_man)"]

    private func fix(_ s: String, strip: Bool = true, weight: Bool = true) -> String {
        AutoActions.apply(s, chars: chars, strip: strip, weight: weight)
    }

    func testStripsTagsAndTagLists() {
        XCTAssertEqual(fix("long_hair"), "long hair")
        XCTAssertEqual(fix("long_hair, blue_eyes"), "long hair, blue eyes")
        XCTAssertEqual(fix("penis_in_another's_thighhigh"), "penis in another's thighhigh")
        XCTAssertEqual(fix("akutami_gege_(style)"), "akutami gege (style)")
        XCTAssertEqual(fix("x_x, smile_face, "), "x_x, smile face, ")   // spacing and emoticons kept
    }

    func testWeightsCharacters() {
        XCTAssertEqual(fix("hatsune_miku"), "1.5::hatsune miku::")
        XCTAssertEqual(fix("hatsune_miku, long_hair"), "1.5::hatsune miku::, long hair")
        XCTAssertEqual(fix("reina(tekken)"), "1.5::reina (tekken)::")
        XCTAssertEqual(fix("Reina (Tekken)"), "1.5::reina (tekken)::")
        XCTAssertEqual(fix("mikasa ackerman, shingeki no kyojin, "), "1.5::mikasa ackerman::, shingeki no kyojin, ")
        XCTAssertEqual(fix("power_(chainsaw_man), chainsaw man "), "1.5::power (chainsaw man)::, chainsaw man ")
    }

    func testEachToggleAlone() {
        XCTAssertEqual(fix("hatsune_miku, long_hair", strip: false), "1.5::hatsune miku::, long_hair")
        XCTAssertEqual(fix("hatsune_miku, long_hair", weight: false), "hatsune miku, long hair")
        XCTAssertEqual(fix("hatsune_miku", strip: false, weight: false), "hatsune_miku")
    }

    func testLeavesNonTagsAlone() {
        for s in ["IMG_8589", "SENTINEL_MUST_SURVIVE", "logs_2.sqlite", "img_0001.png", "C:\\a_b", "a_b/c_d",
                  "https://a.com/a_b", "1.5::hatsune miku::", "my_var = 3", "^_^", "link", "hello world",
                  "flamme (sousou no frieren)_pose_order_1792102902",
                  "30_mating press_1girl,_1.50__boa hancock__,__-2.0__artist collaboration__",
                  "clippip-setup:http://x?token=a_b", "line_one\nline_two",
                  "this is a whole sentence with words, and_one tag"] {
            XCTAssertEqual(fix(s), s, s)
        }
    }

    func testRunningTwiceChangesNothing() {
        for s in ["hatsune_miku", "long_hair, blue_eyes", "hatsune_miku, long_hair", "reina(tekken)", "x_x"] {
            XCTAssertEqual(fix(fix(s)), fix(s), s)
        }
    }
}
