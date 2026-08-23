import XCTest

/// Captures privacy-safe, real SpringBoard screenshots for the in-app Widget
/// placement guide. This test is intentionally excluded from the normal smoke
/// path and is run only by the manual screenshot-capture workflow.
///
/// The workflow erases its Simulator before and after the test. No Photos are
/// imported, and the final "Add Widget" button is deliberately not tapped.
final class WidgetPlacementScreenshotUITests: XCTestCase {
    private let springboardBundleIdentifier = "com.apple.springboard"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
    }

    @MainActor
    func testCaptureJapaneseCurrentWidgetPlacementGuide() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-onboarding.completedVersion", "0",
            "-onboarding.resumePageIndex.v1", "0",
            "-hasSeenInitialScanResult.v1", "0",
        ]
        app.launch()

        guard app.wait(for: .runningForeground, timeout: 20) else {
            fail(
                "The app did not launch before opening SpringBoard.",
                application: app
            )
            return
        }

        // Launching once makes the app and its embedded Widget extension known
        // to SpringBoard. We leave onboarding untouched and never request Photos.
        XCUIDevice.shared.press(.home)

        let springboard = XCUIApplication(bundleIdentifier: springboardBundleIdentifier)
        guard springboard.wait(for: .runningForeground, timeout: 15) else {
            fail(
                "SpringBoard did not become foreground after pressing Home.",
                application: springboard
            )
            return
        }

        guard let editButton = enterHomeScreenEditing(in: springboard) else {
            fail(
                "Could not enter Home Screen editing mode. Expected 編集 or Edit.",
                application: springboard
            )
            return
        }
        captureScreenshot(named: "onboarding-widget-step-1")

        editButton.tap()
        guard let addWidgetMenuItem = waitForElement(
            in: springboard,
            labels: [
                "ウィジェットを追加",
                "Add Widget",
            ],
            elementTypes: [.button, .staticText, .menuItem],
            timeout: 12
        ) else {
            fail(
                "The Home Screen edit menu did not expose Add Widget.",
                application: springboard
            )
            return
        }
        captureScreenshot(named: "onboarding-widget-step-2-ios18")

        addWidgetMenuItem.tap()
        guard let searchField = waitForFirstElement(
            springboard.searchFields,
            timeout: 15
        ) else {
            fail(
                "The Widget gallery search field did not appear.",
                application: springboard
            )
            return
        }

        searchField.tap()
        searchField.typeText("ねこのまど")

        guard let widgetSearchResult = waitForElement(
            in: springboard,
            labels: [
                "ねこのまど",
                "NekoWidget",
            ],
            elementTypes: [.button, .cell, .staticText, .other],
            timeout: 20
        ) else {
            fail(
                "The Widget gallery did not return ねこのまど.",
                application: springboard
            )
            return
        }
        captureScreenshot(named: "onboarding-widget-step-3")

        if widgetSearchResult.isHittable {
            widgetSearchResult.tap()
        } else {
            widgetSearchResult
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .tap()
        }

        guard waitForElement(
            in: springboard,
            labels: [
                "ウィジェットを追加",
                "Add Widget",
            ],
            elementTypes: [.button],
            timeout: 20
        ) != nil else {
            fail(
                "The Widget size picker did not expose its Add Widget button.",
                application: springboard
            )
            return
        }
        captureScreenshot(named: "onboarding-widget-step-4")

        // Intentionally stop here. The capture workflow must never mutate even
        // its disposable Home Screen by adding a Widget.
    }

    @MainActor
    func testCaptureJapaneseLocalOnlyWidgetPreviewForAppStore() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "--app-store-widget-screenshot-fixture",
        ]
        app.launch()

        guard app.staticTexts["app-store-widget-screenshot-fixture-ready"]
            .waitForExistence(timeout: 20)
        else {
            fail(
                "The local-only Widget fixture was not published to the App Group.",
                application: app
            )
            return
        }

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: springboardBundleIdentifier)
        guard springboard.wait(for: .runningForeground, timeout: 15) else {
            fail(
                "SpringBoard did not become foreground for the App Store Widget capture.",
                application: springboard
            )
            return
        }
        guard let editButton = enterHomeScreenEditing(in: springboard) else {
            fail(
                "Could not enter Home Screen editing mode for the App Store Widget capture.",
                application: springboard
            )
            return
        }
        editButton.tap()

        guard let addWidgetMenuItem = waitForElement(
            in: springboard,
            labels: ["ウィジェットを追加", "Add Widget"],
            elementTypes: [.button, .staticText, .menuItem],
            timeout: 12
        ) else {
            fail(
                "The Home Screen edit menu did not expose Add Widget.",
                application: springboard
            )
            return
        }
        addWidgetMenuItem.tap()

        guard let searchField = waitForFirstElement(
            springboard.searchFields,
            timeout: 15
        ) else {
            fail(
                "The Widget gallery search field did not appear.",
                application: springboard
            )
            return
        }
        searchField.tap()
        searchField.typeText("ねこのまど")

        guard let widgetSearchResult = waitForElement(
            in: springboard,
            labels: ["ねこのまど", "NekoWidget"],
            elementTypes: [.button, .cell, .staticText, .other],
            timeout: 20
        ) else {
            fail(
                "The Widget gallery did not return ねこのまど.",
                application: springboard
            )
            return
        }
        if widgetSearchResult.isHittable {
            widgetSearchResult.tap()
        } else {
            widgetSearchResult
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .tap()
        }

        guard waitForElement(
            in: springboard,
            labels: ["ウィジェットを追加", "Add Widget"],
            elementTypes: [.button],
            timeout: 20
        ) != nil else {
            fail(
                "The Widget size picker did not expose its Add Widget button.",
                application: springboard
            )
            return
        }
        guard waitForElement(
            in: springboard,
            labels: ["このiPhoneで見つけた猫写真"],
            elementTypes: [.image, .other, .staticText],
            timeout: 30
        ) != nil else {
            fail(
                "The Widget gallery did not render the seeded local cat preview.",
                application: springboard
            )
            return
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        captureScreenshot(named: "01-local-cat-widget")
        // Do not tap Add Widget. The disposable Simulator is erased after the
        // run, but the capture itself remains read-only SpringBoard review.
    }

    @MainActor
    private func enterHomeScreenEditing(in springboard: XCUIApplication) -> XCUIElement? {
        let labels = ["編集", "Edit"]
        let candidatePoints = [
            CGVector(dx: 0.50, dy: 0.48),
            CGVector(dx: 0.50, dy: 0.70),
            CGVector(dx: 0.30, dy: 0.62),
        ]

        for point in candidatePoints {
            springboard
                .coordinate(withNormalizedOffset: point)
                .press(forDuration: 1.8)

            if let editButton = waitForElement(
                in: springboard,
                labels: labels,
                elementTypes: [.button, .staticText],
                timeout: 4
            ) {
                return editButton
            }

            // A press that landed on an icon can open its context menu. Dismiss
            // it before trying another icon-free coordinate.
            springboard
                .coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.78))
                .tap()
        }
        return nil
    }

    @MainActor
    private func waitForElement(
        in application: XCUIApplication,
        labels: [String],
        elementTypes: [XCUIElement.ElementType],
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            for elementType in elementTypes {
                let candidates = application.descendants(matching: elementType)
                for label in labels {
                    let predicate = NSPredicate(
                        format: "label == %@ OR identifier == %@ OR value == %@ OR label CONTAINS %@",
                        label,
                        label,
                        label,
                        label
                    )
                    let matches = candidates.matching(predicate).allElementsBoundByIndex
                    if let match = matches.first(where: \.exists) {
                        return match
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        } while Date() < deadline

        return nil
    }

    @MainActor
    private func waitForFirstElement(
        _ query: XCUIElementQuery,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let element = query.firstMatch
        return element.waitForExistence(timeout: timeout) ? element : nil
    }

    @MainActor
    private func captureScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func fail(_ message: String, application: XCUIApplication) {
        let hierarchy = XCTAttachment(string: application.debugDescription)
        hierarchy.name = "SpringBoard hierarchy on capture failure"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Screen on capture failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTFail(message)
    }
}
