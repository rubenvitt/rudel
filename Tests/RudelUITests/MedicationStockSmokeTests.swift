import XCTest

/// Legt eine Impfung und ein Dauermedikament mit Vorrat an und füllt den
/// Vorrat einmal auf — der Compiler prüft nur, dass Formular und Sheet gültig
/// sind, nicht dass sie sich bedienen lassen.
///
/// Der Simulator-Store überlebt die Läufe. Die Pläne tragen deshalb eindeutige
/// Namen und werden am Ende abgesetzt.
final class MedicationStockSmokeTests: XCTestCase {

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
    func testVaccinationAndStockCanBeCreatedAndRestocked() throws {
        let app = XCUIApplication()
        let suffix = String(UUID().uuidString.prefix(6))
        let vaccineProduct = "Nobivac \(suffix)"
        let stockProduct = "Apoquel \(suffix)"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        createPetIfNeeded(in: app, named: "Zola", breed: "Rhodesian Ridgeback")

        // Impfung „Leptospirose“ anlegen: eine Art „Impfung", darunter die Auswahl.
        app.tabBars.buttons["Medikamente"].tap()
        app.buttons["Plan anlegen"].firstMatch.tap()
        app.buttons["Art"].tap()
        app.buttons["Impfung"].firstMatch.tap()
        let vaccinePicker = app.buttons["medication-vaccine"]
        XCTAssertTrue(vaccinePicker.waitForExistence(timeout: 5), "Auswahl der Impfung fehlt")
        vaccinePicker.tap()
        let lepto = app.buttons["Leptospirose"].firstMatch
        XCTAssertTrue(lepto.waitForExistence(timeout: 5), "Leptospirose fehlt im Katalog")
        lepto.tap()
        type(vaccineProduct, into: app.textFields["medication-product-name"], in: app)
        attachScreenshot(of: app, named: "impfung-anlegen")
        app.buttons["Speichern"].tap()

        let vaccineRow = planRow(vaccineProduct, in: app)
        XCTAssertTrue(vaccineRow.label.contains("Leptospirose"), "Zeile zeigt nicht den Impfnamen: \(vaccineRow.label)")
        XCTAssertTrue(app.staticTexts["Impfungen"].exists, "Abschnitt „Impfungen“ fehlt")
        attachScreenshot(of: app, named: "impfpass")

        // Dauermedikament mit Vorrat: drei Tabletten, Packung zu 30.
        app.buttons["Plan anlegen"].firstMatch.tap()
        app.buttons["Art"].tap()
        app.buttons["Laufendes Medikament"].firstMatch.tap()
        type(stockProduct, into: app.textFields["medication-product-name"], in: app)
        let toggle = app.switches["medication-manage-stock"]
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.exists, "Schalter „Vorrat verwalten“ fehlt")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        type("3", into: app.textFields["medication-stock-amount"], in: app)
        type("30", into: app.textFields["medication-package-size"], in: app)
        attachScreenshot(of: app, named: "vorrat-anlegen")
        app.buttons["Speichern"].tap()

        // Knapper Vorrat steht in der Liste, „Aufgefüllt“ öffnet das Sheet.
        _ = planRow(stockProduct, in: app)
        let restock = app.buttons["restock-\(stockProduct)"]
        reveal(restock, in: app)
        XCTAssertTrue(restock.waitForExistence(timeout: 5), "„Aufgefüllt“ fehlt")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Vorrat: noch 3")).firstMatch.exists,
            "Vorratszeile fehlt"
        )
        attachScreenshot(of: app, named: "vorrat-liste")
        restock.tap()
        XCTAssertTrue(app.navigationBars["Aufgefüllt"].waitForExistence(timeout: 5))
        app.buttons["restock-add-package"].tap()
        attachScreenshot(of: app, named: "vorrat-auffuellen")
        app.buttons["Speichern"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Vorrat: noch 33")).firstMatch
                .waitForExistence(timeout: 5),
            "Bestand nach dem Auffüllen stimmt nicht"
        )

        // Heute muss die Liste samt Vorrat bauen können.
        app.tabBars.buttons["Heute"].tap()
        XCTAssertEqual(app.state, .runningForeground, "Absturz auf Heute")
        attachScreenshot(of: app, named: "vorrat-heute")

        // Aufräumen: beide Pläne absetzen.
        app.tabBars.buttons["Medikamente"].tap()
        for product in [stockProduct, vaccineProduct] {
            openRowAction("Bearbeiten", on: planRow(product, in: app), in: app)
            XCTAssertTrue(app.navigationBars["Plan bearbeiten"].waitForExistence(timeout: 5))
            let deactivate = app.buttons["Medikament absetzen"]
            reveal(deactivate, in: app)
            deactivate.tap()
            XCTAssertEqual(app.state, .runningForeground)
        }
    }

    // MARK: - Helfer

    @MainActor
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Feld \(field) fehlt")
        field.tap()
        field.typeText(text)
    }

    @MainActor
    private func planRow(_ productName: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", productName)).firstMatch
        // Erst blättern, dann prüfen: Der Store wächst mit jedem Lauf, und eine
        // `List` baut Zeilen außerhalb des Bildschirms nicht.
        _ = row.waitForExistence(timeout: 3)
        reveal(row, in: app)
        XCTAssertTrue(row.exists, "Planzeile \(productName) fehlt")
        return row
    }

    @MainActor
    private func openRowAction(_ title: String, on row: XCUIElement, in app: XCUIApplication) {
        row.swipeLeft()
        let swipeButton = app.buttons[title].firstMatch
        if swipeButton.waitForExistence(timeout: 2), swipeButton.isHittable {
            swipeButton.tap()
            return
        }
        row.swipeRight()
        row.press(forDuration: 1.2)
        let menuButton = app.buttons[title].firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 3), "Aktion \(title) nicht erreichbar")
        menuButton.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < 20 {
            app.swipeUp(velocity: .slow)
            attempts += 1
        }
        attempts = 0
        while !(element.exists && element.isHittable), attempts < 25 {
            app.swipeDown()
            attempts += 1
        }
    }

    @MainActor
    private func createPetIfNeeded(in app: XCUIApplication, named name: String, breed: String) {
        let welcomeButton = app.buttons["Tier anlegen"]
        guard welcomeButton.waitForExistence(timeout: 10) else { return }
        let nameField = app.textFields["Name"]
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
