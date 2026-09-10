import XCTest
import UIKit

/// Captures privacy-safe, real SpringBoard screenshots for the in-app Widget
/// placement guide and explicitly enabled Widget visual review. Ordinary smoke
/// runs do not enable the Widget screenshot compiler conditions.
///
/// The workflow erases its Simulator before and after the test. No Photos are
/// imported. Only the dedicated official-photo test adds a Widget to that
/// disposable Home Screen; existing guide and private-window captures do not.
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

        guard let widgetSearchResult = waitForWidgetGalleryResult(
            in: springboard,
            timeout: 20
        ) else {
            fail(
                "The Widget gallery did not return ねこのまど.",
                application: springboard
            )
            return
        }
        captureScreenshot(named: "onboarding-widget-step-3")

        widgetSearchResult.tap()

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
        captureFixtureGallery(captureAllSizes: false)
    }

    @MainActor
    func testCaptureSharedWidgetAllSupportedSizes() {
        executionTimeAllowance = 180
        captureFixtureGallery(captureAllSizes: true)
    }

    @MainActor
    func testCaptureSharedWidgetWhiteBackgroundAllSupportedSizes() {
        executionTimeAllowance = 180
        captureFixtureGallery(captureAllSizes: true, expectWhiteFixture: true)
    }

    @MainActor
    func testCaptureOfficialWidgetAllSupportedSizesAndHomeScreen() {
        executionTimeAllowance = 240
        captureFixtureGallery(captureAllSizes: true, officialWindow: true)
    }

    @MainActor
    private func captureFixtureGallery(
        captureAllSizes: Bool,
        expectWhiteFixture: Bool = false,
        officialWindow: Bool = false
    ) {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
        ]
        app.launch()

        guard app.wait(for: .runningForeground, timeout: 20) else {
            fail(
                "The app did not launch before opening the Widget Gallery.",
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

        guard let widgetSearchResult = findFixtureGalleryResult(in: springboard) else {
            fail(
                "The Widget gallery did not return ねこのまど.",
                application: springboard
            )
            return
        }
        widgetSearchResult.tap()

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
        if captureAllSizes {
            // SpringBoard also exposes the obscured Home Screen page control.
            // Only the Gallery's scroll view contains the size picker control.
            let gallery = springboard.scrollViews
                .containing(.pageIndicator, identifier: nil)
                .firstMatch
            let pages = gallery.pageIndicators.firstMatch
            guard pages.waitForExistence(timeout: 10),
                  galleryPage(pages) == [1, 3],
                  let fixtureScreenshot = waitForFixturePhoto(
                      in: gallery, springboard: springboard, timeout: 15,
                      expectWhiteFixture: expectWhiteFixture
                  ) else {
                fail("The small Widget page did not display its fixture photo.", application: springboard)
                return
            }
            if officialWindow { assertNoOfficialPhotoActions(in: gallery) }
            captureScreenshot(
                named: officialWindow ? "widget-official-small" : "widget-family-small",
                screenshot: fixtureScreenshot
            )
            for (index, size) in ["medium", "large"].enumerated() {
                guard let previousPage = pages.value as? String, !previousPage.isEmpty else {
                    fail("The Widget size page cannot be identified.", application: springboard)
                    return
                }
                let start = springboard.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.85, dy: 0.57)
                )
                let end = springboard.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.15, dy: 0.57)
                )
                start.press(forDuration: 0.1, thenDragTo: end)
                let changedPage = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value != %@", previousPage),
                    object: pages
                )
                guard XCTWaiter.wait(for: [changedPage], timeout: 8) == .completed,
                      let screenshot = waitForFixturePhoto(
                          in: gallery, springboard: springboard, timeout: 10,
                          expectWhiteFixture: expectWhiteFixture
                      ),
                      galleryPage(pages) == [index + 2, 3] else {
                    fail("The Widget size did not advance to a rendered photo.", application: springboard)
                    return
                }
                if officialWindow { assertNoOfficialPhotoActions(in: gallery) }
                captureScreenshot(
                    named: officialWindow ? "widget-official-\(size)" : "widget-family-\(size)",
                    screenshot: screenshot
                )
            }
            if officialWindow {
                installSmallOfficialWidget(in: springboard, gallery: gallery, pages: pages)
            }
        } else {
            guard let fixtureScreenshot = waitForFixturePalette(timeout: 15) else {
                fail("The Widget gallery did not render the deterministic local cat preview.", application: springboard)
                return
            }
            captureScreenshot(named: "01-local-cat-widget", screenshot: fixtureScreenshot)
        }
        // Existing guide/private captures never add a Widget. Only the
        // explicit official scenario installs one before Simulator cleanup.
    }

    @MainActor
    private func installSmallOfficialWidget(
        in springboard: XCUIApplication,
        gallery: XCUIElement,
        pages: XCUIElement
    ) {
        // The all-size capture finishes on Large. Return through Medium to
        // Small and verify the Gallery's page indicator before installing.
        for index in 0..<2 {
            guard let previousPage = pages.value as? String else {
                fail("The official Widget size cannot be identified.", application: springboard)
                return
            }
            let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.57))
            let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.57))
            start.press(forDuration: 0.1, thenDragTo: end)
            let changedPage = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", previousPage), object: pages
            )
            guard XCTWaiter.wait(for: [changedPage], timeout: 8) == .completed,
                  galleryPage(pages) == [2 - index, 3],
                  waitForFixturePhoto(in: gallery, springboard: springboard, timeout: 10) != nil else {
                fail("Could not return to the small official Widget.", application: springboard)
                return
            }
        }
        guard waitForFixturePhoto(in: gallery, springboard: springboard, timeout: 10) != nil,
              let addButton = waitForElement(
                  in: springboard, labels: ["ウィジェットを追加", "Add Widget"],
                  elementTypes: [.button], timeout: 8
              ) else {
            fail("The small official Widget was not ready to install.", application: springboard)
            return
        }
        addButton.tap()
        let galleryDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: gallery
        )
        guard XCTWaiter.wait(for: [galleryDismissed], timeout: 15) == .completed else {
            fail("The Widget Gallery did not close after installation.", application: springboard)
            return
        }
        XCUIDevice.shared.press(.home)
        guard let screenshot = waitForFixturePalette(timeout: 15) else {
            fail("The installed official Widget did not render on Home Screen.", application: springboard)
            return
        }
        assertNoOfficialPhotoActions(in: springboard)
        captureScreenshot(named: "widget-official-home-small", screenshot: screenshot)
        let hierarchy = XCTAttachment(string: springboard.debugDescription)
        hierarchy.name = "Official Widget Home Screen hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    private func assertNoOfficialPhotoActions(in surface: XCUIElement) {
        // Assert exposed controls; reviewers also inspect the captured pixels
        // for the short cat-name footer and absence of overlaid action icons.
        XCTAssertFalse(surface.buttons["ハートを送る"].exists)
        XCTAssertFalse(surface.buttons["思い出に残す"].exists)
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
    private func findFixtureGalleryResult(in springboard: XCUIApplication) -> XCUIElement? {
        if let result = waitForWidgetGalleryResult(in: springboard, timeout: 20) {
            return result
        }

        // A freshly installed extension may be absent from the first catalog.
        // Preserve that evidence, then reopen the catalog once. This prepares
        // the visual fixture; it does not prove immediate install availability.
        let hierarchy = XCTAttachment(string: springboard.debugDescription)
        hierarchy.name = "Widget Gallery before single reopen"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        captureScreenshot(named: "widget-gallery-before-single-reopen")

        guard let close = waitForElement(
            in: springboard, labels: ["Close", "閉じる"], elementTypes: [.button], timeout: 5
        ) else { return nil }
        close.tap()
        guard let edit = waitForElement(
            in: springboard, labels: ["Edit", "編集"], elementTypes: [.button], timeout: 5
        ) else { return nil }
        edit.tap()
        guard let addWidget = waitForElement(
            in: springboard, labels: ["Add Widget", "ウィジェットを追加"],
            elementTypes: [.button, .staticText, .menuItem], timeout: 5
        ) else { return nil }
        addWidget.tap()
        guard let search = waitForFirstElement(springboard.searchFields, timeout: 5) else { return nil }
        search.tap()
        if let value = search.value as? String, value != search.placeholderValue, !value.isEmpty {
            let clear = search.buttons.matching(NSPredicate(
                format: "label IN %@", ["Clear text", "テキストを消去"]
            )).firstMatch
            guard clear.waitForExistence(timeout: 5), clear.isHittable else { return nil }
            clear.tap()
            guard let cleared = search.value as? String,
                  cleared.isEmpty || cleared == search.placeholderValue else { return nil }
        }
        search.typeText("ねこのまど")
        guard search.value as? String == "ねこのまど" else { return nil }
        return waitForWidgetGalleryResult(in: springboard, timeout: 20)
    }

    @MainActor
    private func waitForWidgetGalleryResult(
        in springboard: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        // Gallery results are cells. A substring search also matches SpringBoard's
        // "No Results for this app" message before an app result appears.
        // Exact, hittable cells exclude that message and obscured Home icons.
        let names = ["ねこのまど", "NekoWidget"]
        let candidates = springboard.cells.matching(NSPredicate(
            format: "label IN %@ OR identifier IN %@", names, names
        ))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let result = candidates.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                return result
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        } while Date() < deadline
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
    private func galleryPage(_ indicator: XCUIElement) -> [Int] {
        guard let value = indicator.value as? String else { return [] }
        return value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    @MainActor
    private func waitForFixturePhoto(
        in gallery: XCUIElement,
        springboard: XCUIApplication,
        timeout: TimeInterval,
        expectWhiteFixture: Bool = false
    ) -> XCUIScreenshot? {
        // CI's Gallery AX exposes the preview as a Button with a "Widget,"
        // value. Its page control supplies the size; don't require the preview
        // to be interactive or depend on unobserved localized size suffixes.
        let photos = gallery.buttons.matching(
            NSPredicate(format: "value BEGINSWITH %@", "Widget,")
        )
        let deadline = Date().addingTimeInterval(timeout)
        var visibleSince: Date?
        repeat {
            let screenshot = XCUIScreen.main.screenshot()
            let screenFrame = springboard.frame
            if let photo = photos.allElementsBoundByIndex.first(where: {
                $0.exists && screenFrame.contains($0.frame)
                    && abs($0.frame.midX - screenFrame.midX) < 20
            }),
               fixturePhotoIsVisible(
                   in: screenshot, photoFrame: photo.frame, screenFrame: screenFrame,
                   expectWhiteFixture: expectWhiteFixture
               ) {
                if let visibleSince {
                    if Date().timeIntervalSince(visibleSince) >= 0.5 { return screenshot }
                } else {
                    visibleSince = Date()
                }
            } else {
                visibleSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return nil
    }

    @MainActor
    private func fixturePhotoIsVisible(
        in screenshot: XCUIScreenshot,
        photoFrame: CGRect,
        screenFrame: CGRect,
        expectWhiteFixture: Bool = false
    ) -> Bool {
        guard let source = screenshot.image.cgImage,
              screenFrame.width > 0, screenFrame.height > 0,
              screenFrame.contains(photoFrame), !photoFrame.isEmpty else { return false }
        let scaleX = CGFloat(source.width) / screenFrame.width
        let scaleY = CGFloat(source.height) / screenFrame.height
        let crop = CGRect(
            x: (photoFrame.minX - screenFrame.minX) * scaleX,
            y: (photoFrame.minY - screenFrame.minY) * scaleY,
            width: photoFrame.width * scaleX, height: photoFrame.height * scaleY
        )
        guard let photo = source.cropping(to: crop) else { return false }
        let width = 100
        let height = max(1, Int(Double(photo.height) / Double(photo.width) * Double(width)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var rendered = false
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(photo, in: CGRect(x: 0, y: 0, width: width, height: height))
            rendered = true
        }
        guard rendered else { return false }
        var lightPixels = 0
        var midtonePixels = 0
        var whitePixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if red > 130 && green > 130 && blue > 110 { lightPixels += 1 }
            if red >= 245 && green >= 245 && blue >= 245 { whitePixels += 1 }
            let brightness = (red + green + blue) / 3
            if brightness > 40 && brightness < 120 && max(red, green, blue) < 140 {
                midtonePixels += 1
            }
        }
        // All three committed cat photos contain light surroundings and darker
        // fur. The white contrast fixture also satisfies this gate: its white
        // canvas is light, and its 60% caption scrim supplies midtones. A uniform
        // skeleton has no such light/midtone pair; sparse copy over the dark
        // missing-image view does not supply the required light area either.
        // The white run must additionally reject a retained normal cat preview.
        // Allow the maximum-text footer and rounded corners to occupy the rest.
        // Text layout and contrast still require visual review of the capture.
        let pixelCount = width * height
        return lightPixels > pixelCount / 10 && midtonePixels > pixelCount / 20
            && (!expectWhiteFixture || whitePixels * 100 >= pixelCount * 35)
    }

    @MainActor
    private func waitForFixturePalette(timeout: TimeInterval) -> XCUIScreenshot? {
        let deadline = Date().addingTimeInterval(timeout)
        var visibleSince: Date?
        repeat {
            let screenshot = XCUIScreen.main.screenshot()
            if fixturePaletteIsVisible(in: screenshot) {
                // Gallery previews keep gently moving. Require sustained photo
                // visibility, not identical pixels, within the same deadline.
                if let visibleSince {
                    if Date().timeIntervalSince(visibleSince) >= 0.5 {
                        return screenshot
                    }
                } else {
                    visibleSince = Date()
                }
            } else {
                visibleSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return nil
    }

    @MainActor
    private func fixturePaletteIsVisible(in screenshot: XCUIScreenshot) -> Bool {
        guard let source = screenshot.image.cgImage else { return false }
        let width = 330
        let height = max(
            1,
            Int((Double(source.height) / Double(source.width) * Double(width)).rounded())
        )
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        var drewImage = false
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return
            }
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            drewImage = true
        }
        guard drewImage else { return false }

        var furPixels = 0
        var eyePixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if isNear(red, 130) && isNear(green, 92) && isNear(blue, 115) {
                furPixels += 1
            }
            if isNear(red, 227) && isNear(green, 191) && isNear(blue, 77) {
                eyePixels += 1
            }
        }
        return furPixels >= 500 && eyePixels >= 25
    }

    private func isNear(_ value: Int, _ target: Int) -> Bool {
        abs(value - target) <= 12
    }

    @MainActor
    private func captureScreenshot(
        named name: String,
        screenshot: XCUIScreenshot? = nil
    ) {
        let attachment = XCTAttachment(
            screenshot: screenshot ?? XCUIScreen.main.screenshot()
        )
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
