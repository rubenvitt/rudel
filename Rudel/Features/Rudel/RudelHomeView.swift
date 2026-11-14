import StoreKit
import SwiftData
import SwiftUI

/// Rudel-Tab: alles, was nicht zu einem einzelnen Tag oder Befund gehört —
/// die Tiere selbst, Einstellungen und Rechtliches.
///
/// Früher lagen die Einstellungen hinter einem Zahnrad im Profil. Hier
/// stehen sie offen, damit man sie findet, ohne zu wissen, wo man suchen muss.
struct RudelHomeView: View {
    @Environment(AppState.self) private var appState

    @Query(sort: \Pet.createdAt) private var pets: [Pet]

    @State private var showsManageSubscriptions = false

    var body: some View {
        NavigationStack {
            List {
                petsSection
                subscriptionSection
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
            RudelSectionHeading(title: String(localized: "Deine Tiere"))
        } footer: {
            Text("Welches Tier die anderen Tabs zeigen, wählst du dort oben links.")
        }
    }

    // MARK: - Früheres Abo

    /// Rudel ist komplett kostenlos. Wer früher Rudel Plus abonniert hat,
    /// findet hier den Weg zum Kündigen, ohne in den iOS-Einstellungen zu suchen.
    private var subscriptionSection: some View {
        Section {
            Button {
                showsManageSubscriptions = true
            } label: {
                Label("Früheres Abo verwalten", systemImage: "creditcard")
            }
            .accessibilityIdentifier("manage-subscription")
        } header: {
            RudelSectionHeading(title: String(localized: "Alles kostenlos"))
        } footer: {
            Text("Rudel ist jetzt komplett kostenlos. Falls du früher Rudel Plus abonniert hast, kannst du das Abo hier kündigen.")
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
            RudelSectionHeading(title: String(localized: "Einstellungen"))
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
            RudelSectionHeading(title: String(localized: "Über Rudel"))
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
                Text(pet.name.isEmpty ? String(localized: "Unbenannt") : pet.name)
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
