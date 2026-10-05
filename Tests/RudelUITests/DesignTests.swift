import XCTest

/// Verifiziert die neuen Bedienflächen in einem isolierten Test-Simulator.
final class DesignTests: XCTestCase {
    private let longName = "Hegel mit einem langen Rufnamen"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testCycleKeepsSelectedCatAndPetSwitcher() {
        let app = launch()
        ensureTwoPets(in: app)
        selectTab("Zyklus", in: app)

        let cat = app.buttons["Tier wechseln: \(longName)"]
        let dog = app.buttons["Tier wechseln: Zola"]
        let unavailable = app.staticTexts["Für \(longName) ist kein Zyklustracking verfügbar."]
        // Der Zyklus-Tab darf weder auf die Hündin zurückfallen noch den
        // Tierwechsler durch eine gefilterte Tierliste verschwinden lassen.
        XCTAssertTrue(cat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(cat.isSelected)
        XCTAssertTrue(dog.isHittable)
        XCTAssertTrue(unavailable.exists)
        XCTAssertFalse(app.buttons["Läufigkeit begonnen"].exists)
        XCTAssertFalse(app.buttons["Beobachtung erfassen"].exists)
        attach(app, "zyklus-katze-ohne-tracking")

        dog.tap()
        XCTAssertTrue(dog.isSelected)
        XCTAssertFalse(unavailable.exists)
        XCTAssertTrue(
            app.buttons["Läufigkeit begonnen"].exists
                || app.buttons["Beobachtung erfassen"].exists
        )

        cat.tap()
        XCTAssertTrue(cat.isSelected)
        XCTAssertTrue(unavailable.exists)
        XCTAssertFalse(app.buttons["Läufigkeit begonnen"].exists)
        XCTAssertFalse(app.buttons["Beobachtung erfassen"].exists)
        selectTab("Profil", in: app)
        XCTAssertEqual(app.staticTexts["pet-hero-name"].label, longName)
    }

    @MainActor
    func testPetSwitchingAndQuickActions() {
        let app = launch()
        ensureTwoPets(in: app)
        selectTab("Heute", in: app)
        let heroName = app.staticTexts["pet-hero-name"]
        XCTAssertEqual(heroName.label, longName)
        // Der Tierstreifen darf den eigentlichen Bildschirm nicht verdrängen.
        XCTAssertTrue(heroName.isHittable)
        attach(app, "design-zwei-tiere-langer-name")

        let weightAction = app.buttons["Gewicht"]
        reveal(weightAction, in: app)
        weightAction.tap()
        XCTAssertTrue(app.navigationBars["Gewicht erfassen"].waitForExistence(timeout: 5))
        let weightField = app.textFields["Gewicht in Kilogramm"]
        XCTAssertTrue(weightField.exists)
        app.buttons["Abbrechen"].tap()

        let firstPet = app.buttons["Tier wechseln: Zola"]
        XCTAssertTrue(firstPet.waitForExistence(timeout: 5))
        firstPet.tap()
        // Ein Wechsel muss den neuen Namen zeigen, auch nach vorherigem Scrollen.
        selectTab("Profil", in: app)
        XCTAssertEqual(app.staticTexts["pet-hero-name"].label, "Zola")
        selectTab("Heute", in: app)
        app.swipeDown(velocity: .fast)
        attach(app, "design-heute-zola")
    }

    @MainActor
    func testAccessibilityText() {
        let app = launch()
        ensureTwoPets(in: app)
        app.terminate()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Heute"].firstMatch.waitForExistence(timeout: 10))
        let longPet = app.buttons["Tier wechseln: \(longName)"]
        // Zweiter Chip ist bei großer Schrift eventuell außerhalb des Ausschnitts.
        for _ in 0..<5 where !longPet.isHittable {
            scrollPetStrip(in: app)
        }
        attach(app, "design-accessibility-auswahl")
        XCTAssertTrue(longPet.isHittable, app.debugDescription)
        longPet.tap()
        XCTAssertEqual(app.staticTexts["pet-hero-name"].label, longName)
        reveal(app.staticTexts["pet-hero-name"], in: app)
        attach(app, "design-accessibility-heute")

        selectTab("Profil", in: app)
        reveal(app.staticTexts["pet-hero-name"], in: app)
        attach(app, "design-accessibility-profil")
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
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        return app
    }

    @MainActor
    private func ensureTwoPets(in app: XCUIApplication) {
        if app.buttons["Tier anlegen"].waitForExistence(timeout: 3) {
            attach(app, "design-willkommen")
            app.buttons["Tier anlegen"].tap()
            fillPet(in: app, name: "Zola", breed: "Rhodesian Ridgeback")
        }
        if app.buttons["Tier wechseln: \(longName)"].exists {
            let target = app.buttons["Tier wechseln: \(longName)"]
            for _ in 0..<5 where !target.isHittable { scrollPetStrip(in: app) }
            target.tap()
            return
        }
        selectTab("Profil", in: app)
        let add = app.buttons["Weiteres Tier anlegen"]
        reveal(add, in: app)
        add.tap()
        fillPet(in: app, name: longName, breed: "Hauskatze")
    }

    @MainActor
    private func fillPet(in app: XCUIApplication, name: String, breed: String) {
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)
        let breedField = app.textFields["Rasse"]
        breedField.tap()
        breedField.typeText(breed)
        if breed == "Hauskatze" { app.segmentedControls.buttons["Katze"].tap() }
        app.buttons["Speichern"].tap()
        XCTAssertTrue(app.staticTexts["pet-hero-name"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func scrollPetStrip(in app: XCUIApplication) {
        // iOS meldet im AX-Frame auch den Bereich unter Status-/Navigationsleiste.
        // Eine Wischgeste in dessen Mitte trifft deshalb die Navigation. Der
        // untere Teil des Frames enthält die tatsächlich sichtbaren Tierchips.
        let strip = app.scrollViews["pet-switcher"]
        let start = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85))
        let end = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func selectTab(_ name: String, in app: XCUIApplication) {
        let tab = app.buttons[name].firstMatch
        // iPadOS stellt die Tabs oben dar und paginiert sie auf dem iPad mini.
        if !tab.exists {
            for page in ["Next Page", "Previous Page"] {
                let next = app.buttons[page].firstMatch
                if next.exists { next.tap() }
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
