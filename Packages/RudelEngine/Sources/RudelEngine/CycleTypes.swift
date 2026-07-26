import Foundation

// MARK: - Beobachtungs-Skalen (PRD §5.3)

/// Farbe des Ausflusses. Der Übergang blutig → strohfarben/rosa ist das
/// verlässlichste nicht-klinische Signal für den Wechsel Proöstrus → Östrus.
public enum DischargeColor: String, Sendable, Codable, CaseIterable, Hashable {
    case bloody         // frisch blutig — Proöstrus
    case brownish       // dunkel, älteres Blut
    case pinkish        // rosa — Übergang
    case strawColored   // strohfarben — Östrus
    case clear          // klar
}

public enum DischargeAmount: String, Sendable, Codable, CaseIterable, Hashable {
    case none
    case scant
    case moderate
    case heavy
}

/// Turgor/Schwellung der Vulva. Prall im Proöstrus, im Östrus weicher und
/// nachgiebiger — das Weicherwerden korreliert mit der Duldungsbereitschaft.
public enum VulvaTurgor: String, Sendable, Codable, CaseIterable, Hashable {
    case normal         // nicht geschwollen — An-/Diöstrus
    case swollenFirm    // geschwollen und prall — Proöstrus
    case softening      // Schwellung gibt nach — Übergang
    case swollenSoft    // geschwollen, weich/schlaff — Östrus
}

/// Ein Satz Beobachtungen zu einem Tag. Alle Felder optional: die App darf
/// nie erzwingen, dass ein Tag vollständig dokumentiert wird (PRD §2: Erfassung
/// in maximal zwei Taps).
public struct PhaseSignals: Sendable, Equatable, Hashable {
    public var date: Date
    public var dischargePresent: Bool?
    public var dischargeColor: DischargeColor?
    public var dischargeAmount: DischargeAmount?
    public var vulvaTurgor: VulvaTurgor?
    /// Schwanz zur Seite legen bei Berührung — Östrus-Signal.
    public var flagging: Bool?
    /// Duldung / Standhitze — das eindeutigste Östrus-Signal.
    public var standingHeat: Bool?
    public var attractsMales: Bool?
    /// Progesteron in ng/ml, falls klinisch bestimmt.
    public var progesteroneNgPerMl: Double?
    /// Anteil kornifizierter Zellen in der Vaginalzytologie, 0–100.
    public var cornificationPercent: Double?
    /// Anzeichen einer Scheinträchtigkeit im Diöstrus-Nachlauf.
    public var pseudopregnancySigns: Bool?

    public init(
        date: Date,
        dischargePresent: Bool? = nil,
        dischargeColor: DischargeColor? = nil,
        dischargeAmount: DischargeAmount? = nil,
        vulvaTurgor: VulvaTurgor? = nil,
        flagging: Bool? = nil,
        standingHeat: Bool? = nil,
        attractsMales: Bool? = nil,
        progesteroneNgPerMl: Double? = nil,
        cornificationPercent: Double? = nil,
        pseudopregnancySigns: Bool? = nil
    ) {
        self.date = date
        self.dischargePresent = dischargePresent
        self.dischargeColor = dischargeColor
        self.dischargeAmount = dischargeAmount
        self.vulvaTurgor = vulvaTurgor
        self.flagging = flagging
        self.standingHeat = standingHeat
        self.attractsMales = attractsMales
        self.progesteroneNgPerMl = progesteroneNgPerMl
        self.cornificationPercent = cornificationPercent
        self.pseudopregnancySigns = pseudopregnancySigns
    }

    /// Trägt dieser Eintrag überhaupt Information? Leere Signale dürfen eine
    /// Phasenschätzung nicht in Richtung „Anöstrus" ziehen.
    public var isEmpty: Bool {
        dischargePresent == nil && dischargeColor == nil && dischargeAmount == nil
            && vulvaTurgor == nil && flagging == nil && standingHeat == nil
            && attractsMales == nil && progesteroneNgPerMl == nil
            && cornificationPercent == nil && pseudopregnancySigns == nil
    }
}

// MARK: - Phasen

public enum CyclePhase: String, Sendable, Codable, CaseIterable, Hashable {
    case proestrus
    case estrus
    case diestrus
    case anestrus

    /// Typische Dauer laut Population (PRD §6.2).
    public var typicalDurationDays: Int {
        switch self {
        case .proestrus: return StudyConstants.proestrusTypicalDays
        case .estrus: return StudyConstants.estrusTypicalDays
        case .diestrus: return StudyConstants.diestrusTypicalDays
        case .anestrus: return StudyConstants.anestrusTypicalDays
        }
    }

    public var durationRangeDays: ClosedRange<Int> {
        switch self {
        case .proestrus:
            return StudyConstants.proestrusMinDays...StudyConstants.proestrusMaxDays
        case .estrus:
            return StudyConstants.estrusMinDays...StudyConstants.estrusMaxDays
        case .diestrus:
            return StudyConstants.diestrusMinDays...StudyConstants.diestrusMaxDays
        case .anestrus:
            return StudyConstants.anestrusMinDays...StudyConstants.anestrusMaxDays
        }
    }
}

