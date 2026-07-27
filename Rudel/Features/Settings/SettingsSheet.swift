import RudelEngine
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Einstellungen: Erinnerungen, Diagnose, Datenschutz.
///
/// Vorwarnzeiten, Uhrzeit und Fenster werden sofort gespeichert, aber erst beim
/// Schließen neu geplant — bei jedem Stepper-Tipp bis zu 56 Requests neu zu
/// setzen wäre Verschwendung. Der Hauptschalter plant dagegen sofort um, weil
/// sein Ergebnis direkt darunter in der Diagnose steht.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    private let service = NotificationService()

    /// Nur um zu entscheiden, ob der Abschnitt zu den kritischen Tagen überhaupt
    /// Sinn hat: bei einem Kater oder einer kastrierten Hündin wäre er Ballast.
    @Query private var pets: [Pet]

    @State private var settings: AppSettings?
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var pendingCount = 0
    @State private var failures: [NotificationService.ScheduleFailure] = []
    @State private var statusMessage: String?
    @State private var isWorking = false
    @State private var lastSuccessAt: Date?
    /// Offene Änderung, die beim Schließen wirksam wird.
    @State private var needsReschedule = false

    /// Vorwarnzeiten zur Auswahl. 0 = am Fälligkeitstag selbst.
    private static let leadDayChoices = [14, 7, 3, 1, 0]

    var body: some View {
        NavigationStack {
            Group {
                if let settings {
                    form(settings)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Einstellungen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .sensoryFeedback(.success, trigger: lastSuccessAt)
        .task {
            let loaded = settings ?? AppSettings.loadOrCreate(in: context)
            settings = loaded
            await refreshDiagnostics()
        }
        .onDisappear {
            guard needsReschedule, let settings else { return }
            // Absichtlich nach dem Schließen: die Neuplanung darf das Sheet
            // nicht am Zugehen hindern.
            Task { await service.reschedule(context: context, settings: settings) }
        }
    }

    @ViewBuilder
    private func form(_ settings: AppSettings) -> some View {
        Form {
            notificationSection(settings)
            if settings.notificationsEnabled {
                leadDaysSection(settings)
                timeSection(settings)
                windowSection(settings)
                if pets.contains(where: { $0.tracksCycle }) {
                    criticalDaysSection(settings)
                }
            }
            diagnosticsSection(settings)
            if !failures.isEmpty {
                failureSection
            }
            privacySection
        }
    }

    // MARK: - Benachrichtigungen

    @ViewBuilder
    private func notificationSection(_ settings: AppSettings) -> some View {
        // `@Bindable` nur für die `$`-Bindings; gelesen wird über den Parameter.
        @Bindable var bound = settings

        Section {
            Toggle("Erinnerungen", isOn: $bound.notificationsEnabled)
                // Gesperrt, solange eine Neuplanung läuft: zwei überlappende
                // Durchläufe räumen sich gegenseitig die Requests ab, und der
                // spätere `removeAll` würde die Erinnerungen des früheren
                // löschen — sichtbar eingeschaltet, tatsächlich nichts gesetzt.
                .disabled(isWorking)
                .onChange(of: settings.notificationsEnabled) {
                    Task { await apply(settings) }
                }

            LabeledValueRow(
                label: "Systemberechtigung",
                value: authorizationLabel,
                systemImage: authorizationSymbol
            )

            switch authorization {
            case .denied:
                Label(
                    "iOS blockiert die Erinnerungen. Rudel kann erst wieder welche setzen, wenn du sie dort erlaubst.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("In den iOS-Einstellungen öffnen", systemImage: "arrow.up.forward.app")
                }

            case .notDetermined:
                Button {
                    Task {
                        authorization = await service.requestAuthorization()
                        await apply(settings)
                    }
                } label: {
                    Label("Erinnerungen erlauben", systemImage: "bell.badge")
                }

            default:
                EmptyView()
            }
        } header: {
            Text("Benachrichtigungen")
        } footer: {
            Text("Ohne Erinnerungen führt Rudel weiterhin jeden Eintrag — es meldet sich nur nicht von selbst.")
        }
    }

    // MARK: - Vorwarnzeiten

    // MARK: - Kritische Tage

    @ViewBuilder
    private func criticalDaysSection(_ settings: AppSettings) -> some View {
        @Bindable var bound = settings

        Section {
            Toggle("Kritische Tage", isOn: $bound.criticalDayRemindersEnabled)
                .onChange(of: settings.criticalDayRemindersEnabled) { needsReschedule = true }
        } header: {
            Text("Läufigkeit")
        } footer: {
            Text(
                settings.criticalDayRemindersEnabled
                    ? """
                    Während einer Läufigkeit kommt täglich ein Hinweis mit dem Tag im \
                    Zyklus. Ab dem Tag, an dem eine Deckung möglich wird, deutlicher \
                    formuliert — und mit Vorrang vor allen anderen Erinnerungen, weil \
                    sich dieser Tag nicht nachholen lässt.

                    Der Beginn ist bewusst früh angesetzt: der Übergang zur \
                    fruchtbaren Phase liegt im Mittel bei Tag 10, kann aber schon an \
                    Tag 4 einsetzen. Wer Beobachtungen erfasst, bekommt eine genauere \
                    Einschätzung; wer das Ende der Hitze einträgt, beendet die \
                    Hinweise früher.
                    """
                    : """
                    Während einer Läufigkeit kommen keine täglichen Hinweise. Die \
                    Prognose der nächsten Läufigkeit und die Phasenanzeige im \
                    Zyklus-Tab bleiben davon unberührt.
                    """
            )
        }
    }

    @ViewBuilder
    private func leadDaysSection(_ settings: AppSettings) -> some View {
        Section {
            ForEach(leadDayOptions(settings), id: \.self) { option in
                Toggle(Self.leadDayLabel(option), isOn: leadDayBinding(option, settings))
            }
        } header: {
            Text("Vorwarnzeiten")
        } footer: {
            Text(
                settings.leadDays.isEmpty
                    ? "Ohne Vorwarnzeit erinnert Rudel an keine Fälligkeit mehr. Einzelgaben eines Dauermedikaments werden weiterhin zu ihrer Gabezeit gemeldet."
                    : "Jede Vorwarnzeit erzeugt eine eigene Erinnerung — drei Werte heißt drei Mitteilungen pro Fälligkeit."
            )
        }
    }

    /// Die feste Auswahl, ergänzt um bereits gespeicherte Werte: sonst wäre eine
    /// Vorwarnzeit aus einer früheren Version unsichtbar, aber weiter wirksam.
    private func leadDayOptions(_ settings: AppSettings) -> [Int] {
        Set(Self.leadDayChoices).union(settings.leadDays).sorted(by: >)
    }

    private static func leadDayLabel(_ days: Int) -> String {
        days == 0 ? "Am Fälligkeitstag" : "\(Format.dayCount(days)) vorher"
    }

    private func leadDayBinding(_ option: Int, _ settings: AppSettings) -> Binding<Bool> {
        Binding(
            get: { settings.leadDays.contains(option) },
            set: { isOn in
                var values = Set(settings.leadDays)
                if isOn {
                    values.insert(option)
                } else {
                    values.remove(option)
                }
                // Absteigend, wie in `AppSettings` dokumentiert.
                settings.leadDays = values.sorted(by: >)
                markChanged()
            }
        )
    }

    // MARK: - Uhrzeit

    @ViewBuilder
    private func timeSection(_ settings: AppSettings) -> some View {
        Section {
            DatePicker(
                "Uhrzeit",
                selection: reminderTimeBinding(settings),
                displayedComponents: .hourAndMinute
            )
        } header: {
            Text("Uhrzeit der Erinnerungen")
        } footer: {
            Text("Gilt für Fälligkeiten. Einzelgaben eines Dauermedikaments melden sich zu den Zeiten aus ihrem Dosierschema.")
        }
    }

    /// Der `DatePicker` will ein `Date`, gespeichert werden Minuten nach
    /// Mitternacht. Das Datum ist dabei bedeutungslos — übernommen werden nur
    /// Stunde und Minute.
    private func reminderTimeBinding(_ settings: AppSettings) -> Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                let midnight = calendar.startOfDay(for: Date())
                return calendar.date(
                    byAdding: .minute,
                    value: settings.reminderMinutesFromMidnight,
                    to: midnight
                ) ?? midnight
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings.reminderMinutesFromMidnight = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
                markChanged()
            }
        )
    }

    // MARK: - Planungsfenster

    @ViewBuilder
    private func windowSection(_ settings: AppSettings) -> some View {
        @Bindable var bound = settings

        Section {
            Stepper(
                "Fenster: \(Format.dayCount(settings.notificationHorizonDays))",
                value: $bound.notificationHorizonDays,
                in: 3...60
            )
            .onChange(of: settings.notificationHorizonDays) {
                markChanged()
            }
        } header: {
            Text("Planungsfenster")
        } footer: {
            Text(windowFootnote(settings))
        }
    }

    /// Erklärt, warum hier nicht „alle" steht. Die Zahlen kommen aus der Engine,
    /// damit der Text nicht von den echten Grenzen abdriften kann.
    private func windowFootnote(_ settings: AppSettings) -> String {
        """
        iOS lässt pro App nur \(NotificationPlanner.iosPendingRequestLimit) ausstehende Erinnerungen zu und verwirft überzählige ohne Meldung — nicht unbedingt die unwichtigsten. Rudel plant deshalb rollierend: nur die nächsten \(Format.dayCount(settings.notificationHorizonDays)), höchstens \(NotificationPlanner.budget) Erinnerungen, mit Vorrang für Überfälliges. Neu gesetzt wird bei jedem Start und nach jedem Eintrag. Ein größeres Fenster verteilt dasselbe Budget nur auf mehr Tage.
        """
    }

    // MARK: - Diagnose

    @ViewBuilder
    private func diagnosticsSection(_ settings: AppSettings) -> some View {
        Section {
            LabeledValueRow(
                label: "Gesetzte Erinnerungen",
                value: "\(pendingCount) von \(NotificationPlanner.budget)",
                systemImage: "bell.badge"
            )

            LabeledValueRow(
                label: "Zuletzt gesetzt",
                value: settings.lastNotificationSyncAt.map(Format.dateTime) ?? "noch nie",
                systemImage: "clock.arrow.circlepath"
            )

            Button {
                Task { await apply(settings) }
            } label: {
                HStack {
                    Label("Erinnerungen neu setzen", systemImage: "arrow.clockwise")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking)
        } header: {
            Text("Diagnose")
        } footer: {
            Text(statusMessage ?? "Rudel setzt die Erinnerungen bei jedem Start und nach jedem Eintrag neu. Der Knopf ist für den Fall, dass die Zahl oben nicht zu den Einträgen passt.")
        }
    }

    @ViewBuilder
    private var failureSection: some View {
        Section {
            ForEach(failures) { failure in
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title)
                    Text(failure.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Abgelehnt", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } footer: {
            Text("Diese Erinnerungen hat iOS nicht angenommen. Sie stehen hier, statt verschluckt zu werden — eine unbemerkt fehlende Erinnerung wäre schlimmer als eine sichtbare Meldung.")
        }
    }

    // MARK: - Datenschutz

    @ViewBuilder
    private var privacySection: some View {
        Section {
            Label("Alle Daten bleiben auf diesem Gerät", systemImage: "lock.shield")
        } header: {
            Text("Datenschutz")
        } footer: {
            Text("Rudel hat kein Benutzerkonto, keinen Server und keine Auswertung. iCloud-Sync ist in Version 1 bewusst abgeschaltet — deshalb gibt es hier auch keinen Schalter dafür. Ein verschlüsseltes Geräte-Backup enthält die Einträge mit; ohne Backup sind sie mit dem Gerät verloren.")
        }
    }

    // MARK: - Zustand

    private var authorizationLabel: String {
        switch authorization {
        case .authorized: return "Erteilt"
        case .provisional: return "Vorläufig"
        case .ephemeral: return "Zeitweise"
        case .denied: return "Verweigert"
        case .notDetermined: return "Noch nicht gefragt"
        @unknown default: return "Unbekannt"
        }
    }

    private var authorizationSymbol: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: return "checkmark.circle"
        case .denied: return "bell.slash"
        case .notDetermined: return "questionmark.circle"
        @unknown default: return "questionmark.circle"
        }
    }

    /// Sofort speichern, Neuplanung für das Schließen vormerken.
    private func markChanged() {
        try? context.save()
        needsReschedule = true
    }

    private func refreshDiagnostics() async {
        authorization = await service.authorizationStatus()
        pendingCount = await service.pendingCount()
    }

    private func apply(_ settings: AppSettings) async {
        isWorking = true
        defer { isWorking = false }

        let outcome = await service.reschedule(context: context, settings: settings)
        needsReschedule = false

        switch outcome {
        case .disabled:
            failures = []
            statusMessage = "Erinnerungen sind aus. Alle ausstehenden wurden entfernt."
        case .notAuthorized(let status):
            authorization = status
            failures = []
            statusMessage = "Ohne Systemberechtigung kann Rudel nichts setzen."
        case .applied(let result):
            failures = result.failures
            if result.isComplete {
                statusMessage = "\(result.scheduled) \(result.scheduled == 1 ? "Erinnerung" : "Erinnerungen") gesetzt."
                lastSuccessAt = Date()
            } else {
                statusMessage = "\(result.scheduled) von \(result.requested) Erinnerungen gesetzt, \(result.failures.count) abgelehnt."
            }
        }

        await refreshDiagnostics()
    }
}
