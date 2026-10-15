import UIKit
import XCTest

/// Loads the keyboard view controller the way iOS does and checks that it gets a height and its controls.
final class KeyboardLayoutTests: XCTestCase {

    private func allViews(_ v: UIView) -> [UIView] {
        [v] + v.subviews.flatMap { allViews($0) }
    }

    func testKeyboardLoadsWithHeightAndToolbar() {
        let vc = KeyboardViewController()
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        vc.viewWillAppear(false)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()

        let heights = vc.view.constraints.filter { $0.firstAttribute == .height && $0.constant >= 250 }
        XCTAssertFalse(heights.isEmpty, "keyboard has no height constraint")

        let buttons = allViews(vc.view).compactMap { $0 as? UIButton }
        XCTAssertGreaterThanOrEqual(buttons.count, 8, "toolbar buttons missing")
        XCTAssertTrue(allViews(vc.view).contains { $0 is UITableView }, "clip list missing")
        let list = allViews(vc.view).compactMap { $0 as? UITableView }.first
        XCTAssertGreaterThan(list?.frame.height ?? 0, 60, "clip list has no room")
    }
}
