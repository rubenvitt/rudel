import Charts
import RudelEngine
import SwiftData
import SwiftUI

/// Symptom-Historie, gruppiert nach Symptomtyp (PRD §5.4).
///
/// Die Gruppierung ist der eigentliche Zweck des Screens. Eine flache Liste nach
/// Datum zeigt nicht, dass die Ohrenentzündung zum vierten Mal in einem halben
/// Jahr auftritt — genau diese Wiederkehr ist aber die Information, die beim
/// Tierarzt zählt. Innerhalb der Gruppe steht deshalb der Verlauf als
/// Punktdiagramm über der Zeit, darunter die Einzeleinträge, jüngster zuerst.
struct SymptomHistorySection: View {
    let pet: Pet

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    /// Abfrage auf den Einträgen selbst, nicht über `pet.symptomEntries`: nur so
    /// aktualisiert sich die Liste zuverlässig, wenn im Sheet ein Eintrag
    /// angelegt wird. Gefiltert wird in Swift statt im `#Predicate` — die
    /// Datenmenge ist winzig, und ein Prädikat wäre hier nur eine Fehlerquelle.
    @Query(sort: \SymptomEntry.date, order: .reverse) private var allEntries: [SymptomEntry]

    private var petEntries: [SymptomEntry] {
        allEntries.filter { $0.pet?.id == pet.id }
    }

    var body: some View {
        if petEntries.isEmpty {
            RudelEmptyState(
                title: "Keine Symptome",
                detail: "Eine kleine Auffälligkeit, ein Foto, eine Beobachtung. Hier entsteht die Geschichte, die dir beim Tierarzt hilft.",
                symbol: "heart.text.square",
                actionTitle: "Symptom erfassen"
            ) {
                appState.present(.logSymptom(petID: pet.id))
            }
        } else {
            List {
                Section {
                    RudelFeatureHeading(
                        eyebrow: "GESUNDHEITSJOURNAL",
                        title: "Aufmerksam begleitet",
                        detail: "\(petEntries.count) \(petEntries.count == 1 ? "Beobachtung" : "Beobachtungen") für \(pet.name.isEmpty ? "dein Tier" : pet.name)",
                        symbol: "heart.text.square"
                    )
                    .rudelFeatureRow()
                }
                ForEach(groups) { group in
                    Section {
                        // Ein einzelner Punkt ist kein Verlauf — bei genau einem
                        // Eintrag bleibt das Diagramm weg.
                        if group.entries.count > 1 {
                            SymptomTimelineChart(entries: group.entries)
                                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 4, trailing: 16))
                        }
                        ForEach(group.entries) { entry in
                            NavigationLink {
                                SymptomDetailView(entry: entry)
                            } label: {
                                SymptomHistoryRow(entry: entry)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(entry)
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        SymptomGroupHeader(group: group, lastSeen: lastSeenText(group))
                    }
                }
            }
            .rudelListStyle()
        }
    }

    /// Gruppen nach `groupingKey`, innen und außen absteigend nach Datum:
    /// die Gruppe mit dem jüngsten Eintrag steht oben.
    private var groups: [SymptomGroup] {
        let sorted = petEntries.sorted { lhs, rhs in
            // Zwei Beobachtungen am gleichen Tag: die später erfasste zuerst.
            lhs.date == rhs.date ? lhs.loggedAt > rhs.loggedAt : lhs.date > rhs.date
        }
        return Dictionary(grouping: sorted, by: \.groupingKey)
            .values
            .compactMap { (entries: [SymptomEntry]) -> SymptomGroup? in
                guard let newest = entries.first else { return nil }
                return SymptomGroup(
                    id: newest.groupingKey,
                    name: newest.displayName,
                    symbolName: newest.typeValue.symbolName,
                    entries: entries
                )
            }
            .sorted { $0.lastDate > $1.lastDate }
    }

    private func lastSeenText(_ group: SymptomGroup) -> String {
        let days = appState.dayMath.days(from: group.lastDate, to: Date())
        return Format.relativePast(days: days)
    }

    /// Journal-Prinzip (PRD §8): korrigiert wird durch Löschen und Neuerfassen,
    /// nie durch Bearbeiten.
    private func delete(_ entry: SymptomEntry) {
        context.delete(entry)
        try? context.save()
    }
}

/// Ein Symptomtyp mit allen seinen Beobachtungen.
private struct SymptomGroup: Identifiable {
    let id: String
    let name: String
    let symbolName: String
    /// Absteigend nach Datum.
    let entries: [SymptomEntry]

    var lastDate: Date { entries.first?.date ?? .distantPast }
}

