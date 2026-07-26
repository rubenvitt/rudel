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
        case .clinicalSignals: return "klinische Werte"
        case .observedSignals: return "eigene Beobachtungen"
        case .populationDefault: return "Populationswerte"
        }
    }

    /// Grundlage einer Intervall-Prognose. Die Anzahl eigener Intervalle ist die
    /// eigentliche Aussage — sie erklärt die Konfidenz, ohne dass jemand die
    /// Shrinkage-Formel kennen muss.
    static func basis(_ basis: PredictionBasis) -> String {
        switch basis {
        case .population:
            return "nur Populationswerte"
        case .blended(let ownIntervalCount):
            return ownIntervalCount == 1 ? "1 eigenes Intervall" : "\(ownIntervalCount) eigene Intervalle"
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
        case .proestrus: return .red
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
        return "rechnerischer Termin liegt \(Format.dayCount(abs(days))) zurück"
    }

    /// Populationswert als Vergleich unter der eigenen Historie.
    static var populationIntervalSummary: String {
        "Ø \(StudyConstants.day1ToDay1IntervalDays) Tage"
            + " (\(StudyConstants.day1ToDay1IntervalMinDays)–\(StudyConstants.day1ToDay1IntervalMaxDays))"
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
            parts.append(present ? "Ausfluss" : "kein Ausfluss")
        }
        if let color = observation.dischargeColorValue {
            parts.append(Format.label(color))
        }
        if let amount = observation.dischargeAmountValue {
            parts.append("Menge: \(Format.label(amount))")
        }
        if let turgor = observation.vulvaTurgorValue {
            parts.append("Vulva: \(Format.label(turgor))")
        }
        if let standingHeat = observation.standingHeat {
            parts.append(standingHeat ? "Duldung" : "keine Duldung")
        }
        if let flagging = observation.flagging {
            parts.append(flagging ? "Flagging" : "kein Flagging")
        }
        if let attractsMales = observation.attractsMales {
            parts.append(attractsMales ? "Rüden interessiert" : "Rüden uninteressiert")
        }
        if let progesterone = observation.progesteroneNgPerMl {
            parts.append("Progesteron \(Format.progesterone(progesterone))")
        }
        if let cornification = observation.cornificationPercent {
            // `Format.percent` erwartet einen Anteil, das Modell speichert 0–100.
            parts.append("Kornifizierung \(Format.percent(cornification / 100))")
        }
        return parts
    }
}
