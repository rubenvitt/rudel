import XCTest

/// Führt die Screens tatsächlich aus, statt sie nur zu übersetzen.
///
/// Der Compiler bestätigt, dass SwiftUI-Code gültig ist — nicht, dass er läuft.
/// Ein Force-Unwrap, ein `#Predicate` mit einem zur Laufzeit nicht
/// unterstützten Ausdruck oder ein Index daneben fallen erst auf, wenn die View
/// wirklich gebaut wird. Dieser Test tut genau das: ein Tier anlegen, jeden Tab
/// öffnen, jedes Erfassungs-Sheet aufziehen.
///
/// Bewusst XCTest und nicht Swift Testing — XCUITest gibt es nur dort.
final class SmokeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Der Durchstich: vom leeren Zustand bis durch alle Tabs.
    @MainActor
    func testCreatePetAndVisitEveryTab() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 20),
            "App ist nicht in den Vordergrund gekommen"
        )

        createPetIfNeeded(in: app, named: "Zola", breed: "Rhodesian Ridgeback")
        attachScreenshot(of: app, named: "01-nach-anlegen")

        // Jeder Tab muss sich öffnen lassen, ohne dass die App verschwindet.
        // "Zyklus" ist optional: er erscheint nur für unkastrierte Hündinnen,
        // und ob das Anlege-Formular so vorbelegt war, hängt an dessen Defaults.
        for tab in ["Heute", "Medikamente", "Zyklus", "Gesundheit", "Profil"] {
            let button = app.tabBars.buttons[tab]
            guard button.waitForExistence(timeout: 5) else {
                if tab == "Zyklus" { continue }
                XCTFail("Tab \(tab) nicht gefunden")
                return
            }
            button.tap()

            XCTAssertEqual(
                app.state, .runningForeground,
                "App ist beim Öffnen von \(tab) abgestürzt"
            )
            attachScreenshot(of: app, named: "tab-\(tab)")
        }
    }

    /// Der Zyklus-Durchstich: Läufigkeit anlegen, damit die Screens der
    /// laufenden Läufigkeit überhaupt gebaut werden.
    ///
    /// Ohne einen Tag-1-Anker zeigt der Zyklus-Tab nur seinen Leerzustand — die
    /// Risikostufe, die Deckplanung und das Beobachtungsformular sind dann
    /// unerreichbar und wären allein vom Compiler geprüft. Genau die Lücke, die
    /// dieses Target schließen soll.
    @MainActor
    func testCycleScreensRenderWithARunningHeat() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        createPetIfNeeded(in: app, named: "Zola", breed: "Rhodesian Ridgeback")

        let cycleTab = app.tabBars.buttons["Zyklus"]
        // Der Tab erscheint nur für unkastrierte Hündinnen. Ist das Anlege-
        // Formular anders vorbelegt, ist hier nichts zu prüfen.
        guard cycleTab.waitForExistence(timeout: 5) else { return }
        cycleTab.tap()

        // Tag 1 anlegen — vorbelegt mit heute, also ist danach eine Läufigkeit
        // aktiv und die Risikostufe steht auf Tag 1.
        let startButton = app.buttons["Läufigkeit begonnen"].firstMatch
        guard startButton.waitForExistence(timeout: 5) else {
            XCTFail("Kein Einstieg in die Läufigkeitserfassung")
            return
        }
        startButton.tap()
        XCTAssertEqual(app.state, .runningForeground, "Absturz im Tag-1-Sheet")
        attachScreenshot(of: app, named: "zyklus-tag1-sheet")

        let saveButton = app.buttons["Speichern"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Speichern im Tag-1-Sheet fehlt")
        saveButton.tap()

        // Zurück auf der Übersicht: Risikostufe, laufende Läufigkeit und
        // Deckplanung werden jetzt tatsächlich gebaut.
        let riskHeader = app.staticTexts["Wie sehr aufpassen?"]
        XCTAssertTrue(
            riskHeader.waitForExistence(timeout: 10),
            "Die Risikostufe erscheint nicht, obwohl eine Läufigkeit läuft"
        )
        XCTAssertEqual(app.state, .runningForeground, "Absturz beim Aufbau der Zyklus-Übersicht")
        attachScreenshot(of: app, named: "zyklus-laufend")

        // Und das Beobachtungsformular, das ohne Läufigkeit nur seinen
        // Leerzustand zeigen könnte.
        let observeButton = app.buttons["Beobachtung erfassen"].firstMatch
        XCTAssertTrue(observeButton.waitForExistence(timeout: 5), "Kein Einstieg in die Beobachtung")
        observeButton.tap()
        XCTAssertEqual(app.state, .runningForeground, "Absturz im Beobachtungs-Sheet")
        attachScreenshot(of: app, named: "zyklus-beobachtung")
        dismissSheet(in: app)
    }

    /// Zieht jedes Erfassungs-Sheet einmal auf. Sheets sind die Screens mit den
    /// meisten Bindings und damit die wahrscheinlichste Absturzstelle.
    @MainActor
    func testEverySheetOpens() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        createPetIfNeeded(in: app, named: "Hegel", breed: "Hauskatze")

        for tab in ["Heute", "Medikamente", "Gesundheit", "Profil"] {
            let tabButton = app.tabBars.buttons[tab]
            guard tabButton.waitForExistence(timeout: 5) else { continue }
            tabButton.tap()

            // Der erste Button in der Navigationsleiste, der ein Sheet öffnet,
            // ist überall das "+"/Erfassen-Element.
            let addButtons = app.navigationBars.buttons.allElementsBoundByIndex
            for button in addButtons where button.isHittable {
                let label = button.label.lowercased()
                guard label.contains("hinzu") || label.contains("erfassen")
                    || label.contains("neu") || label.contains("add") || label == "+"
                else { continue }

                button.tap()
                XCTAssertEqual(
                    app.state, .runningForeground,
                    "Absturz beim Öffnen eines Sheets in \(tab)"
                )
                attachScreenshot(of: app, named: "sheet-\(tab)")
                dismissSheet(in: app)
                break
            }
        }
    }

    // MARK: - Helfer

    /// Legt ein Tier an, falls die App noch den Willkommensbildschirm zeigt.
    /// Bleibt der Store aus einem vorherigen Lauf gefüllt, passiert nichts —
    /// der Test soll nicht daran scheitern, in welcher Reihenfolge er läuft.
    @MainActor
    private func createPetIfNeeded(in app: XCUIApplication, named name: String, breed: String) {
        let welcomeButton = app.buttons["Tier anlegen"]
        guard welcomeButton.waitForExistence(timeout: 10) else { return }
        welcomeButton.tap()

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Namensfeld fehlt")
        nameField.tap()
        nameField.typeText(name)

        let breedField = app.textFields["Rasse"]
        if breedField.exists {
            breedField.tap()
            breedField.typeText(breed)
        }

        let saveButton = app.buttons["Speichern"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Speichern-Button fehlt")
        XCTAssertTrue(saveButton.isEnabled, "Speichern ist bei ausgefülltem Namen deaktiviert")
        saveButton.tap()

        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 10),
            "Nach dem Anlegen erscheint keine Tab-Leiste"
        )
    }

    @MainActor
    private func dismissSheet(in app: XCUIApplication) {
        for label in ["Abbrechen", "Fertig", "Schließen"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }
        // Kein Abbrechen-Button: nach unten wegwischen.
        app.swipeDown(velocity: .fast)
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