private struct SymptomGroupHeader: View {
    let group: SymptomGroup
    let lastSeen: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(group.name, systemImage: group.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text("\(group.entries.count) × · zuletzt \(lastSeen)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Symptomnamen sind Substantive, keine Rubrik — die
        // Großbuchstaben-Voreinstellung gruppierter Listen passt hier nicht.
        .textCase(nil)
        .padding(.bottom, 2)
    }
}

/// Verlauf eines Symptomtyps: Zeitpunkt auf der X-Achse, Schweregrad auf der Y.
///
/// Bewusst als Punkte ohne Verbindungslinie: zwischen zwei Beobachtungen liegt
/// kein gemessener Zustand, den man interpolieren dürfte. Eine Linie würde
/// behaupten, das Symptom sei durchgehend vorhanden gewesen.
private struct SymptomTimelineChart: View {
    let entries: [SymptomEntry]

    var body: some View {
        Chart(entries) { entry in
            PointMark(
                x: .value("Datum", entry.date),
                y: .value("Schweregrad", Double(entry.severityValue.rawValue))
            )
            .foregroundStyle(SymptomStyle.tint(entry.severityValue))
            .symbolSize(90)
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0.5...3.5)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Format.shortDate(date))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [1.0, 2.0, 3.0]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let raw = value.as(Double.self),
                       let severity = SymptomSeverity(rawValue: Int(raw)) {
                        Text(severity.label)
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(height: 116)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Verlauf")
        .accessibilityValue(accessibilitySummary)
    }

    /// Rand links und rechts, damit die äußeren Punkte nicht an der Achse
    /// kleben. Liegen alle Beobachtungen am selben Tag, wird ein künstliches
    /// Fenster von einer Woche aufgespannt — sonst kollabiert die Skala.
    private var xDomain: ClosedRange<Date> {
        let dates = entries.map(\.date)
        let lower = dates.min() ?? Date()
        let upper = dates.max() ?? Date()
        let span = upper.timeIntervalSince(lower)
        guard span > 0 else {
            let halfWeek: TimeInterval = 3.5 * 86_400
            return lower.addingTimeInterval(-halfWeek)...upper.addingTimeInterval(halfWeek)
        }
        let padding = span * 0.08
        return lower.addingTimeInterval(-padding)...upper.addingTimeInterval(padding)
    }

    private var accessibilitySummary: String {
        let parts = entries.prefix(6).map { entry in
            "\(Format.shortDate(entry.date)) \(entry.severityValue.label)"
        }
        return parts.joined(separator: ", ")
    }
}

private struct SymptomHistoryRow: View {
    let entry: SymptomEntry

    var body: some View {
        HStack(spacing: 12) {
            if let data = entry.photoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Format.date(entry.date))
                        .font(.subheadline.weight(.medium))
                    SymptomSeverityTag(severity: entry.severityValue)
                }
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let treatment = entry.linkedTreatment {
                    Label(treatmentName(treatment), systemImage: "pills")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Detailansicht eines Eintrags. Zeigt das Foto groß — der Grund, warum die
/// Zeile überhaupt antippbar ist.
private struct SymptomDetailView: View {
    let entry: SymptomEntry

    var body: some View {
        List {
            if let data = entry.photoData, let image = UIImage(data: data) {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 460)
                        .accessibilityLabel("Foto zur Beobachtung")
                }
                .listRowInsets(EdgeInsets())
            }

            Section {
                LabeledValueRow(
                    label: "Datum",
                    value: Format.date(entry.date),
                    systemImage: "calendar"
                )
                LabeledValueRow(
                    label: "Schweregrad",
                    value: entry.severityValue.label,
                    systemImage: "gauge.with.dots.needle.bottom.50percent"
                )
                if let treatment = entry.linkedTreatment {
                    LabeledValueRow(
                        label: "Behandlung",
                        value: treatmentName(treatment),
                        systemImage: "pills"
                    )
                }
                LabeledValueRow(
                    label: "Erfasst",
                    value: Format.dateTime(entry.loggedAt),
                    systemImage: "square.and.pencil"
                )
            } footer: {
                // Journal-Prinzip (PRD §8): Einträge werden nicht bearbeitet.
                // Ein Tippfehler wird gelöscht und neu erfasst, damit die
                // Historie nicht stillschweigend umgeschrieben wird.
                //
                // Gelöscht wird bewusst nur in der Liste: ein Löschen-Knopf hier
                // müsste das Objekt entfernen, auf dem diese Ansicht noch steht.
                Text("Einträge lassen sich nicht bearbeiten. Zum Korrigieren in der Liste nach links wischen und neu erfassen.")
            }

            if !entry.note.isEmpty {
                Section("Notiz") {
                    Text(entry.note)
                }
            }
        }
        .rudelListStyle()
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Anzeigename einer verknüpften Behandlung: Präparat, sonst die Gattung.
private func treatmentName(_ plan: MedicationPlan) -> String {
    plan.productName.isEmpty ? Format.label(plan.kindValue) : plan.productName
}
