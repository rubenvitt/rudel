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

            // Der Gesundheit-Tab hat drei Bereiche; der Tierarzt-Bereich wird
            // erst beim Umschalten gebaut.
            if tab == "Gesundheit" {
                let vetSegment = app.segmentedControls.buttons["Tierarzt"]
                XCTAssertTrue(vetSegment.waitForExistence(timeout: 5), "Bereich Tierarzt fehlt")
                vetSegment.tap()
                XCTAssertEqual(app.state, .runningForeground, "Absturz im Tierarzt-Bereich")
                attachScreenshot(of: app, named: "tab-Gesundheit-Tierarzt")
                app.segmentedControls.buttons["Symptome"].tap()
            }
        }
    }

    /// Tierarzt-Durchstich: Praxis anlegen, Termin mit Praxis anlegen, Termin
    /// abschließen — und die Notfallkarte im Profil.
    @MainActor
    func testVetPracticeAndAppointmentLifecycle() throws {
        let app = XCUIApplication()
        // Der Simulator-Store überlebt den Testlauf: eindeutige Namen, damit
        // Einträge früherer Läufe nicht verwechselt werden.
        let suffix = UUID().uuidString.prefix(6)
        let practiceName = "Praxis UI-\(suffix)"
        let appointmentTitle = "Kontrolle UI-\(suffix)"

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        createPetIfNeeded(in: app, named: "Zola", breed: "Rhodesian Ridgeback")

        // Termine erzeugen Mitteilungen — im Test nicht.
        app.tabBars.buttons["Profil"].tap()
        app.buttons["Einstellungen"].tap()
        XCTAssertTrue(app.switches["Erinnerungen"].waitForExistence(timeout: 5))
        setReminders(false, in: app)
        app.buttons["Fertig"].tap()

        app.tabBars.buttons["Gesundheit"].tap()
        let vetSegment = app.segmentedControls.buttons["Tierarzt"]
        XCTAssertTrue(vetSegment.waitForExistence(timeout: 5))
        vetSegment.tap()

        // Praxis anlegen.
        openVetAddMenu(in: app, choosing: "Praxis")
        let nameField = app.textFields["practice-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Praxis-Sheet öffnet nicht")
        nameField.tap()
        nameField.typeText(practiceName)
        let phoneField = app.textFields["practice-phone"]
        phoneField.tap()
        phoneField.typeText("0221 123456")
        attachScreenshot(of: app, named: "tierarzt-praxis-sheet")
        app.buttons["Speichern"].tap()
        XCTAssertTrue(scrollTo(app.staticTexts[practiceName], in: app), "Praxis erscheint nicht unter „Praxen“")

        // Termin mit dieser Praxis anlegen.
        openVetAddMenu(in: app, choosing: "Termin")
        let titleField = app.textFields["appointment-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Termin-Sheet öffnet nicht")
        titleField.tap()
        titleField.typeText(appointmentTitle)
        app.buttons["appointment-practice"].tap()
        let practiceOption = app.buttons[practiceName].firstMatch
        XCTAssertTrue(practiceOption.waitForExistence(timeout: 5), "Praxis fehlt in der Auswahl")
        // Jeder Lauf legt eine Praxis an; die Auswahl wächst und der neue
        // Eintrag kann außerhalb des sichtbaren Menüs liegen.
        var attempts = 0
        while !practiceOption.isHittable, attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        practiceOption.tap()
        XCTAssertTrue(app.buttons["appointment-practice"].label.contains(practiceName) || app.staticTexts[practiceName].exists)
        attachScreenshot(of: app, named: "tierarzt-termin-sheet")
        app.buttons["Speichern"].tap()

        let upcoming = app.buttons.matching(identifier: "upcoming-appointment")
            .matching(NSPredicate(format: "label CONTAINS %@", appointmentTitle)).firstMatch
        XCTAssertTrue(scrollTo(upcoming, in: app), "Termin erscheint nicht unter „Anstehend“")
        XCTAssertTrue(upcoming.label.contains(practiceName), "Termin zeigt die Praxis nicht")
        attachScreenshot(of: app, named: "tierarzt-anstehend")

        // Termin abschließen.
        upcoming.tap()
        let doneButton = app.buttons["Als erledigt markieren"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Abschluss fehlt im Termin-Sheet")
        doneButton.tap()
        let findings = app.textFields["appointment-findings"]
        XCTAssertTrue(revealInForm(findings, in: app), "Befundfeld erscheint nicht")
        findings.tap()
        findings.typeText("Alles unauffällig")
        let cost = app.textFields["appointment-cost"]
        cost.tap()
        cost.typeText("45")
        attachScreenshot(of: app, named: "tierarzt-termin-abschluss")
        app.buttons["Speichern"].tap()

        let past = app.buttons.matching(identifier: "past-appointment")
            .matching(NSPredicate(format: "label CONTAINS %@", appointmentTitle)).firstMatch
        XCTAssertTrue(scrollTo(past, in: app), "Erledigter Termin erscheint nicht im Verlauf")
        XCTAssertFalse(upcoming.exists, "Erledigter Termin steht noch unter „Anstehend“")
        attachScreenshot(of: app, named: "tierarzt-verlauf")

        // Notfallkarte im Profil.
        app.tabBars.buttons["Profil"].tap()
        XCTAssertTrue(app.staticTexts["Notfall"].waitForExistence(timeout: 5), "Abschnitt „Notfall“ fehlt")
        XCTAssertTrue(app.staticTexts["Chipnummer"].exists)
        attachScreenshot(of: app, named: "profil-notfall")
    }

    /// Praxis direkt im Termin-Formular anlegen, Bericht teilen, Termin in
    /// den Kalender übernehmen. Teilen-Menü und Kalender-Editor sind
    /// Systemansichten: geprüft wird, dass sie erscheinen, dann abbrechen.
    @MainActor
    func testAppointmentInlinePracticeReportAndCalendar() throws {
        let app = XCUIApplication()
        let suffix = UUID().uuidString.prefix(6)
        let practiceName = "Inline-Praxis \(suffix)"
        let appointmentTitle = "Bericht UI-\(suffix)"

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        createPetIfNeeded(in: app, named: "Zola", breed: "Rhodesian Ridgeback")

        app.tabBars.buttons["Profil"].tap()
        app.buttons["Einstellungen"].tap()
        XCTAssertTrue(app.switches["Erinnerungen"].waitForExistence(timeout: 5))
        setReminders(false, in: app)
        app.buttons["Fertig"].tap()

        app.tabBars.buttons["Gesundheit"].tap()
        let vetSegment = app.segmentedControls.buttons["Tierarzt"]
        XCTAssertTrue(vetSegment.waitForExistence(timeout: 5))
        vetSegment.tap()

        // Neue Praxis aus dem Termin-Formular heraus.
        openVetAddMenu(in: app, choosing: "Termin")
        let titleField = app.textFields["appointment-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Termin-Sheet öffnet nicht")
        titleField.tap()
        titleField.typeText(appointmentTitle)
        let newPractice = app.buttons["appointment-new-practice"]
        XCTAssertTrue(newPractice.waitForExistence(timeout: 5), "„Neue Praxis …“ fehlt")
        newPractice.tap()
        let nameField = app.textFields["practice-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Praxis-Formular öffnet nicht")
        nameField.tap()
        nameField.typeText(practiceName)
        attachScreenshot(of: app, named: "termin-neue-praxis")
        // Zwei Formulare übereinander: das Speichern der Praxis gezielt treffen.
        app.navigationBars["Praxis"].buttons["Speichern"].tap()
        XCTAssertTrue(app.navigationBars["Termin"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Praxis"].exists, "Praxis-Formular bleibt offen")
        let picker = app.buttons["appointment-practice"]
        XCTAssertTrue(
            picker.label.contains(practiceName) || app.staticTexts[practiceName].exists,
            "Neue Praxis ist nicht ausgewählt: \(picker.label)"
        )
        attachScreenshot(of: app, named: "termin-praxis-ausgewaehlt")
        app.navigationBars["Termin"].buttons["Speichern"].tap()

        let upcoming = app.buttons.matching(identifier: "upcoming-appointment")
            .matching(NSPredicate(format: "label CONTAINS %@", appointmentTitle)).firstMatch
        XCTAssertTrue(scrollTo(upcoming, in: app), "Termin erscheint nicht unter „Anstehend“")
        XCTAssertTrue(upcoming.label.contains(practiceName), "Termin zeigt die neue Praxis nicht")
        upcoming.tap()

        // Bericht teilen.
        let report = app.buttons["appointment-report-share"]
        XCTAssertTrue(revealInForm(report, in: app), "Bericht-Button fehlt im Termin")
        report.tap()
        XCTAssertTrue(closeShareSheet(in: app), "Teilen-Menü erscheint nicht")
        XCTAssertTrue(app.navigationBars["Termin"].waitForExistence(timeout: 5))

        // In den Kalender übernehmen.
        let calendar = app.buttons["appointment-add-to-calendar"]
        XCTAssertTrue(revealInForm(calendar, in: app), "„In Kalender übernehmen“ fehlt")
        calendar.tap()
        XCTAssertTrue(cancelCalendarEditor(in: app), "Kalender-Editor erscheint nicht")
        XCTAssertTrue(app.navigationBars["Termin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appointment-add-to-calendar"].exists, "Abbrechen darf nicht als eingetragen gelten")
        app.navigationBars["Termin"].buttons["Abbrechen"].tap()
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

    /// Sucht ein Element in einer Liste. Der Store wächst mit jedem Lauf, und
    /// eine `List` erzeugt Zeilen außerhalb des Bildschirms gar nicht erst —
    /// deshalb erst nach unten, dann zurück nach oben blättern.
    ///
    /// `isHittable` allein reicht nicht: eine Zeile unter dem angehefteten
    /// Bereichsumschalter gilt als antippbar, der Tipp träfe aber den
    /// Umschalter. Deshalb zählt nur der Streifen zwischen Umschalter und
    /// Tab-Leiste.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        func isVisible() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let picker = app.segmentedControls.firstMatch
            let top = picker.exists ? picker.frame.maxY : 0
            let tabBar = app.tabBars.firstMatch
            let bottom = tabBar.exists ? tabBar.frame.minY : app.frame.maxY
            return element.frame.minY >= top && element.frame.maxY <= bottom
        }
        _ = element.waitForExistence(timeout: 3)
        if isVisible() { return true }
        for _ in 0..<10 {
            app.swipeUp()
            if isVisible() { return true }
        }
        for _ in 0..<20 {
            app.swipeDown()
            if isVisible() { return true }
        }
        return false
    }

    /// Ein `Form` baut Zeilen außerhalb des Bildschirms nicht: nach unten
    /// blättern, bis das Element da und antippbar ist.
    @MainActor
    private func revealInForm(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.waitForExistence(timeout: 1), element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// Das Teilen-Menü ist eine Systemansicht; ihr Schließen-Knopf folgt der
    /// Sprache des Simulators, nicht der App.
    @MainActor
    private func closeShareSheet(in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            for label in ["Close", "Schließen"] {
                let button = app.buttons[label].firstMatch
                if button.exists, button.isHittable {
                    attachScreenshot(of: app, named: "bericht-teilen")
                    button.tap()
                    return true
                }
            }
            if app.otherElements["ActivityListView"].exists || app.collectionViews["ActivityListView"].exists {
                attachScreenshot(of: app, named: "bericht-teilen")
                // Die kompakte Teilen-Karte (iOS 26) hat keinen Schließen-Knopf.
                // Ein Tipp auf den Titel daneben schließt nur sie; ein Wischen
                // nach unten nähme das Termin-Formular darunter gleich mit.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.11)).tap()
                return true
            }
            usleep(300_000)
        }
        return false
    }

    /// Der Kalender-Editor läuft außerhalb der App. Abbrechen kann bei
    /// vorbelegtem Ereignis noch eine Rückfrage zum Verwerfen auslösen.
    @MainActor
    private func cancelCalendarEditor(in app: XCUIApplication) -> Bool {
        let bar = app.navigationBars.matching(
            NSPredicate(format: "identifier IN %@", ["New Event", "Neues Ereignis", "Edit Event", "Ereignis bearbeiten"])
        ).firstMatch
        guard bar.waitForExistence(timeout: 15) else { return false }
        attachScreenshot(of: app, named: "kalender-editor")
        for label in ["Cancel", "Abbrechen"] where bar.buttons[label].exists {
            bar.buttons[label].tap()
            break
        }
        for label in ["Discard Changes", "Änderungen verwerfen", "Delete Event", "Ereignis löschen"] {
            let discard = app.buttons[label].firstMatch
            if discard.waitForExistence(timeout: 2) {
                discard.tap()
                break
            }
        }
        return true
    }

    /// Das Plus im Tierarzt-Bereich ist ein Menü mit „Termin“ und „Praxis“.
    @MainActor
    private func openVetAddMenu(in app: XCUIApplication, choosing item: String) {
        let menu = app.buttons["vet-add-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Plus-Menü im Tierarzt-Bereich fehlt")
        menu.tap()
        let entry = app.buttons[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Menüeintrag \(item) fehlt")
        entry.tap()
    }

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
