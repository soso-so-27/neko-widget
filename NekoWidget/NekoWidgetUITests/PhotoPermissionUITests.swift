import XCTest

final class PhotoPermissionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 60
    }

    @MainActor
    func testGrantFullPhotoLibraryAccess() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launch()

        let requestButton = app.buttons["photo-permission-primary"]
        guard requestButton.waitForExistence(timeout: 15) else {
            addDiagnosticAttachment(
                name: "Missing in-app Photos permission button",
                contents: app.debugDescription
            )
            XCTFail("The in-app Photos permission button did not appear.")
            return
        }
        requestButton.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permissionAlert = springboard.alerts.firstMatch
        guard permissionAlert.waitForExistence(timeout: 15) else {
            addDiagnosticAttachment(
                name: "Missing Photos permission alert",
                contents: springboard.debugDescription
            )
            XCTFail("The system Photos permission alert did not appear.")
            return
        }

        let fullAccessLabels = [
            "Allow Full Access",
            "Allow Access to All Photos",
            "フルアクセスを許可",
            "すべての写真へのアクセスを許可",
        ]
        guard let fullAccessButton = fullAccessLabels.lazy
            .map({ permissionAlert.buttons[$0] })
            .first(where: { $0.exists })
        else {
            let buttonLabels = permissionAlert.buttons.allElementsBoundByIndex
                .map(\.label)
                .joined(separator: "\n")
            addDiagnosticAttachment(
                name: "Unhandled Photos permission alert",
                contents: "Buttons:\n\(buttonLabels)\n\nAlert:\n\(permissionAlert.debugDescription)"
            )
            XCTFail("No known full-access button was present in the Photos permission alert.")
            return
        }

        fullAccessButton.tap()

        let systemAlertDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: permissionAlert
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [systemAlertDisappeared], timeout: 15),
            .completed,
            "The Photos permission alert did not close after granting full access."
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "After full Photos authorization"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func addDiagnosticAttachment(name: String, contents: String) {
        let attachment = XCTAttachment(string: contents)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
