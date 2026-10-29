import XCTest

/// App-Store-Screenshots mit Beispieldaten. Läuft nur im Screenshots-Workflow
/// (`TEST_RUNNER_SCREENSHOTS=1`) auf einem frischen Simulator.
final class AppStoreScreenshots: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Systemberechtigung") { alert in
            for label in ["Allow", "Erlauben", "Zulassen"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    @MainActor
    func testAppStoreScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCREENSHOTS"] == "1", "only for the Screenshots workflow")
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication.withPlus()
        app.launchArguments += ["-rudelDemo", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        XCTAssertTrue(app.staticTexts["pet-hero-name"].waitForExistence(timeout: 20))
        // Heute zuletzt: der erste Tab-Wechsel räumt Berechtigungsdialoge ab.
        for (name, tab) in [("2-Medikamente", "Medikamente"), ("3-Gesundheit", "Gesundheit"), ("4-Profil", "Profil"), ("1-Heute", "Heute")] {
            let button = app.tab(tab).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Tab \(tab) fehlt")
            button.tap()
            sleep(1)
            attach(app, name)
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
