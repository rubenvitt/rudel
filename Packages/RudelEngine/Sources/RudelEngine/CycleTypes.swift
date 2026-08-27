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

/// Turgor der Vulva — **eine Tastbeobachtung**, nicht das, was man von außen
/// sieht. Prall im Proöstrus, im Östrus weicher und nachgiebiger; das
/// Weicherwerden korreliert mit der Duldungsbereitschaft.
///
/// Bewusst getrennt von `PhaseSignals.vulvaSwellingVisible`: die *Schwellung*
/// ist sichtbar, die *Konsistenz* nicht. Wer nicht täglich palpiert, füllt
/// dieses Feld nie — und darf trotzdem eine brauchbare Einschätzung bekommen.
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

    // MARK: Alltagszeichen
    //
    // Die folgenden drei Felder sind **ohne Anfassen** zu erheben — sie sind
    // deshalb die einzigen, die in der Praxis lückenlos anfallen. Genau deshalb
    // müssen sie mit besonderer Vorsicht ausgewertet werden: keines von ihnen
    // trennt Proöstrus von Östrus.
    //
    // - Vermehrtes Urinieren/Markieren setzt mit dem Proöstrus ein und hält
    //   über den Östrus an.
    // - Vermehrtes Belecken folgt dem Ausfluss und existiert in beiden Phasen.
    // - Die sichtbare Schwellung ist im Proöstrus maximal und *nimmt* zum
    //   Östrus hin oft wieder *ab* — als Phasenmarker wäre sie damit eher ein
    //   Proöstrus-Hinweis, was in die falsche Richtung zeigt.
    //
    // Konsequenz, die `CyclePhaseEstimator` und `CriticalDaysAdvisor` beide
    // einhalten: Diese Felder benennen **keine Phase** und ziehen die Stufe
    // `.critical` **nicht** vor. Sie belegen nur, dass überhaupt eine
    // Läufigkeit läuft (`indicatesActiveHeat`).

    /// Häufigeres Urinieren bzw. vermehrtes Markieren.
    public var frequentUrination: Bool?
    /// Vermehrtes Belecken des Genitalbereichs — Proxy für Ausfluss, wenn
    /// dessen Farbe und Menge nicht zu beurteilen sind.
    public var genitalLicking: Bool?
    /// Von außen sichtbare Schwellung der Vulva. Reine Sichtbeobachtung —
    /// die Konsistenz steht in `vulvaTurgor`.
    public var vulvaSwellingVisible: Bool?

    // MARK: Duldungsreflex

    /// **Flagging**: der Schwanz wird bei Berührung von Kruppe oder Damm zur
    /// Seite gelegt. Ein *Bestandteil* des Duldungsreflexes, ohne Rüden
    /// auslösbar — und er tritt früher auf als die volle Duldung, teils schon im
    /// späten Proöstrus. Damit weniger spezifisch als `standingHeat`, aber
    /// früher verfügbar; für eine Risikoeinschätzung ist genau das die
    /// nützlichere Eigenschaft.
    public var flagging: Bool?

    /// **Duldung / Standhitze**: der vollständige Reflex — sie bleibt stehen,
    /// stemmt sich fest, hebt die Hinterhand und legt den Schwanz zur Seite.
    /// Das eindeutigste nicht-klinische Östrus-Signal.
    ///
    /// Auslösbar auch ohne Rüden, durch festen Druck auf die Lendenpartie:
    /// duldet sie, versteift sie sich statt auszuweichen. Das Feld setzt also
    /// **keinen** Deckpartner voraus.
    public var standingHeat: Bool?

    /// Rüden zeigen Interesse. Trennt die Phasen nicht — Rüden reagieren schon
    /// im Proöstrus.
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
        frequentUrination: Bool? = nil,
        genitalLicking: Bool? = nil,
        vulvaSwellingVisible: Bool? = nil,
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
        self.frequentUrination = frequentUrination
        self.genitalLicking = genitalLicking
        self.vulvaSwellingVisible = vulvaSwellingVisible
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
            && vulvaTurgor == nil && frequentUrination == nil && genitalLicking == nil
            && vulvaSwellingVisible == nil && flagging == nil && standingHeat == nil
            && attractsMales == nil && progesteroneNgPerMl == nil
            && cornificationPercent == nil && pseudopregnancySigns == nil
    }

    /// Belegt dieser Eintrag, dass eine Läufigkeit **läuft** — ohne zu sagen,
    /// in welcher Phase?
    ///
    /// Bewusst getrennt von der Phasenschätzung: Alltagszeichen beantworten
    /// „läuft überhaupt etwas?" zuverlässig und „welche Phase?" gar nicht. Wer
    /// beides in eine Regel packt, bekommt entweder eine Phasenaussage ohne
    /// Grundlage oder verschenkt die einzige Information, die lückenlos anfällt.
    ///
    /// `false`-Werte zählen nicht: „kein Ausfluss" ist ein Befund, aber kein
    /// Beleg für eine laufende Läufigkeit.
    public var indicatesActiveHeat: Bool {
        if standingHeat == true || flagging == true { return true }
        if frequentUrination == true || genitalLicking == true { return true }
        if vulvaSwellingVisible == true { return true }
        if dischargePresent == true { return true }
        if let color = dischargeColor, color != .clear { return true }
        if let turgor = vulvaTurgor, turgor != .normal { return true }
        return false
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
