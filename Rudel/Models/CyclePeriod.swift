import Foundation
import RudelEngine
import SwiftData

/// Eine Läufigkeit. `day1Date` ist der **Anker** aller Berechnungen: der erste
/// Tag mit blutigem Ausfluss bzw. Vulvaschwellung (PRD §5.3).
///
/// Der Zyklus ist erst mit dem Tag-1-Anker existent — ohne ihn gibt es keinen
/// Referenzpunkt und keine Prognose.
@Model
final class CyclePeriod {
    var id: UUID = UUID()

    /// Tag 1: erster Tag blutiger Ausfluss / Vulvaschwellung. Auf Mitternacht
    /// normalisiert speichern.
    var day1Date: Date = Date.distantPast

    /// Ende der **sichtbaren** Hitze. `nil` = läuft noch bzw. nicht erfasst.
    /// Nicht zu verwechseln mit dem Ende des Zyklus — der Diöstrus läuft danach
    /// noch 60–90 Tage weiter.
    var visibleHeatEndDate: Date?

    /// Anzeichen von Scheinträchtigkeit im Diöstrus-Nachlauf (PRD §5.3).
    var pseudopregnancyObserved: Bool = false
    var pseudopregnancyNote: String = ""

    var note: String = ""
    var createdAt: Date = Date.distantPast

    var pet: Pet?

    @Relationship(deleteRule: .cascade, inverse: \CycleObservation.period)
    var observations: [CycleObservation] = []

    init(
        day1Date: Date,
        visibleHeatEndDate: Date? = nil,
        pseudopregnancyObserved: Bool = false,
        pseudopregnancyNote: String = "",
        note: String = "",
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.day1Date = day1Date
        self.visibleHeatEndDate = visibleHeatEndDate
        self.pseudopregnancyObserved = pseudopregnancyObserved
        self.pseudopregnancyNote = pseudopregnancyNote
        self.note = note
        self.createdAt = createdAt
    }
}

extension CyclePeriod {
    var engineID: String { id.uuidString }

    /// Beobachtungen chronologisch.
    var sortedObservations: [CycleObservation] {
        observations.sorted { $0.date < $1.date }
    }

    /// Alle Beobachtungen als Engine-Signale.
    var phaseSignals: [PhaseSignals] {
        sortedObservations.map(\.phaseSignals)
    }

    /// Erster Tag mit dokumentierter Standhitze — Grundlage der
    /// Deckzeitpunkt-Schätzung ohne Progesteron.
    var firstStandingHeatDate: Date? {
        sortedObservations.first { $0.standingHeat == true }?.date
    }

    /// Läuft die sichtbare Hitze zum Stichtag noch?
    func isVisiblyActive(asOf: Date = Date()) -> Bool {
        guard let visibleHeatEndDate else { return day1Date <= asOf }
        return day1Date <= asOf && asOf <= visibleHeatEndDate
    }
}

/// Eine Tagesbeobachtung innerhalb einer Läufigkeit. **Append-only** (PRD §8).
///
/// Alle Felder außer `date` sind optional: die Erfassung muss in zwei Taps
/// möglich sein (PRD §2), also darf kein Feld erzwungen werden. Ein nicht
/// gesetztes Feld heißt „nicht beobachtet", nicht „nicht vorhanden" — die
/// Engine unterscheidet das (`PhaseSignals.isEmpty`).
@Model
final class CycleObservation {
    var id: UUID = UUID()
    var date: Date = Date.distantPast

    var dischargePresent: Bool?
    var dischargeColorValue: DischargeColor?
    var dischargeAmountValue: DischargeAmount?
    /// Konsistenz der Vulva — Tastbefund.
    var vulvaTurgorValue: VulvaTurgor?

    // Alltagszeichen: ohne Anfassen zu erheben, deshalb die einzigen Felder,
    // die in der Praxis lückenlos anfallen. Sie belegen eine laufende
    // Läufigkeit, benennen aber keine Phase — siehe `PhaseSignals`.
    var frequentUrination: Bool?
    var genitalLicking: Bool?
    var vulvaSwellingVisible: Bool?

    /// Flagging: Schwanz zur Seite bei Berührung von Kruppe/Damm. Teil des
    /// Duldungsreflexes, ohne Rüden auslösbar und früher da als die volle
    /// Duldung.
    var flagging: Bool?
    /// Duldung / Standhitze: der vollständige Reflex. Ebenfalls ohne Rüden
    /// prüfbar, über festen Druck auf die Lendenpartie.
    var standingHeat: Bool?
    var attractsMales: Bool?

    /// Progesteron in ng/ml, falls gemessen.
    var progesteroneNgPerMl: Double?
    /// Kornifizierung in Prozent (Vaginalzytologie), 0–100.
    var cornificationPercent: Double?

    var note: String = ""
    var loggedAt: Date = Date.distantPast

    var period: CyclePeriod?

    init(
        date: Date,
        dischargePresent: Bool? = nil,
        dischargeColor: DischargeColor? = nil,
        dischargeAmount: DischargeAmount? = nil,
        vulvaTurgor: VulvaTurgor? = nil,
        frequentUrination: Bool? = nil,
        genitalLicking: Bool? = nil,
        vulvaSwellingVisible: Bool? = nil,
        flagging: Bool? = nil,
        standingHeat: Bool? = nil,
        attractsMales: Bool? = nil,
        progesteroneNgPerMl: Double? = nil,
        cornificationPercent: Double? = nil,
        note: String = "",
        loggedAt: Date = Date()
    ) {
        self.id = UUID()
        self.date = date
        self.dischargePresent = dischargePresent
        self.dischargeColorValue = dischargeColor
        self.dischargeAmountValue = dischargeAmount
        self.vulvaTurgorValue = vulvaTurgor
        self.frequentUrination = frequentUrination
        self.genitalLicking = genitalLicking
        self.vulvaSwellingVisible = vulvaSwellingVisible
        self.flagging = flagging
        self.standingHeat = standingHeat
        self.attractsMales = attractsMales
        self.progesteroneNgPerMl = progesteroneNgPerMl
        self.cornificationPercent = cornificationPercent
        self.note = note
        self.loggedAt = loggedAt
    }
}

extension CycleObservation {
    /// Mappt die Beobachtung auf den Engine-Typ. In `Tests/RudelTests` abgedeckt.
    var phaseSignals: PhaseSignals {
        PhaseSignals(
            date: date,
            dischargePresent: dischargePresent,
            dischargeColor: dischargeColorValue,
            dischargeAmount: dischargeAmountValue,
            vulvaTurgor: vulvaTurgorValue,
            frequentUrination: frequentUrination,
            genitalLicking: genitalLicking,
            vulvaSwellingVisible: vulvaSwellingVisible,
            flagging: flagging,
            standingHeat: standingHeat,
            attractsMales: attractsMales,
            progesteroneNgPerMl: progesteroneNgPerMl,
            cornificationPercent: cornificationPercent,
            pseudopregnancySigns: period?.pseudopregnancyObserved
        )
    }
}
