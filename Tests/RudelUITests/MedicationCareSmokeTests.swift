import XCTest

/// Führt Auslassen, Zurückstellen und die Erinnerungsklasse einmal wirklich
/// aus — der Compiler prüft nur, dass die Sheets gültig sind, nicht dass sie
/// sich öffnen und speichern lassen.
///
/// Der Simulator-Store überlebt die Läufe. Der Test legt deshalb einen Plan mit
/// eindeutigem Namen an und setzt ihn am Ende ab, statt einen leeren Store
/// vorauszusetzen.
final class MedicationCareSmokeTests: XCTestCase {

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
    func testPreventivePlanCanBeDeferredSkippedAndConfigured() throws {
        let app = XCUIApplication()
        let productName = "Zeckentablette \(UUID().uuidString.prefix(6))"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        createPetIfNeeded(in: app, named: "Zola", breed: "Rhodesian Ridgeback")

        // Zeckenschutz-Plan anlegen. Das Formular zeigt die Erinnerungsklasse
        // schon beim Anlegen, mit „Vorsorge" als Standard der Art.
        app.tabBars.buttons["Medikamente"].tap()
        app.buttons["Plan anlegen"].firstMatch.tap()
        app.buttons["Art"].tap()
        app.buttons["Zeckenschutz"].firstMatch.tap()
        let product = app.textFields["medication-product-name"]
        XCTAssertTrue(product.waitForExistence(timeout: 5))
        product.tap()
        product.typeText(productName)
        reveal(app.buttons["Vorsorge"], in: app)
        XCTAssertTrue(app.buttons["Vorsorge"].isSelected, "Zeckenschutz startet nicht als Vorsorge")
        attachScreenshot(of: app, named: "vorsorge-plan-anlegen")
        app.buttons["Speichern"].tap()

        // Zurückstellen bis zum 1. März.
        let row = planRow(productName, in: app)
        openRowAction("Zurückstellen", on: row, in: app)
        XCTAssertTrue(app.navigationBars["Zurückstellen"].waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "vorsorge-zurueckstellen-sheet")
        app.buttons["defer-option-march"].tap()
        app.buttons["Speichern"].tap()
        XCTAssertTrue(
            waitForLabel(of: row, containing: "Zurückgestellt bis", timeout: 5),
            "Status zeigt keine Zurückstellung: \(row.label)"
        )
        attachScreenshot(of: app, named: "vorsorge-zurueckgestellt")

        // Auslassen schreibt einen Journal-Eintrag und hebt die Zurückstellung auf.
        openRowAction("Auslassen", on: planRow(productName, in: app), in: app)
        XCTAssertEqual(app.state, .runningForeground, "Absturz beim Auslassen")
        XCTAssertTrue(
            waitForLabel(of: planRow(productName, in: app), containing: "Ausgelassen", timeout: 5),
            "Status zeigt keine Auslassung"
        )
        attachScreenshot(of: app, named: "vorsorge-ausgelassen")

        // Der Heute-Screen muss den Plan samt Vorsorge-Aktionen bauen können.
        app.tabBars.buttons["Heute"].tap()
        XCTAssertEqual(app.state, .runningForeground, "Absturz auf Heute")
        attachScreenshot(of: app, named: "vorsorge-heute")

        // Das Bearbeiten-Sheet zeigt die Erinnerungsklasse. Danach den Plan
        // absetzen, damit der dauerhafte Store nicht mit Testplänen vollläuft.
        app.tabBars.buttons["Medikamente"].tap()
        openRowAction("Bearbeiten", on: planRow(productName, in: app), in: app)
        XCTAssertTrue(app.navigationBars["Plan bearbeiten"].waitForExistence(timeout: 5))
        reveal(app.buttons["Zeitkritisch"], in: app)
        XCTAssertTrue(app.buttons["Zeitkritisch"].exists)
        XCTAssertTrue(app.buttons["Vorsorge"].isSelected)
        XCTAssertTrue(app.switches["Tierarzttermin nötig"].exists)
        attachScreenshot(of: app, named: "vorsorge-plan-bearbeiten")
        let deactivate = app.buttons["Medikament absetzen"]
        reveal(deactivate, in: app)
        deactivate.tap()
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Helfer

    /// Die Planzeile ist ein Button; SwiftUI fasst Titel und Status zu dessen
    /// Beschriftung zusammen.
    @MainActor
    private func planRow(_ productName: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", productName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Planzeile \(productName) fehlt")
        reveal(row, in: app)
        return row
    }

    /// Wischaktion, mit dem Kontextmenü als zweitem Weg — Wischgesten sind in
    /// XCUITest nicht immer zuverlässig.
    @MainActor
    private func openRowAction(_ title: String, on row: XCUIElement, in app: XCUIApplication) {
        row.swipeLeft()
        let swipeButton = app.buttons[title].firstMatch
        if swipeButton.waitForExistence(timeout: 2), swipeButton.isHittable {
            swipeButton.tap()
            return
        }
        // Offene Wischaktion schließen, dann das Kontextmenü.
        row.swipeRight()
        row.press(forDuration: 1.2)
        let menuButton = app.buttons[title].firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 3), "Aktion \(title) nicht erreichbar")
        menuButton.tap()
    }

    @MainActor
    private func waitForLabel(of element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Scrollt, bis das Element antippbar ist. Die Zeckenschutz-Gruppe kann bei
    /// gefülltem Store unter dem sichtbaren Bereich liegen.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < 8 {
            app.swipeUp(velocity: .slow)
            attempts += 1
        }
    }

    @MainActor
    private func createPetIfNeeded(in app: XCUIApplication, named name: String, breed: String) {
        let welcomeButton = app.buttons["Tier anlegen"]
        guard welcomeButton.waitForExistence(timeout: 10) else { return }
        let nameField = app.textFields["Name"]
        // Auf einem frischen Simulator schluckt eine Systemabfrage den ersten
        // Tap; der Unterbrechungs-Monitor greift erst bei der nächsten
        // Interaktion. Deshalb bis zu dreimal versuchen.
        for _ in 0..<3 where !nameField.exists {
            welcomeButton.tap()
            if nameField.waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Namensfeld fehlt")
        nameField.tap()
        nameField.typeText(name)

        let breedField = app.textFields["Rasse"]
        if breedField.exists {
            breedField.tap()
            breedField.typeText(breed)
        }

        let saveButton = app.buttons["Speichern"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Speichern-Button fehlt")
        saveButton.tap()

        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 10),
            "Nach dem Anlegen erscheint keine Tab-Leiste"
        )
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
