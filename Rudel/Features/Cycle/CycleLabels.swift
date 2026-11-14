import RudelEngine
import SwiftUI

/// Zyklus-Beschriftungen, die `Format` nicht kennt.
///
/// Absichtlich hier und nicht in `Formatters.swift`: es sind Begriffe, die nur
/// die Zyklus-Screens brauchen — woher eine Schätzung stammt, worauf eine
/// Prognose beruht, wie eine Beobachtung in einer Zeile zusammengefasst wird.
enum CycleLabel {

    // MARK: Herkunft einer Schätzung

    /// Quelle einer Schätzung. Steht immer neben der Konfidenz: „hoch" bedeutet
    /// etwas anderes, wenn es aus einem Progesteronwert statt aus dem Kalender
    /// kommt.
    static func source(_ source: PhaseEstimateSource) -> String {
        switch source {
        case .clinicalSignals: return String(localized: "klinische Werte", comment: "Quelle einer Zyklus-Schätzung, steht neben der Konfidenz")
        case .observedSignals: return String(localized: "eigene Beobachtungen", comment: "Quelle einer Zyklus-Schätzung, steht neben der Konfidenz")
        case .populationDefault: return String(localized: "Populationswerte", comment: "Quelle einer Zyklus-Schätzung: Durchschnittswerte aus Studien, steht neben der Konfidenz")
        }
    }

    /// Grundlage einer Intervall-Prognose. Die Anzahl eigener Intervalle ist die
    /// eigentliche Aussage — sie erklärt die Konfidenz, ohne dass jemand die
    /// Shrinkage-Formel kennen muss.
    static func basis(_ basis: PredictionBasis) -> String {
        switch basis {
        case .population:
            return String(localized: "nur Populationswerte", comment: "Grundlage der Läufigkeits-Prognose: nur Studien-Durchschnittswerte")
        case .blended(let ownIntervalCount):
            return String(
                localized: "\(ownIntervalCount) eigene Intervalle",
                comment: "Grundlage der Prognose: Anzahl gemessener Abstände (Tag 1 zu Tag 1) dieses Tiers"
            )
        }
    }

    // MARK: Phasen

    static func symbolName(_ phase: CyclePhase) -> String {
        switch phase {
        case .proestrus: return "drop.fill"
        case .estrus: return "heart.fill"
        case .diestrus: return "hourglass"
        case .anestrus: return "moon.zzz.fill"
        }
    }

    static func tint(_ phase: CyclePhase) -> Color {
        switch phase {
        case .proestrus: return RudelTheme.danger
        case .estrus: return .pink
        case .diestrus: return .indigo
        case .anestrus: return .secondary
        }
    }

    // MARK: Prognose-Zeitpunkt

    /// Zeitliche Einordnung einer Zyklus-Prognose.
    ///
    /// Bewusst nicht `Format.relativeDue` für vergangene Termine: eine
    /// Läufigkeit wird nicht „überfällig" — sie kommt später als gerechnet, und
    /// genau das ist bei einer Spanne von mehreren Wochen der Normalfall.
    static func predictionTiming(days: Int) -> String {
        if days >= 0 { return Format.relativeDue(days: days) }
        return String(
            localized: "rechnerischer Termin liegt \(abs(days)) Tage zurück",
            comment: "Prognostizierter Läufigkeitsbeginn liegt in der Vergangenheit; bewusst nicht „überfällig“"
        )
    }

    /// Populationswert als Vergleich unter der eigenen Historie.
    static var populationIntervalSummary: String {
        String(
            localized: "Ø \(StudyConstants.day1ToDay1IntervalDays) Tage (\(StudyConstants.day1ToDay1IntervalMinDays)–\(StudyConstants.day1ToDay1IntervalMaxDays))",
            comment: "Populations-Durchschnitt des Läufigkeitsabstands mit Spanne, z. B. „Ø 210 Tage (135–300)“"
        )
    }

    // MARK: Risikostufe

