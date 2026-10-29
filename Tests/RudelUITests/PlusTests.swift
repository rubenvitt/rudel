import XCTest

extension XCUIApplication {
    /// App mit freigeschaltetem Rudel Plus (nur Debug-Builds). Die meisten
    /// Tests legen mehrere Tiere an oder teilen Berichte.
    static func withPlus() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-rudelPlus"]
        return app
    }
}

/// Ohne Plus führt ein zweites Tier zum Angebot, nicht ins Formular.
final class PlusTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testSecondPetShowsPlusOffer() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        let welcome = app.buttons["Tier anlegen"]
        if welcome.waitForExistence(timeout: 5) {
            welcome.tap()
            let name = app.textFields["Name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText("Zola")
            app.buttons["Speichern"].tap()
        }

        let profile = app.tabBars.buttons["Profil"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
        let add = app.buttons["Weiteres Tier anlegen"]
        for _ in 0..<8 where !add.isHittable { app.swipeUp() }
        add.tap()

        XCTAssertTrue(app.staticTexts["Rudel Plus"].waitForExistence(timeout: 5), "Plus-Angebot erscheint nicht")
        XCTAssertFalse(app.textFields["Name"].exists, "Formular statt Angebot")
        attachScreenshot(of: app, named: "plus-angebot")
        app.buttons["Schließen"].tap()
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
