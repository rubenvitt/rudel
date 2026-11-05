import XCTest

extension XCUIApplication {
    /// App mit freigeschaltetem Rudel Plus (nur Debug-Builds). Die meisten
    /// Tests legen mehrere Tiere an oder teilen Berichte.
    static func withPlus() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-rudelPlus"]
        return app
    }

    /// Ein Tab der Hauptnavigation. Auf dem iPad zeigt iOS 26 die Tabs
    /// schwebend oben, dort findet XCTest keine TabBar, nur Buttons.
    func tab(_ name: String) -> XCUIElement {
        UIDevice.current.userInterfaceIdiom == .pad
            ? buttons[name].firstMatch
            : tabBars.buttons[name]
    }

    /// Das „+“ oben rechts ist überall ein Menü mit beschrifteten Einträgen.
    func chooseFromAddMenu(_ item: String, menu: String = "add-menu") {
        let button = buttons[menu].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Plus-Menü fehlt")
        button.tap()
        let entry = buttons[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Menüeintrag \(item) fehlt")
        entry.tap()
    }

    /// Wechselt das Tier über das Tierbild oben links.
    func selectPet(_ name: String) {
        let switcher = buttons["pet-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "Tier-Wechsler fehlt")
        switcher.tap()
        // Menüeinträge tragen je nach iOS-Version das eigene Label oder nur
        // den Titel.
        let labelled = buttons["Tier wechseln: \(name)"].firstMatch
        let titled = buttons[name].firstMatch
        XCTAssertTrue(
            labelled.waitForExistence(timeout: 5) || titled.exists,
            "Tier \(name) fehlt im Wechsler"
        )
        (labelled.exists ? labelled : titled).tap()
    }

    /// Öffnet Rudel › Erinnerungen & Alarme.
    func openReminderSettings() {
        tab("Rudel").tap()
        let link = buttons["settings-reminders"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Einstieg in die Erinnerungen fehlt")
        for _ in 0..<6 where !link.isHittable { swipeUp() }
        link.tap()
    }

    /// Zurück aus den Erinnerungen in die Rudel-Übersicht.
    func closeReminderSettings() {
        let back = navigationBars["Erinnerungen"].buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
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

        let rudel = app.tab("Rudel")
        XCTAssertTrue(rudel.waitForExistence(timeout: 10))
        rudel.tap()
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