    /// Kurzname der Stufe. Bewusst ohne Phasenbegriffe — die Stufe beantwortet
    /// „wie sehr aufpassen?", nicht „welche Phase?".
    static func riskTitle(_ risk: HeatRiskLevel) -> String {
        switch risk {
        case .elevated: return String(localized: "Erhöhte Aufmerksamkeit", comment: "Risikostufe der Läufigkeit: Hündin gut beaufsichtigen")
        case .critical: return String(localized: "Kritische Tage", comment: "Risikostufe der Läufigkeit: Deckung möglich")
        case .subsiding: return String(localized: "Klingt ab", comment: "Risikostufe der Läufigkeit: Läufigkeit klingt ab")
        }
    }

    /// Die Antwort auf die Frage, die man morgens hat, in einem Halbsatz.
    static func riskHeadline(_ risk: HeatRiskLevel) -> String {
        switch risk {
        case .elevated: return String(localized: "Deckung noch nicht möglich", comment: "Kurzantwort zur Risikostufe der Läufigkeit")
        case .critical: return String(localized: "Deckung möglich", comment: "Kurzantwort zur Risikostufe der Läufigkeit")
        case .subsiding: return String(localized: "Restrisiko", comment: "Kurzantwort zur Risikostufe der Läufigkeit: Deckung noch nicht ausgeschlossen")
        }
    }

    static func riskSymbolName(_ risk: HeatRiskLevel) -> String {
        switch risk {
        case .elevated: return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .subsiding: return "arrow.down.circle.fill"
        }
    }

    static func riskTint(_ risk: HeatRiskLevel) -> Color {
        switch risk {
        case .elevated: return RudelTheme.warning
        case .critical: return RudelTheme.danger
        case .subsiding: return RudelTheme.warning
        }
    }

    // MARK: Beobachtungen

    /// Die **gesetzten** Felder einer Beobachtung als kurze Textbausteine.
    ///
    /// `nil` wird weggelassen, `false` ausgeschrieben („kein Ausfluss"). Der
    /// Unterschied ist die ganze Aussage: nicht beobachtet ist keine Beobachtung,
    /// und wer das in der Historie nicht auseinanderhalten kann, traut später
    /// der Phasenschätzung nicht.
    static func observationSummary(_ observation: CycleObservation) -> [String] {
        var parts: [String] = []
        if let present = observation.dischargePresent {
            parts.append(present ? String(localized: "Ausfluss") : String(localized: "kein Ausfluss"))
        }
        if let color = observation.dischargeColorValue {
            parts.append(Format.label(color))
        }
        if let amount = observation.dischargeAmountValue {
            parts.append(String(localized: "Menge: \(Format.label(amount))", comment: "Menge des Ausflusses"))
        }
        if let turgor = observation.vulvaTurgorValue {
            parts.append(String(localized: "Vulva: \(Format.label(turgor))", comment: "Konsistenz der Vulva"))
        }
        if let swollen = observation.vulvaSwellingVisible {
            parts.append(swollen ? String(localized: "sichtbar geschwollen") : String(localized: "keine sichtbare Schwellung"))
        }
        if let urination = observation.frequentUrination {
            parts.append(urination ? String(localized: "häufiges Urinieren") : String(localized: "Urinieren unauffällig"))
        }
        if let licking = observation.genitalLicking {
            parts.append(licking ? String(localized: "vermehrtes Belecken") : String(localized: "kein vermehrtes Belecken"))
        }
        if let standingHeat = observation.standingHeat {
            parts.append(standingHeat ? String(localized: "Duldung") : String(localized: "keine Duldung"))
        }
        if let flagging = observation.flagging {
            parts.append(flagging ? String(localized: "Flagging") : String(localized: "kein Flagging"))
        }
        if let attractsMales = observation.attractsMales {
            parts.append(attractsMales ? String(localized: "Rüden interessiert") : String(localized: "Rüden uninteressiert"))
        }
        if let progesterone = observation.progesteroneNgPerMl {
            parts.append(String(localized: "Progesteron \(Format.progesterone(progesterone))"))
        }
        if let cornification = observation.cornificationPercent {
            // `Format.percent` erwartet einen Anteil, das Modell speichert 0–100.
            parts.append(String(localized: "Kornifizierung \(Format.percent(cornification / 100))"))
        }
        return parts
    }
}
