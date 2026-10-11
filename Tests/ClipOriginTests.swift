import UIKit
import XCTest

/// The "which app was this copied in" hints: the app reported by Shortcuts automations,
/// the sites inside a copied page fragment, and the private origin lookup staying harmless.
final class ClipOriginTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "clippip.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testSetThenReadCurrentApp() {
        XCTAssertNil(ClipOrigin.currentApp(defaults: defaults))
        ClipOrigin.setCurrentApp("  Reddit \n", defaults: defaults)
        XCTAssertEqual(ClipOrigin.currentApp(defaults: defaults), "Reddit")
    }

    func testClearOnlyClearsTheSameApp() {
        ClipOrigin.setCurrentApp("Brave", defaults: defaults)
        ClipOrigin.clearCurrentApp("Reddit", defaults: defaults)       // Reddit closed after Brave opened
        XCTAssertEqual(ClipOrigin.currentApp(defaults: defaults), "Brave")
        ClipOrigin.clearCurrentApp("brave", defaults: defaults)
        XCTAssertNil(ClipOrigin.currentApp(defaults: defaults))
    }

    func testEmptyNameAlwaysClears() {
        ClipOrigin.setCurrentApp("Reddit", defaults: defaults)
        ClipOrigin.clearCurrentApp("", defaults: defaults)
        XCTAssertNil(ClipOrigin.currentApp(defaults: defaults))
        ClipOrigin.setCurrentApp("Reddit", defaults: defaults)
        ClipOrigin.setCurrentApp("   ", defaults: defaults)
        XCTAssertNil(ClipOrigin.currentApp(defaults: defaults))
    }

    func testReportedAppGoesStale() {
        let start = Date()
        ClipOrigin.setCurrentApp("Reddit", defaults: defaults, now: start)
        XCTAssertEqual(ClipOrigin.currentApp(defaults: defaults, now: start.addingTimeInterval(29 * 60)), "Reddit")
        XCTAssertNil(ClipOrigin.currentApp(defaults: defaults, now: start.addingTimeInterval(31 * 60)))
    }

    func testLongAndNonAsciiNames() {
        ClipOrigin.setCurrentApp(String(repeating: "a", count: 300), defaults: defaults)
        XCTAssertEqual(ClipOrigin.currentApp(defaults: defaults)?.count, 60)
        ClipOrigin.setCurrentApp("日本語 アプリ", defaults: defaults)
        XCTAssertEqual(ClipOrigin.currentApp(defaults: defaults), "日本語 アプリ")
    }

    func testHostsInHTML() {
        let html = """
        <meta charset="utf-8"><p>some comment <a href="https://www.reddit.com/r/test/comments/1/x/">link</a>
        <img src='https://preview.redd.it/abc.jpg?width=640'> <a href="https://WWW.reddit.com/user/x">again</a>
        <a href="/relative/path">rel</a> <a href="mailto:a@b.c">mail</a> <A HREF = "http://example.com:8080/p">e</A></p>
        """
        XCTAssertEqual(ClipOrigin.hosts(inHTML: html), ["www.reddit.com", "preview.redd.it", "example.com"])
        XCTAssertEqual(ClipOrigin.hosts(inHTML: ""), [])
        XCTAssertEqual(ClipOrigin.hosts(inHTML: "plain text, no tags"), [])
        XCTAssertEqual(ClipOrigin.hosts(inHTML: html, limit: 1), ["www.reddit.com"])
    }

    func testOriginLookupIsHarmless() {
        let pb = UIPasteboard.withUniqueName()
        pb.string = "clip origin test"
        _ = ClipOrigin.origin(pb, defaults: defaults)
        _ = ClipOrigin.origin(pb, defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: ClipOrigin.busyKey), "busy flag was left set")
        XCTAssertFalse(defaults.bool(forKey: ClipOrigin.offKey))
    }

    func testOriginLookupTurnsItselfOffAfterACrash() {
        defaults.set(true, forKey: ClipOrigin.busyKey)                 // as if the app died inside the lookup
        let pb = UIPasteboard.withUniqueName()
        let found = ClipOrigin.origin(pb, defaults: defaults)
        XCTAssertNil(found.bundle)
        XCTAssertNil(found.name)
        XCTAssertTrue(defaults.bool(forKey: ClipOrigin.offKey))
        XCTAssertFalse(defaults.bool(forKey: ClipOrigin.busyKey))
    }

    func testHeadersCarryTheReportedAppAndPageSites() {
        ClipOrigin.setCurrentApp("Reddit", defaults: defaults)
        let pb = UIPasteboard.withUniqueName()
        let html = "<a href=\"https://old.reddit.com/r/x/\">x</a>"
        pb.setItems([["public.utf8-plain-text": "x", "public.html": Data(html.utf8)]], options: [:])
        let headers = ClipOrigin.headers(for: pb, defaults: defaults)
        XCTAssertEqual(headers["X-Clip-App"], "Reddit")
        XCTAssertEqual(headers["X-Clip-Hosts"], "old.reddit.com")
        ClipOrigin.clearCurrentApp("Reddit", defaults: defaults)
        XCTAssertNil(ClipOrigin.headers(for: pb, defaults: defaults)["X-Clip-App"])
    }
}
