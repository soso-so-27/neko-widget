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
        let result = spring.staticTexts["Neko Group Probe"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), spring.debugDescription); result.tap()
        let pass = spring.staticTexts["WIDGET_HPKE_MLS_PASS"].firstMatch
        XCTAssertTrue(pass.waitForExistence(timeout: 30), spring.debugDescription)
        let screenshot = XCTAttachment(screenshot: spring.screenshot()); screenshot.name = "isolated-widget-crypto-read"; screenshot.lifetime = .keepAlways; add(screenshot)
        // The extension wrote its success marker into the shared container.
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["WIDGET_HPKE_MLS_PASS"].waitForExistence(timeout: 20), app.debugDescription)
    }
}
