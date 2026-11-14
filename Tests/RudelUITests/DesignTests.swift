import XCTest

/// Verifiziert die neuen Bedienflächen in einem isolierten Test-Simulator.
final class DesignTests: XCTestCase {
    private let longName = "Hegel mit einem langen Rufnamen"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Der Zyklus ist kein eigener Tab mehr, sondern ein Bereich im
    /// Gesundheit-Tab — und erscheint nur für Tiere, die ihn brauchen. Die
    /// Auswahl darf dabei nicht von selbst auf die Hündin springen.
    @MainActor
    func testCycleOnlyForPetsThatNeedIt() {
        let app = launch()
        ensureTwoPets(in: app)
        selectTab("Gesundheit", in: app)

        let cycle = app.buttons["health-cycle"]
        XCTAssertTrue(app.buttons["health-symptoms"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(cycle.exists, "Zyklus erscheint für die Katze")
        attach(app, "gesundheit-katze-ohne-zyklus")

        app.selectPet("Zola")
        XCTAssertTrue(cycle.waitForExistence(timeout: 5), "Zyklus fehlt für die Hündin")
        cycle.tap()
        let start = app.buttons["Läufigkeit begonnen"].firstMatch
        let observe = app.buttons["Beobachtung erfassen"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5) || observe.exists)
        attach(app, "gesundheit-zyklus-hündin")
        app.navigationBars.buttons.firstMatch.tap()

        app.selectPet(longName)
        XCTAssertTrue(app.buttons["health-symptoms"].waitForExistence(timeout: 5))
        XCTAssertFalse(cycle.exists)
        selectTab("Heute", in: app)
        XCTAssertEqual(app.staticTexts["pet-hero-name"].label, longName)
    }

    @MainActor
    func testPetSwitchingAndQuickActions() {
        let app = launch()
        ensureTwoPets(in: app)
        selectTab("Heute", in: app)
        let heroName = app.staticTexts["pet-hero-name"]
        XCTAssertEqual(heroName.label, longName)
        XCTAssertTrue(heroName.isHittable)
        attach(app, "design-zwei-tiere-langer-name")

        let weightAction = app.buttons["Gewicht"]
        reveal(weightAction, in: app)
        weightAction.tap()
        XCTAssertTrue(app.navigationBars["Gewicht erfassen"].waitForExistence(timeout: 5))
        let weightField = app.textFields["Gewicht in Kilogramm"]
        XCTAssertTrue(weightField.exists)
        app.buttons["Abbrechen"].tap()

        // Ein Wechsel muss den neuen Namen zeigen, auch nach vorherigem Scrollen,
        // und in jedem Tab gelten.
        app.selectPet("Zola")
        XCTAssertEqual(app.staticTexts["pet-hero-name"].label, "Zola")
        selectTab("Tierarzt", in: app)
        XCTAssertTrue(app.buttons["pet-switcher"].label.contains("Zola"), app.buttons["pet-switcher"].label)
        selectTab("Heute", in: app)
        app.swipeDown(velocity: .fast)
        attach(app, "design-heute-zola")
    }

    @MainActor
    func testAccessibilityText() {
        let app = launch()
        ensureTwoPets(in: app)
        // Erst neu starten, wenn die App wirklich beendet ist. Ein sofortiger
        // Neustart lief im iPad-Simulator wiederholt in „Timed out while
        // requesting launch progress“.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertTrue(app.buttons["Heute"].firstMatch.waitForExistence(timeout: 10))
        selectTab("Heute", in: app)
        app.selectPet(longName)
        attach(app, "design-accessibility-auswahl")
        XCTAssertEqual(app.staticTexts["pet-hero-name"].label, longName)
        reveal(app.staticTexts["pet-hero-name"], in: app)
        attach(app, "design-accessibility-heute")

        selectTab("Rudel", in: app)
        attach(app, "design-accessibility-rudel")
        selectTab("Medikamente", in: app)
        let create = app.scrollViews.buttons["Plan anlegen"]
        reveal(create, in: app)
        XCTAssertTrue(create.isHittable)
        attach(app, "design-accessibility-leerzustand")
        create.tap()
        XCTAssertTrue(app.navigationBars["Neuer Plan"].waitForExistence(timeout: 5))
        app.buttons["Abbrechen"].tap()
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication.german()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        return app
    }

    /// Legt Zola und die Katze mit dem langen Namen an, falls nötig, und
    /// wählt am Ende die Katze.
    @MainActor
    private func ensureTwoPets(in app: XCUIApplication) {
        if app.buttons["Tier anlegen"].waitForExistence(timeout: 3) {
            attach(app, "design-willkommen")
            // Auf langsamen CI-Simulatoren geht der erste Tipp direkt nach dem
            // Start manchmal verloren; dann ein zweites Mal tippen.
            app.buttons["Tier anlegen"].tap()
            if !app.textFields["Name"].waitForExistence(timeout: 10),
               app.buttons["Tier anlegen"].exists {
                app.buttons["Tier anlegen"].tap()
            }
            fillPet(in: app, name: "Zola", breed: "Rhodesian Ridgeback")
        }
        selectTab("Rudel", in: app)
        let existing = app.buttons.matching(identifier: "pet-row")
            .matching(NSPredicate(format: "label CONTAINS %@", longName)).firstMatch
        if !existing.waitForExistence(timeout: 3) {
            let add = app.buttons["Weiteres Tier anlegen"]
            reveal(add, in: app)
            add.tap()
            fillPet(in: app, name: longName, breed: "Hauskatze")
        }
        selectTab("Heute", in: app)
        app.selectPet(longName)
        XCTAssertTrue(app.staticTexts["pet-hero-name"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func fillPet(in app: XCUIApplication, name: String, breed: String) {
        // Der iPad-Simulator in CI braucht für das Formular-Sheet teils deutlich
        // länger als 5 s (Start dort bis zu 65 s).
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20))
        nameField.tap()
        nameField.typeText(name)
        let breedField = app.textFields["Rasse"]
        breedField.tap()
        breedField.typeText(breed)
        if breed == "Hauskatze" { app.segmentedControls.buttons["Katze"].tap() }
        app.buttons["Speichern"].tap()
        XCTAssertTrue(app.tab("Heute").waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Name"].waitForExistence(timeout: 2), "Formular bleibt offen")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func selectTab(_ name: String, in app: XCUIApplication) {
        let tab = app.buttons[name].firstMatch
        // iPadOS stellt die Tabs oben dar und paginiert sie, wenn sie nicht
        // passen (iPad mini, sehr große Schrift). Die Blätter-Knöpfe beschriftet
        // das System in der App-Sprache — seit die App lokalisiert ist, also
        // auf Deutsch.
        if !tab.exists {
            let pagers = app.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Seite", "Page"
            ))
            for index in 0..<min(pagers.count, 2) {
                let pager = pagers.element(boundBy: index)
                if pager.exists { pager.tap() }
                if tab.exists { break }
            }
        }
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
