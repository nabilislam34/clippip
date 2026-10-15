import Foundation
import XCTest

/// The age badge on a clip card.
final class RelativeTimeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ seconds: TimeInterval) -> String {
        RelativeTime.short(now.addingTimeInterval(-seconds), now: now)
    }

    func testSecondsMinutesHours() {
        XCTAssertEqual(ago(0), "now")
        XCTAssertEqual(ago(59), "now")
        XCTAssertEqual(ago(60), "1m")
        XCTAssertEqual(ago(125), "2m")
        XCTAssertEqual(ago(3599), "59m")
        XCTAssertEqual(ago(3600), "1h")
        XCTAssertEqual(ago(86399), "23h")
    }

    func testDaysUseTheWeekdayThenTheDate() {
        XCTAssertEqual(ago(2 * 86400).count, 3)                 // "Tue"
        XCTAssertTrue(ago(30 * 86400).contains(" "))            // "Oct 3"
    }

    func testAClockThatRanBackwardsIsNow() {
        XCTAssertEqual(ago(-500), "now")
    }
}
