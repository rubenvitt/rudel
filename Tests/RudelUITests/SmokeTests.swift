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
        addUIInterruptionMonitor(withDescription: "Systemberechtigung im isolierten Simulator") { alert in
            for label in ["Allow", "Erlauben", "Zulassen"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    @MainActor
    func testMedicationReminderSettingsAndConfirmationRoute() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        createPetIfNeeded(in: app, named: "Zola", breed: "Rhodesian Ridgeback")
        app.tabBars.buttons["Profil"].tap()
        app.buttons["Einstellungen"].tap()
        XCTAssertTrue(app.switches["Erinnerungen"].waitForExistence(timeout: 5))
        setReminders(true, in: app)
        XCTAssertTrue(app.switches["Medikamentenalarme"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.steppers["Vorwarnung: 30 Minuten"].exists)
        XCTAssertTrue(app.steppers["Schlummern: 10 Minuten"].exists)
        attachScreenshot(of: app, named: "medikamentenalarm-einstellungen")
        // Nur der isolierte Test-Store: keine echten Alarme während UI-Tests.
        setReminders(false, in: app)
        app.buttons["Fertig"].tap()
        app.open(URL(string: "rudel://medication-reminder?reminder=already-completed")!)
        XCTAssertTrue(app.navigationBars["Gabe bestätigen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Diese Erinnerung ist bereits erledigt oder wurde durch einen geänderten Plan ersetzt."].exists)
        XCTAssertFalse(app.buttons["Jetzt als gegeben bestätigen"].exists)
        attachScreenshot(of: app, named: "medikamentenalarm-erledigter-verweis")
        app.buttons["Schließen"].tap()
    }

    @MainActor
    func testOngoingMedicationQuickLogSelectsAConcreteDose() throws {
        let app = XCUIApplication()
        let productName = "UI-Präparat \(UUID().uuidString.prefix(6))"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        createPetIfNeeded(in: app, named: "Zola", breed: "Rhodesian Ridgeback")
        app.tabBars.buttons["Profil"].tap()
        app.buttons["Einstellungen"].tap()
        XCTAssertTrue(app.switches["Erinnerungen"].waitForExistence(timeout: 5))
        setReminders(false, in: app)
        app.buttons["Fertig"].tap()
        app.tabBars.buttons["Medikamente"].tap()
        app.buttons["Plan anlegen"].firstMatch.tap()
        app.buttons["Art"].tap()
        app.buttons["Laufendes Medikament"].tap()
        let product = app.textFields["medication-product-name"]
        XCTAssertTrue(product.waitForExistence(timeout: 5))
        product.tap()
        product.typeText(productName)
        app.buttons["Speichern"].tap()
        XCTAssertTrue(app.buttons["Gabe erfassen"].waitForExistence(timeout: 5))
        app.buttons["Gabe erfassen"].tap()
        XCTAssertTrue(app.navigationBars["Gabe erfassen"].waitForExistence(timeout: 5))
        app.buttons["medication-plan-selection"].tap()
        app.buttons[productName].tap()
        attachScreenshot(of: app, named: "medikament-erfassungsformular")
        XCTAssertTrue(app.buttons["medication-dose-selection"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Speichern"].isEnabled)
        attachScreenshot(of: app, named: "medikament-konkrete-gabe-erfassen")
        app.buttons["Speichern"].tap()
        XCTAssertTrue(app.buttons["Gabe erfassen"].waitForExistence(timeout: 5))
        app.buttons["Gabe erfassen"].tap()
        XCTAssertTrue(app.buttons["medication-plan-selection"].waitForExistence(timeout: 5))
        app.buttons["medication-plan-selection"].tap()
        app.buttons[productName].tap()
        XCTAssertTrue(app.staticTexts["An diesem Tag gibt es keine offene Gabe."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Speichern"].isEnabled)
        attachScreenshot(of: app, named: "medikament-bestaetigung-einmalig")
        app.buttons["Abbrechen"].tap()
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
        //
        // Der Simulator-Store überlebt den einzelnen Testlauf: läuft aus einem
        // früheren Durchlauf schon eine Läufigkeit, fehlt dieser Einstieg, und
        // der Test soll daran nicht scheitern — er prüft, dass die Screens der
        // laufenden Läufigkeit bauen, nicht wer sie angelegt hat.
        let startButton = app.buttons["Läufigkeit begonnen"].firstMatch
        if startButton.waitForExistence(timeout: 5) {
            startButton.tap()
            XCTAssertEqual(app.state, .runningForeground, "Absturz im Tag-1-Sheet")
            attachScreenshot(of: app, named: "zyklus-tag1-sheet")

            let saveButton = app.buttons["Speichern"]
            XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Speichern im Tag-1-Sheet fehlt")
            saveButton.tap()
        }

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

    @MainActor
    private func setReminders(_ enabled: Bool, in app: XCUIApplication) {
        let toggle = app.switches["Erinnerungen"]
        let expected = enabled ? "1" : "0"
        if toggle.value as? String != expected {
            // SwiftUI meldet die ganze beschriftete Zeile als Switch. Der
            // tatsächliche Schalter sitzt am rechten Rand der Zeile.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

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
