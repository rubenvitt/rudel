import XCTest

extension XCUIApplication {
    /// Die App auf Deutsch, unabhängig von der Simulatorsprache: Die Tests
    /// finden Elemente über ihre deutschen Beschriftungen.
    static func german() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
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
    ///
    /// Menüeinträge tragen je nach iOS-Version und Schriftgröße das eigene
    /// Label oder nur den Titel; bei sehr großer Schrift öffnet das Menü auf
    /// dem iPad gelegentlich erst beim zweiten Tipp.
    func selectPet(_ name: String) {
        let switcher = buttons["pet-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "Tier-Wechsler fehlt")
        let entry = buttons.matching(NSPredicate(
            format: "identifier != %@ AND (label == %@ OR label CONTAINS %@)",
            "pet-switcher", "Tier wechseln: \(name)", name
        )).firstMatch
        for _ in 0..<3 {
            switcher.tap()
            if entry.waitForExistence(timeout: 5) {
                entry.tap()
                return
            }
            // Kein Eintrag sichtbar: Der Tipp hat das Menü vielleicht nicht
            // geöffnet. Noch einmal tippen und sofort nachsehen, damit der
            // nächste Durchlauf ein jetzt offenes Menü nicht wieder schließt.
            guard switcher.isHittable else { continue }
            switcher.tap()
            if entry.waitForExistence(timeout: 5) {
                entry.tap()
                return
            }
        }
        XCTFail("Tier \(name) fehlt im Wechsler: \(debugDescription)")
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
