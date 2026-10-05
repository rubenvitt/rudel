import Charts
import SwiftData
import SwiftUI

/// Gewichtsverlauf (PRD §5.5).
///
/// Oben der letzte Wert groß mit der Veränderung gegenüber dem vorletzten,
/// darunter die Kurve, darunter die Einzeleinträge. Die Reihenfolge folgt der
/// Frage, mit der man den Screen öffnet: „Wie schwer ist sie jetzt, und geht es
/// hoch oder runter?"
struct WeightHistorySection: View {
    let pet: Pet

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    /// Abfrage auf den Einträgen selbst, nicht über `pet.weightEntries`: nur so
    /// aktualisiert sich der Verlauf zuverlässig, wenn im Sheet gewogen wird.
    /// Gefiltert wird in Swift — bei einstelliger Tierzahl billiger als jedes
    /// Prädikat, und ohne dessen Fallstricke.
    @Query(sort: \WeightEntry.date) private var allEntries: [WeightEntry]

    var body: some View {
        if entries.isEmpty {
            RudelEmptyState(
                title: "Kein Gewicht",
                detail: "Wiege \(petName) und halte den ersten Wert fest. Mit dem zweiten Eintrag beginnt euer Gewichtsverlauf.",
                symbol: "scalemass",
                actionTitle: "Gewicht erfassen"
            ) {
                appState.present(.logWeight(petID: pet.id))
            }
        } else {
            List {
                Section {
                    latestValue
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RudelTheme.softSage, in: .rect(cornerRadius: RudelTheme.cardRadius))
                        .rudelFeatureRow()
                }

                Section("Verlauf") {
                    chartOrHint
                }

                Section("Einträge") {
                    ForEach(Array(entries.reversed())) { entry in
                        WeightHistoryRow(entry: entry)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(entry)
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .rudelListStyle()
        }
    }

    // MARK: Daten

    /// Aufsteigend — so liest der Chart die Zeitachse.
    private var entries: [WeightEntry] {
        allEntries
            .filter { $0.pet?.id == pet.id }
            .sorted { lhs, rhs in
                lhs.date == rhs.date ? lhs.loggedAt < rhs.loggedAt : lhs.date < rhs.date
            }
    }

    private var petName: String {
        pet.name.isEmpty ? "dein Tier" : pet.name
    }

    /// Zielbereich, nur wenn beide Grenzen sinnvoll gesetzt sind (`0` heißt
    /// „nicht gesetzt", siehe `Pet`). Eine halbe Spanne ist kein Bereich und
    /// wird stattdessen als Text unter dem Wert angezeigt.
    private var band: ClosedRange<Double>? {
        let lower = pet.weightTargetMinKg
        let upper = pet.weightTargetMaxKg
        guard lower > 0, upper > 0, upper >= lower else { return nil }
        return lower...upper
    }

    // MARK: Bausteine

    @ViewBuilder
    private var latestValue: some View {
        if let latest = entries.last {
            VStack(alignment: .leading, spacing: 6) {
                Label("ZULETZT GEWOGEN", systemImage: "scalemass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RudelTheme.muted)
                    .padding(.bottom, 8)
                Text(Format.weight(latest.valueKg))
                    .font(RudelTheme.display())
                    .foregroundStyle(RudelTheme.ink)

                Text("Gewogen \(Format.date(latest.date))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let trend {
                    // Bewusst neutral gefärbt: ob Zunahme gut oder schlecht ist,
                    // weiß die App ohne Zielbereich nicht — eine rote Zahl wäre
                    // eine Bewertung, die ihr nicht zusteht.
                    Label(trend.text, systemImage: trend.symbolName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let targetStatus {
                    Label(targetStatus.text, systemImage: targetStatus.symbolName)
                        .font(.subheadline)
                        .foregroundStyle(targetStatus.tint)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var chartOrHint: some View {
        if entries.count < 2 {
            ContentUnavailableView {
                Label("Noch kein Verlauf", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Ein zweites Wiegen genügt, dann wird die Kurve gezeichnet.")
            }
            .frame(maxWidth: .infinity)
        } else {
            WeightChart(entries: entries, band: band)
                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 16))
        }
    }

    // MARK: Trend und Zielbereich

    private struct Trend {
        let symbolName: String
        let text: String
    }

    private var trend: Trend? {
        guard entries.count >= 2 else { return nil }
        let latest = entries[entries.count - 1]
        let previous = entries[entries.count - 2]
        let delta = latest.valueKg - previous.valueKg
        let since = Format.shortDate(previous.date)

        // Angezeigt wird auf zwei Dezimalstellen. Alles darunter ist Rauschen
        // der Waage und wird nicht als Richtung behauptet.
        guard abs(delta) >= 0.005 else {
            return Trend(symbolName: "arrow.right", text: "unverändert seit \(since)")
        }
        return Trend(
            symbolName: delta > 0 ? "arrow.up.right" : "arrow.down.right",
            text: "\(delta > 0 ? "+" : "−")\(Format.weight(abs(delta))) seit \(since)"
        )
    }

    private var targetStatus: (text: String, tint: Color, symbolName: String)? {
        guard let latest = entries.last else { return nil }

        if let band {
            let range = "\(band.lowerBound.formatted(.number.precision(.fractionLength(0...2))))–\(Format.weight(band.upperBound))"
            if band.contains(latest.valueKg) {
                return ("Im Zielbereich \(range)", .green, "checkmark.circle.fill")
            }
            let direction = latest.valueKg < band.lowerBound ? "Unter" : "Über"
            return ("\(direction) dem Zielbereich \(range)", .orange, "exclamationmark.circle.fill")
        }

        if pet.weightTargetMinKg > 0 {
            return ("Zielgewicht mindestens \(Format.weight(pet.weightTargetMinKg))", .secondary, "target")
        }
        if pet.weightTargetMaxKg > 0 {
            return ("Zielgewicht höchstens \(Format.weight(pet.weightTargetMaxKg))", .secondary, "target")
        }
        return nil
    }

    /// Journal-Prinzip (PRD §8): korrigiert wird durch Löschen und Neuerfassen.
    private func delete(_ entry: WeightEntry) {
        context.delete(entry)
        try? context.save()
    }
}

/// Die Kurve. Zielbereich als Band im Hintergrund, damit man auf einen Blick
/// sieht, ob der Verlauf ihn verlässt.
private struct WeightChart: View {
    /// Aufsteigend nach Datum.
    let entries: [WeightEntry]
    let band: ClosedRange<Double>?

    var body: some View {
        Chart {
            if let band {
                RectangleMark(
                    xStart: .value("Von", xDomain.lowerBound),
                    xEnd: .value("Bis", xDomain.upperBound),
                    yStart: .value("Zielbereich ab", band.lowerBound),
                    yEnd: .value("Zielbereich bis", band.upperBound)
                )
                .foregroundStyle(Color.green.opacity(0.14))
            }
            ForEach(entries) { entry in
                LineMark(
                    x: .value("Datum", entry.date),
                    y: .value("Gewicht", entry.valueKg)
                )
                .foregroundStyle(Color.accentColor)
                .symbol(.circle)
                .symbolSize(50)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Format.shortDate(date))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let kilograms = value.as(Double.self) {
                        Text(Format.weight(kilograms))
                    }
                }
            }
        }
        .frame(height: 210)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gewichtsverlauf")
        .accessibilityValue(accessibilitySummary)
    }

    /// Etwas Luft an den Rändern, damit der erste und letzte Punkt nicht auf der
    /// Achse liegen. Bei zwei Einträgen am selben Tag würde die Skala sonst
    /// kollabieren — dann wird ein Fenster von einer Woche aufgespannt.
    private var xDomain: ClosedRange<Date> {
        let dates = entries.map(\.date)
        let lower = dates.min() ?? Date()
        let upper = dates.max() ?? Date()
        let span = upper.timeIntervalSince(lower)
        guard span > 0 else {
            let halfWeek: TimeInterval = 3.5 * 86_400
            return lower.addingTimeInterval(-halfWeek)...upper.addingTimeInterval(halfWeek)
        }
        let padding = span * 0.05
        return lower.addingTimeInterval(-padding)...upper.addingTimeInterval(padding)
    }

    /// Y-Fenster über alle Werte **und** den Zielbereich — ein Band, das aus dem
    /// Bild läuft, wäre schlimmer als keines.
    private var yDomain: ClosedRange<Double> {
        var lower = entries.map(\.valueKg).min() ?? 0
        var upper = entries.map(\.valueKg).max() ?? 1
        if let band {
            lower = min(lower, band.lowerBound)
            upper = max(upper, band.upperBound)
        }
        let middle = (lower + upper) / 2
        // Mindestens ein Kilo Fenster: sonst blähen 100 Gramm Tagesschwankung
        // die Kurve zu einem Gebirge auf.
        let half = max((upper - lower) / 2, 0.5) * 1.25
        return max(0, middle - half)...(middle + half)
    }

    private var accessibilitySummary: String {
        guard let first = entries.first, let last = entries.last else { return "" }
        return "\(entries.count) Einträge, \(Format.weight(first.valueKg)) am \(Format.date(first.date)) bis \(Format.weight(last.valueKg)) am \(Format.date(last.date))"
    }
}

private struct WeightHistoryRow: View {
    let entry: WeightEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.weight(entry.valueKg))
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(Format.date(entry.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// BCS und Futtermenge sind optional (PRD §5.5) — die Zeile erscheint nur,
    /// wenn wirklich etwas erfasst wurde. In einer Textzeile statt in einer
    /// HStack, damit große Schriftgrade umbrechen statt abzuschneiden.
    private var detail: String? {
        var parts: [String] = []
        if let score = entry.bodyConditionScoreValue {
            parts.append(score.label)
        }
        if let food = entry.foodAmountGrams, food > 0 {
            parts.append("\(Format.grams(food)) Futter")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
