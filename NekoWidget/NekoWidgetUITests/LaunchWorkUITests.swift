import XCTest

/// 11/14: the main thread in the first 25 s after opening the app and after
/// coming back to it, with a library the size of the owner's (DEBUG
/// `--launch-work-fixture`: 10,000 synthetic records, 2,500 cats, 2 cats with
/// linked albums of 500). Records only, no pass/fail line: one
/// `LAUNCHWORK|<場面>|<summary>` line per window in the xcodebuild log.
/// summary: frames, frame gaps over 32 ms and 100 ms, their total ms, the
/// longest gap, then `name=calls/ms` for the measured functions.
/// Manual only: native-tests route=speed, test_filter=LaunchWork.
final class LaunchWorkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        executionTimeAllowance = 600
    }

    @MainActor
    func testLaunchWorkOnLargeLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
                               "--launch-work-fixture", "--launch-work-meter"]
        app.launchEnvironment["NEKO_LAUNCH_WORK_SECONDS"] = "25"

        // 1. First launch: the library is written, then the first pass.
        app.launch()
        allowPhotosIfAsked()
        report("初回", read(app, window: 1))
        // Let the first pass finish before closing, as a person would.
        sleep(20)
        app.terminate()

        // 2. Opening again, nothing changed in Photos.
        app.launch()
        report("再起動（写真は同じ）", read(app, window: 1))

        // 3. Home, then back to the app.
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        report("前面に戻る", read(app, window: 2))
        app.terminate()
    }

    private func read(_ app: XCUIApplication, window: Int) -> String {
        let meter = app.descendants(matching: .any)["launch-work-meter"]
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if meter.exists, meter.label.hasPrefix("window=\(window);") { return meter.label }
            usleep(500_000)
        }
        XCTFail("launch-work-meter window \(window) did not report")
        return "missing"
    }

    private func report(_ scene: String, _ summary: String) {
        print("LAUNCHWORK|\(scene)|\(summary)")
        let attachment = XCTAttachment(string: summary)
        attachment.name = "LAUNCHWORK " + scene
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        for label in ["フルアクセスを許可", "すべての写真へのアクセスを許可", "Allow Full Access", "許可", "OK"] {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return }
        }
    }
}