/// Woher eine Phasenschätzung kommt. Beobachtungsbasierte Schätzungen sind
/// den Populations-Defaults immer vorzuziehen (PRD §6.2).
public enum PhaseEstimateSource: String, Sendable, Equatable, Hashable {
    /// Aus klinischen Werten (Progesteron/Zytologie) — belastbarste Quelle.
    case clinicalSignals
    /// Aus eigenen Beobachtungen (Ausfluss, Vulva, Duldung).
    case observedSignals
    /// Nur aus dem Tag im Zyklus über Populations-Defaults.
    case populationDefault
}

public struct PhaseEstimate: Sendable, Equatable, Hashable {
    public var phase: CyclePhase
    /// Tag im Zyklus, Tag 1 = Anker (erster Tag blutiger Ausfluss/Schwellung).
    public var dayInCycle: Int
    public var confidence: Confidence
    public var source: PhaseEstimateSource
    /// Erwartetes Ende der aktuellen Phase. Als Spanne, nie als exaktes Datum.
    public var expectedPhaseEnd: ClosedRange<Date>

    public init(
        phase: CyclePhase,
        dayInCycle: Int,
        confidence: Confidence,
        source: PhaseEstimateSource,
        expectedPhaseEnd: ClosedRange<Date>
    ) {
        self.phase = phase
        self.dayInCycle = dayInCycle
        self.confidence = confidence
        self.source = source
        self.expectedPhaseEnd = expectedPhaseEnd
    }
}

// MARK: - Intervall-Prognose

/// Eigene Zyklus-Historie: die geloggten Tag-1-Anker plus die Größenklasse,
/// die nur den Startwert beeinflusst.
public struct CycleHistory: Sendable, Equatable, Hashable {
    /// Tag-1-Anker, beliebige Reihenfolge — die Engine sortiert selbst.
    public var day1Anchors: [Date]
    public var sizeClass: DogSizeClass

    public init(day1Anchors: [Date], sizeClass: DogSizeClass = .medium) {
        self.day1Anchors = day1Anchors
        self.sizeClass = sizeClass
    }
}

/// Worauf eine Intervall-Prognose beruht.
public enum PredictionBasis: Sendable, Equatable, Hashable {
    /// Keine eigenen Intervalle: reiner Populationswert.
    case population
    /// Eigene Intervalle, gegen die Population gewichtet.
    /// `ownIntervalCount` ist die Anzahl Intervalle (= Anker − 1).
    case blended(ownIntervalCount: Int)
}

/// Prognose der nächsten Läufigkeit. Immer Spanne + Konfidenz, nie ein
/// nackter Punktwert (PRD §6).
public struct CyclePrediction: Sendable, Equatable, Hashable {
    /// Punktschätzung — in der UI nur zusammen mit `range` zeigen.
    public var expectedDate: Date
    /// Konfidenzband. Enthält `expectedDate` immer und ist nie leer.
    public var range: ClosedRange<Date>
    public var confidence: Confidence
    public var basis: PredictionBasis
    /// Die eigenen, aus den Ankern berechneten Intervalle in Tagen.
    public var observedIntervalDays: [Int]
    /// Das für die Prognose verwendete Intervall in Tagen (nach Shrinkage).
    public var effectiveIntervalDays: Double
    /// Halbe Breite des Bandes in Tagen — praktisch für die UI („± 21 Tage").
    public var bandHalfWidthDays: Double

    public init(
        expectedDate: Date,
        range: ClosedRange<Date>,
        confidence: Confidence,
        basis: PredictionBasis,
        observedIntervalDays: [Int],
        effectiveIntervalDays: Double,
        bandHalfWidthDays: Double
    ) {
        self.expectedDate = expectedDate
        self.range = range
        self.confidence = confidence
        self.basis = basis
        self.observedIntervalDays = observedIntervalDays
        self.effectiveIntervalDays = effectiveIntervalDays
        self.bandHalfWidthDays = bandHalfWidthDays
    }
}

// MARK: - Fruchtbares Fenster

/// Grobe Schätzung des Deckzeitpunkts. **Nur informativ.** Ohne Progesteronkurve
/// ist der Eisprung nicht zuverlässig bestimmbar (PRD §6.3) — `caveat` ist der
/// Text, den die UI zwingend mitanzeigen muss.
public struct FertileWindowEstimate: Sendable, Equatable, Hashable {
    public var window: ClosedRange<Date>
    /// Bester geschätzter Deckzeitpunkt innerhalb von `window`.
    public var optimalDate: Date
    public var confidence: Confidence
    /// Worauf die Schätzung beruht — Progesteron, Standhitze oder nur der Tag.
    public var source: PhaseEstimateSource
    public var caveat: String

    public init(
        window: ClosedRange<Date>,
        optimalDate: Date,
        confidence: Confidence,
        source: PhaseEstimateSource,
        caveat: String
    ) {
        self.window = window
        self.optimalDate = optimalDate
        self.confidence = confidence
        self.source = source
        self.caveat = caveat
    }
}
