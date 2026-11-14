import Foundation
import Testing

@testable import RudelEngine

/// Die Engine-Tests prüfen die deutschen Texte byte-genau. CI-Runner laufen
/// auf Englisch — ohne diese Zeile käme dort die englische Übersetzung. Jede
/// Suite ruft das in ihrem `init()`; alle setzen denselben Wert, parallel
/// laufende Suites stören sich also nicht. Tests anderer Sprachen nutzen
/// `EngineLocalization.withLanguage(_:operation:)` (Task-lokal, hat Vorrang).
func useGermanEngineTexts() {
    EngineLocalization.overrideLanguage("de")
}

@Suite("EngineLocalization — Sprachwahl und Übersetzungen")
struct EngineLocalizationTests {
    init() { useGermanEngineTexts() }

    private let planner = NotificationPlanner(dayMath: .utc)

    @Test("Sprachcodes werden auf die mitgelieferten Sprachen abgebildet")
    func normalization() {
        #expect(EngineLocalization.normalize("pt-BR") == "pt")
        #expect(EngineLocalization.normalize("nb_NO") == "nb")
        #expect(EngineLocalization.normalize("no") == "nb")
        #expect(EngineLocalization.normalize("de-CH") == "de")
        #expect(EngineLocalization.normalize("en") == "en")
        #expect(EngineLocalization.normalize("zh-Hans") == nil)
        #expect(EngineLocalization.normalize("Base") == nil)
    }

    @Test("Die erzwungene Sprache gilt, die Task-lokale hat Vorrang")
    func overridePrecedence() {
        #expect(EngineLocalization.currentLanguage == "de")
        EngineLocalization.withLanguage("en") {
            #expect(EngineLocalization.currentLanguage == "en")
        }
        #expect(EngineLocalization.currentLanguage == "de")
    }

    @Test("Jede Sprache bringt ihr eigenes lproj mit")
    func everyLanguageShipsResources() {
        let keys = [
            "pet.fallbackName",
            "vaccine.other",
            "notification.subject.vetAppointment",
            "notification.relative.inDays",
        ]
        for language in EngineLocalization.supportedLanguages {
            for key in keys {
                #expect(L10n.lookup(key, language: language) != nil, "\(language): \(key)")
            }
        }
        #expect(L10n.lookup("pet.fallbackName", language: "fr") == "Votre animal")
    }

    @Test("Deutsch: einfache Texte und Plural")
    func germanTexts() {
        #expect(VaccineType.other.displayName == "Andere Impfung")
        #expect(L10n.string("notification.relative.overdue", 1) == "seit 1 Tag überfällig")
        #expect(L10n.string("notification.relative.overdue", 4) == "seit 4 Tagen überfällig")
        #expect(L10n.string("notification.relative.inDays", 3) == "in 3 Tagen")
        #expect(L10n.string("due.detail.forecastWindow", 0) == "Prognosefenster ± 0 Tage")
        #expect(L10n.string("notification.appointment.onDate", "01.03.2026", "10:30") == "Am 01.03.2026 um 10:30")
    }

    @Test("Englisch: Übersetzung und englische Pluralregel")
    func englishTexts() {
        EngineLocalization.withLanguage("en") {
            #expect(VaccineType.other.displayName == "Other vaccination")
            #expect(FertileWindowEstimator.behaviourCaveat.hasPrefix("Estimated from behavior only"))
            #expect(L10n.string("notification.relative.overdue", 1) == "overdue by 1 day")
            #expect(L10n.string("notification.relative.overdue", 2) == "overdue by 2 days")
            #expect(L10n.string("notification.appointment.onDate", "Mar 1, 2026", "10:30 AM") == "Mar 1, 2026 at 10:30 AM")
        }
    }

    @Test("Japanisch kennt nur „other“")
    func japanesePlural() {
        EngineLocalization.withLanguage("ja") {
            #expect(L10n.string("notification.relative.inDays", 1) == "1日後")
            #expect(L10n.string("notification.relative.inDays", 5) == "5日後")
        }
    }

    @Test("Mitteilung auf Englisch: Satzbau aus einem Schlüssel, Verb nicht doppelt")
    func englishNotification() throws {
        let item = DueItem(
            id: "med:a",
            sourceID: "a",
            petID: "p",
            petName: "Zola",
            category: .medication,
            title: "Deworming",
            dueOn: day(2026, 3, 10),
            daysUntilDue: 0,
            urgency: .dueToday
        )
        let notifications = EngineLocalization.withLanguage("en") {
            planner.plan(
                dueItems: [item],
                doseOccurrences: [:],
                settings: .init(leadDays: [0], horizonDays: 14),
                asOf: day(2026, 3, 10)
            )
        }
        let first = try #require(notifications.first)
        #expect(first.title == "Zola — Deworming due")
        #expect(first.body == "Deworming is due today.")
    }

    @Test("Ein unbekannter Schlüssel kommt unverändert zurück")
    func unknownKeyFallsBackToKey() {
        // Sichtbar falsch, aber kein Absturz und kein leerer Text.
        #expect(L10n.string("does.not.exist") == "does.not.exist")
    }
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    DayMath.utc.calendar.date(from: DateComponents(year: year, month: month, day: day))!
}
