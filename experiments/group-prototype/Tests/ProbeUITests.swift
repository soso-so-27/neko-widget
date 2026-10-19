import XCTest
final class ProbeUITests: XCTestCase {
    @MainActor func testWidgetReadsBothProtocols() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.staticTexts["PROTOCOLS_PASS"].waitForExistence(timeout: 30), app.debugDescription)
        XCUIDevice.shared.press(.home)
        let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var edit: XCUIElement?
        for point in [CGVector(dx: 0.5, dy: 0.48), CGVector(dx: 0.5, dy: 0.70), CGVector(dx: 0.3, dy: 0.62)] {
            spring.coordinate(withNormalizedOffset: point).press(forDuration: 1.8)
            let candidate = spring.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Edit", "編集"])).firstMatch
            if candidate.waitForExistence(timeout: 4) { edit = candidate; break }
            spring.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.78)).tap()
        }
        XCTAssertNotNil(edit, spring.debugDescription); edit!.tap()
        let addButton = spring.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Add Widget", "ウィジェットを追加"])).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), spring.debugDescription); addButton.tap()
        let search = spring.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("Neko Group Probe")
        // Gallery results are hittable cells; identical text on the obscured
        // Home Screen is not a gallery result (as observed in the first run).
        let candidates = spring.cells.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
            ["Neko Group Probe", "Probe"], ["Neko Group Probe", "Probe"]))
        let deadline = Date().addingTimeInterval(20)
        var result: XCUIElement?
        repeat {
            result = candidates.allElementsBoundByIndex.first { $0.isHittable }
            if result != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        } while Date() < deadline
        XCTAssertNotNil(result, spring.debugDescription); result!.tap()
        // WidgetKit can aggregate the preview's accessibility text. The app's
        // shared-container marker below is the actual crypto-read assertion.
        _ = spring.staticTexts["WIDGET_HPKE_MLS_PASS"].firstMatch.waitForExistence(timeout: 20)
        let screenshot = XCTAttachment(screenshot: spring.screenshot()); screenshot.name = "isolated-widget-crypto-read"; screenshot.lifetime = .keepAlways; add(screenshot)
        // The extension wrote its success marker into the shared container.
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["WIDGET_HPKE_MLS_PASS"].waitForExistence(timeout: 20), app.debugDescription)
    }
}
