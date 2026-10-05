import SwiftData
import SwiftUI

/// Tierarzt-Bereich im Gesundheit-Tab: anstehende Termine, Verlauf, Praxen.
///
/// Termine gehören zum Tier, Praxen allen Tieren — deshalb stehen hier alle
/// Praxen, nicht nur die des gewählten Tiers.
struct VetSection: View {
    let pet: Pet

    @Environment(AppState.self) private var appState

    /// Abfrage auf den Terminen selbst statt über `pet.vetAppointments`: nur so
    /// aktualisiert sich die Liste zuverlässig, wenn ein Sheet speichert.
    @Query(sort: \VetAppointment.date) private var allAppointments: [VetAppointment]
    @Query(sort: \VetPractice.name) private var practices: [VetPractice]

    private var petAppointments: [VetAppointment] {
        allAppointments.filter { $0.pet?.id == pet.id }
    }

    private var upcoming: [VetAppointment] {
        petAppointments.filter(\.isOpen)
    }

    /// Neueste zuerst: im Verlauf sucht man meist den letzten Besuch.
    private var history: [VetAppointment] {
        petAppointments.filter { !$0.isOpen }.sorted { $0.date > $1.date }
    }

    private var petName: String { pet.name.isEmpty ? "dein Tier" : pet.name }

    var body: some View {
        // Der Leerzustand nur, wenn es weder Termine noch Praxen gibt — sonst
        // wären angelegte Praxen nicht mehr erreichbar.
        if petAppointments.isEmpty && practices.isEmpty {
            RudelEmptyState(
                title: "Noch keine Termine",
                detail: "Termine, Befunde und Kosten an einer Stelle. Dazu die Praxen mit Telefonnummer, für den Notfall.",
                symbol: "stethoscope",
                actionTitle: "Termin anlegen"
            ) {
                appState.present(.editAppointment(appointmentID: nil, petID: pet.id))
            }
        } else {
            List {
                Section {
                    RudelFeatureHeading(
                        eyebrow: "TIERARZT",
                        title: "Termine & Praxen",
                        detail: headingDetail,
                        symbol: "stethoscope"
                    )
                    .rudelFeatureRow()
                }
                Section {
                    VetReportShareLink(petID: pet.id, petName: pet.name)
                }
                upcomingSection
                if !history.isEmpty {
                    historySection
                }
                practicesSection
            }
            .rudelListStyle()
        }
    }

    private var headingDetail: String {
        let now = Date()
        if let next = upcoming.first(where: { $0.date >= now }) {
            return "Nächster Termin: \(Format.dateTime(next.date))"
        }
        let unfinished = upcoming.count
        guard unfinished > 0 else { return "Kein Termin geplant für \(petName)" }
        return unfinished == 1 ? "1 Termin abzuschließen" : "\(unfinished) Termine abzuschließen"
    }

    // MARK: - Abschnitte

