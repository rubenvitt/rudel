import StoreKit
import SwiftData
import SwiftUI

/// Rudel-Tab: alles, was nicht zu einem einzelnen Tag oder Befund gehört —
/// die Tiere selbst, Rudel Plus samt Abo, Einstellungen und Rechtliches.
///
/// Früher lagen Einstellungen und Plus hinter einem Zahnrad im Profil. Hier
/// stehen sie offen, damit man sie findet, ohne zu wissen, wo man suchen muss.
struct RudelHomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlusStore.self) private var plus

    @Query(sort: \Pet.createdAt) private var pets: [Pet]

    @State private var showsManageSubscriptions = false
    @State private var isRestoring = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                petsSection
                plusSection
                settingsSection
                aboutSection
            }
            .rudelListStyle()
            .rudelReadableWidth()
            .navigationTitle("Rudel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(RudelTheme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "pawprint.fill").font(.caption)
                        Text("rudel").font(.system(.title3, design: .serif, weight: .bold))
                    }
                    .foregroundStyle(RudelTheme.accent)
                    .accessibilityLabel("Rudel")
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    RudelAddMenu {
                        Button {
                            appState.present(.editPet(petID: nil))
                        } label: {
                            Label("Tier hinzufügen", systemImage: "pawprint")
                        }
                    }
                }
            }
            .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
            .alert("Rudel Plus", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: - Tiere

    private var petsSection: some View {
        Section {
            ForEach(pets) { pet in
                NavigationLink {
                    PetProfileView(pet: pet)
                } label: {
                    PetRow(pet: pet, isSelected: pet.id == appState.selectedPetID)
                }
                .accessibilityIdentifier("pet-row")
            }
            Button {
                appState.present(.editPet(petID: nil))
            } label: {
                Label("Weiteres Tier anlegen", systemImage: "plus.circle")
            }
        } header: {
            RudelSectionHeading(title: "Deine Tiere")
        } footer: {
            Text("Welches Tier die anderen Tabs zeigen, wählst du dort oben links.")
        }
    }

    // MARK: - Rudel Plus

    private var plusSection: some View {
        Section {
            LabeledContent("Status", value: plus.isPlus ? "Aktiv" : "Nicht aktiv")
            if !plus.isPlus {
                Button {
                    appState.present(.plus)
                } label: {
                    Label("Rudel Plus ansehen", systemImage: "sparkles")
                }
            }
            Button {
                showsManageSubscriptions = true
            } label: {
                Label("Abo verwalten", systemImage: "creditcard")
            }
            .accessibilityIdentifier("manage-subscription")
            Button {
                restore()
            } label: {
                Label(isRestoring ? "Wird geprüft …" : "Käufe wiederherstellen", systemImage: "arrow.clockwise")
            }
            .disabled(isRestoring)
        } header: {
            RudelSectionHeading(title: "Rudel Plus")
        } footer: {
            Text("Abos verlängern sich automatisch. Unter „Abo verwalten“ kannst du jederzeit wechseln oder kündigen.")
        }
    }

    private func restore() {
        isRestoring = true
        Task {
            do {
                try await plus.restore()
                message = plus.isPlus ? "Rudel Plus ist aktiv." : "Es wurde kein Kauf gefunden."
            } catch {
                message = "Wiederherstellen hat nicht geklappt. Prüf deine Verbindung und versuch es noch einmal."
            }
            isRestoring = false
        }
    }

    // MARK: - Einstellungen

    private var settingsSection: some View {
        Section {
            NavigationLink {
                SettingsSheet(isPushed: true)
            } label: {
                HStack {
                    Label("Erinnerungen & Alarme", systemImage: "bell")
                    if MedicationAlarmService.shared.issue != nil {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Problem mit Alarmen")
                    }
                }
            }
            .accessibilityIdentifier("settings-reminders")
        } header: {
            RudelSectionHeading(title: "Einstellungen")
        }
    }

    // MARK: - Über Rudel

    private var aboutSection: some View {
        Section {
            Label("Alle Daten bleiben auf diesem Gerät", systemImage: "lock.shield")
            Link(destination: RudelLinks.privacy) {
                Label("Datenschutzerklärung", systemImage: "hand.raised")
            }
            Link(destination: RudelLinks.terms) {
                Label("Nutzungsbedingungen", systemImage: "doc.text")
            }
            if let version {
                LabeledContent("Version", value: version)
            }
        } header: {
            RudelSectionHeading(title: "Über Rudel")
        } footer: {
            Text("Kein Konto, kein Server. Dein iCloud- oder Geräte-Backup sichert die Einträge mit.")
        }
    }

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

/// Ein Tier in der Liste: Bild, Name, Art und Rasse.
private struct PetRow: View {
    let pet: Pet
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            PetAvatar(pet: pet, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pet.name.isEmpty ? "Unbenannt" : pet.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(RudelTheme.ink)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(RudelTheme.muted)
            }
            Spacer(minLength: 8)
            if isSelected {
                Text("Gewählt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RudelTheme.accent)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        pet.breed.isEmpty ? pet.speciesValue.label : "\(pet.speciesValue.label) · \(pet.breed)"
    }
}