    private var upcomingSection: some View {
        Section {
            if upcoming.isEmpty {
                Button {
                    appState.present(.editAppointment(appointmentID: nil, petID: pet.id))
                } label: {
                    Label("Termin anlegen", systemImage: "plus.circle")
                }
            } else {
                ForEach(upcoming) { appointment in
                    Button {
                        appState.present(.editAppointment(appointmentID: appointment.id, petID: pet.id))
                    } label: {
                        VetAppointmentRow(appointment: appointment, isPastOpen: appointment.date < Date())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("upcoming-appointment")
                }
            }
        } header: {
            RudelSectionHeading(title: "Anstehend")
        }
    }

    private var historySection: some View {
        Section {
            ForEach(history) { appointment in
                Button {
                    appState.present(.editAppointment(appointmentID: appointment.id, petID: pet.id))
                } label: {
                    VetAppointmentRow(appointment: appointment, isPastOpen: false)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("past-appointment")
            }
        } header: {
            RudelSectionHeading(title: "Verlauf")
        } footer: {
            if let costLine {
                Text(costLine)
            }
        }
    }

    /// Summe der erfassten Kosten im laufenden Kalenderjahr. Nur erledigte
    /// Termine — eine abgesagte Behandlung hat nichts gekostet.
    private var costLine: String? {
        let calendar = appState.dayMath.calendar
        let year = calendar.component(.year, from: Date())
        let total = history
            .filter { $0.statusValue == .done && calendar.component(.year, from: $0.date) == year }
            .reduce(0) { $0 + $1.costEuro }
        guard total > 0 else { return nil }
        return "Erfasste Kosten \(year): \(VetDisplay.euro(total))"
    }

    private var practicesSection: some View {
        Section {
            if practices.isEmpty {
                Button {
                    appState.present(.editPractice(practiceID: nil))
                } label: {
                    Label("Praxis anlegen", systemImage: "plus.circle")
                }
            } else {
                ForEach(practices) { practice in
                    VetPracticeRow(
                        practice: practice,
                        isPrimary: pet.primaryPractice?.id == practice.id
                    ) {
                        appState.present(.editPractice(practiceID: practice.id))
                    }
                }
            }
        } header: {
            RudelSectionHeading(title: "Praxen")
        }
    }
}

/// Eine Terminzeile. Offene Termine in der Vergangenheit werden als
/// „Abschließen" markiert: bis zum Abschluss steht der Termin auch auf Heute.
private struct VetAppointmentRow: View {
    let appointment: VetAppointment
    let isPastOpen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RudelIcon(
                symbol: appointment.reasonValue.symbolName,
                fill: appointment.isOpen ? RudelTheme.softSage : RudelTheme.softApricot,
                size: 40
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(appointment.displayTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(RudelTheme.ink)
                    .strikethrough(appointment.statusValue == .cancelled)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(RudelTheme.muted)
                if let excerpt = findingsExcerpt {
                    Text(excerpt)
                        .font(.footnote)
                        .foregroundStyle(RudelTheme.muted)
                        .lineLimit(2)
                }
                statusLine
            }
            Spacer(minLength: 0)
            if appointment.costEuro > 0 {
                Text(VetDisplay.euro(appointment.costEuro))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(RudelTheme.muted)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [Format.dateTime(appointment.date)]
        if let practice = appointment.practice {
            parts.append(VetDisplay.practiceName(practice))
        }
        return parts.joined(separator: " · ")
    }

    private var findingsExcerpt: String? {
        let trimmed = appointment.findings.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder
    private var statusLine: some View {
        if isPastOpen {
            Label("Termin abschließen", systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RudelTheme.warning)
        } else if appointment.statusValue == .cancelled {
            Label("Abgesagt", systemImage: "xmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RudelTheme.muted)
        } else if appointment.statusValue == .done {
            Label("Erledigt", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RudelTheme.success)
        }
    }
}

/// Eine Praxiszeile: Tippen bearbeitet, der Telefonknopf ruft an.
private struct VetPracticeRow: View {
    let practice: VetPractice
    let isPrimary: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(alignment: .top, spacing: 12) {
                    RudelIcon(
                        symbol: practice.isEmergencyClinic ? "cross.case.fill" : "building.2",
                        fill: practice.isEmergencyClinic ? RudelTheme.softApricot : RudelTheme.softSage,
                        size: 40
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(VetDisplay.practiceName(practice))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(RudelTheme.ink)
                        if let detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(RudelTheme.muted)
                        }
                        tags
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Praxis bearbeiten")

            VetCallButton(
                number: practice.phone,
                accessibilityName: "\(VetDisplay.practiceName(practice)) anrufen"
            )
        }
        .padding(.vertical, 4)
    }

    private var detail: String? {
        let parts = [practice.veterinarian, practice.phone]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var tags: some View {
        if isPrimary || practice.isEmergencyClinic {
            HStack(spacing: 6) {
                if isPrimary {
                    VetTag(title: "Haustierarzt", symbol: "house.fill")
                }
                if practice.isEmergencyClinic {
                    VetTag(title: "Notdienst", symbol: "cross.case.fill")
                }
            }
        }
    }
}

private struct VetTag: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RudelTheme.softSage, in: .capsule)
            .foregroundStyle(RudelTheme.accent)
    }
}
