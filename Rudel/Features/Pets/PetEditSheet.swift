import PhotosUI
import RudelEngine
import SwiftData
import SwiftUI

/// Tier anlegen oder bearbeiten (PRD §5.1). `petID == nil` ⇒ neues Tier.
///
/// Das Sheet holt sein Tier selbst per Fetch, statt ein `Pet` durchgereicht zu
/// bekommen: `AppState.Sheet` trägt nur die ID, damit der Zustand über einen
/// App-Neustart hinweg beschreibbar bleibt.
///
/// Pflichtfeld ist allein der Name. Alles andere darf leer bleiben und später
/// nachgetragen werden — ein Formular, das beim ersten Start alles verlangt,
/// verhindert genau die Historie, für die es die App gibt.
struct PetEditSheet: View {
    let petID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState

    @State private var name = ""
    @State private var species: Species = .dog
    @State private var breed = ""
    @State private var hasBirthDate = false
    @State private var birthDate = Date()
    @State private var weightMinText = ""
    @State private var weightMaxText = ""
    @State private var isFemale = true
    @State private var isNeutered = false
    @State private var sizeClassOverride: DogSizeClass?
    @State private var photoData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var isProcessingPhoto = false

    /// Die Vorbelegung darf nur einmal laufen. `.task` feuert bei jedem
    /// Wiedereinblenden erneut und würde sonst Tippen überschreiben.
    @State private var didLoad = false

    @FocusState private var nameFocused: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isNew: Bool { petID == nil }

    var body: some View {
        NavigationStack {
            Form {
                photoAndNameSection
                speciesSection
                baseDataSection
                sexSection
                weightSection
                if species == .dog {
                    sizeClassSection
                }
            }
            .navigationTitle(isNew ? "Neues Tier" : "Tier bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            // Beim Anlegen steht die Tastatur direkt im Namensfeld: danach fehlt
            // nur noch „Speichern". Beim Bearbeiten (`isNew == false`) bleibt der
            // Fokus bewusst leer — eine aufspringende Tastatur würde das
            // Formular halb verdecken.
            .defaultFocus($nameFocused, isNew)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(!canSave)
                }
            }
            .task { load() }
            .task(id: photoItem) { await loadPhoto() }
        }
    }

    // MARK: - Abschnitte

    private var photoAndNameSection: some View {
        // Die Label-Closure des `PhotosPicker` ist `@Sendable` und darf deshalb
        // nicht auf den @MainActor-Zustand der View zugreifen — den Titel hier
        // ausrechnen und als Wert hineingeben.
        let pickerTitle = photoData == nil ? "Foto wählen" : "Foto ändern"

        return Section {
            HStack(spacing: 16) {
                PetPhotoThumbnail(photoData: photoData, species: species)

                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(pickerTitle, systemImage: "photo")
                    }
                    // Ohne `.borderless` beansprucht ein Steuerelement in einer
                    // Listenzeile die ganze Zeile — hier stehen zwei darin.
                    .buttonStyle(.borderless)
                    .disabled(isProcessingPhoto)

                    if isProcessingPhoto {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("Wird verkleinert …")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if photoData != nil {
                        Button(role: .destructive) {
                            photoData = nil
                            photoItem = nil
                        } label: {
                            Label("Foto entfernen", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.vertical, 4)

            TextField("Name", text: $name)
                .focused($nameFocused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
        } footer: {
            if trimmedName.isEmpty {
                Text("Ein Name genügt zum Anlegen — alles andere kannst du jederzeit ergänzen.")
            }
        }
    }

    private var speciesSection: some View {
        Section {
            Picker("Art", selection: $species) {
                ForEach(Species.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: species) { _, newValue in
                // Die Größenklasse ist eine Hunde-Größe. Bliebe eine manuelle
                // Vorgabe beim Wechsel zur Katze stehen, würde sie gespeichert,
                // ohne dass das Formular sie noch zeigt.
                if newValue == .cat { sizeClassOverride = nil }
            }
        } header: {
            Text("Art")
        }
    }

    private var baseDataSection: some View {
        Section {
            TextField("Rasse", text: $breed, prompt: Text("z. B. Rhodesian Ridgeback"))
                .textInputAutocapitalization(.words)

            Toggle("Geburtsdatum bekannt", isOn: $hasBirthDate)

            if hasBirthDate {
                DatePicker(
                    "Geburtstag",
                    selection: $birthDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
            }
        } header: {
            Text("Stammdaten")
        } footer: {
            Text("Die Rasse ist reine Information — gerechnet wird mit dem Gewicht.")
        }
    }

    private var sexSection: some View {
        Section {
            // „Weiblich"/„Männlich" passt segmentiert nur bei normalen
            // Schriftgrößen; ein Segmented Control kürzt Text, statt ihn zu
            // brechen. Bei Barrierefreiheits-Größen deshalb die Menü-Zeile des
            // Formulars, die den Titel vollständig zeigt.
            if dynamicTypeSize.isAccessibilitySize {
                sexPicker
            } else {
                sexPicker.pickerStyle(.segmented)
            }

            Toggle("Kastriert / sterilisiert", isOn: $isNeutered)
        } header: {
            Text("Geschlecht")
        } footer: {
            Text(sexFooter)
        }
    }

    private var sexPicker: some View {
        Picker("Geschlecht", selection: $isFemale) {
            Text("Weiblich").tag(true)
            Text("Männlich").tag(false)
        }
    }

    private var weightSection: some View {
        Section {
            weightField(label: "Von", text: $weightMinText, prompt: "z. B. 22")
            weightField(label: "Bis", text: $weightMaxText, prompt: "z. B. 28")
        } header: {
            Text("Zielbereich Gewicht")
        } footer: {
            Text(weightFooter)
        }
    }

    private var sizeClassSection: some View {
        Section {
            Picker("Größenklasse", selection: $sizeClassOverride) {
                Text("Automatisch aus Gewicht").tag(nil as DogSizeClass?)
                ForEach(DogSizeClass.allCases, id: \.self) { value in
                    Text(Format.label(value)).tag(Optional(value))
                }
            }
        } header: {
            Text("Größenklasse")
        } footer: {
            Text("Automatisch heißt: aus dem letzten Gewichtseintrag abgeleitet. Die Klasse verschiebt nur den Startwert der Zyklusprognose und wird von eigenen geloggten Intervallen schnell überstimmt.")
        }
    }

    /// Eine Zeile des Zielbereichs. Kurzes Label links, Zahl rechtsbündig,
    /// Einheit dahinter — so bleibt nichts abgeschnitten, auch bei großer
    /// Schrift.
    private func weightField(label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label)
            TextField(label, text: text, prompt: Text(prompt))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("\(label) Kilogramm")
            Text("kg")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Fußnoten

    private var sexFooter: String {
        switch species {
        case .dog:
            return "Die Läufigkeit wird nur für unkastrierte Hündinnen geführt; für alle anderen blendet Rudel den Zyklus-Tab aus."
        case .cat:
            return "Für Katzen gibt es in Rudel keine Zyklusprognose. Katzen sind saisonal polyöstrisch: innerhalb der Saison folgt der Östrus alle zwei bis drei Wochen, und der Eisprung wird erst durch die Paarung ausgelöst. Dieses Muster lässt sich nicht wie der Zyklus einer Hündin vorhersagen — deshalb fehlen hier die zyklusbezogenen Felder."
        }
    }

    private var weightFooter: String {
        if case .invalid = parsedWeightMin { return "Bitte eine Zahl eingeben, z. B. 22,5." }
        if case .invalid = parsedWeightMax { return "Bitte eine Zahl eingeben, z. B. 22,5." }
        if !isWeightRangeOrdered { return "Der untere Wert muss kleiner sein als der obere." }
        return "Optional. Dient als Vergleichsmaßstab im Gewichtsverlauf; die Größenklasse leitet Rudel aus dem tatsächlich gewogenen Gewicht ab, nicht aus dem Zielbereich."
    }

    // MARK: - Gültigkeit

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedWeightMin: PetWeightField { PetWeightField(text: weightMinText) }
    private var parsedWeightMax: PetWeightField { PetWeightField(text: weightMaxText) }

    private var isWeightRangeOrdered: Bool {
        guard case .value(let minKg) = parsedWeightMin, case .value(let maxKg) = parsedWeightMax else {
            return true
        }
        return minKg <= maxKg
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty else { return false }
        if case .invalid = parsedWeightMin { return false }
        if case .invalid = parsedWeightMax { return false }
        return isWeightRangeOrdered
    }

    // MARK: - Laden und Speichern

    /// Das zu bearbeitende Tier. Bewusst ohne `#Predicate`: die Datenmenge ist
    /// winzig, und in Swift zu filtern kann nicht an einer
    /// Predicate-Einschränkung scheitern.
    private var existingPet: Pet? {
        guard let petID else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Pet>())) ?? []
        return all.first { $0.id == petID }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true

        // Bei einem neuen Tier sind die Defaults der `@State`-Properties bereits
        // die Vorbelegung (Hund, weiblich, kein Geburtsdatum).
        guard let pet = existingPet else { return }

        name = pet.name
        species = pet.speciesValue
        breed = pet.breed
        if let existingBirthDate = pet.birthDate {
            hasBirthDate = true
            birthDate = existingBirthDate
        }
        weightMinText = PetWeightField.text(for: pet.weightTargetMinKg)
        weightMaxText = PetWeightField.text(for: pet.weightTargetMaxKg)
        isFemale = pet.isFemale
        isNeutered = pet.isNeutered
        sizeClassOverride = pet.sizeClassOverride
        photoData = pet.photoData
    }

    private func loadPhoto() async {
        guard let photoItem else { return }

        isProcessingPhoto = true
        defer { isProcessingPhoto = false }

        // Verkleinern kostet bei einem 12-Megapixel-Foto genug Zeit, um Frames zu
        // verlieren — deshalb abseits des Main-Actors. Über die Grenze wandert
        // nur `Data`, und das ist `Sendable`.
        //
        // Schlägt eines von beiden fehl, wird bewusst nichts gesetzt: Daten, die
        // UIKit nicht dekodieren kann, wären auch nicht anzeigbar.
        guard let original = try? await photoItem.loadTransferable(type: Data.self),
              let reduced = await Task.detached(priority: .userInitiated, operation: {
                  PetPhoto.downscaledJPEG(from: original)
              }).value
        else { return }

        photoData = reduced
    }

    private func save() {
        guard canSave else { return }

        let minKg = parsedWeightMin.kilograms
        let maxKg = parsedWeightMax.kilograms
        let trimmedBreed = breed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Eine Größenklassen-Vorgabe gilt nur für Hunde (siehe `DogSizeClass`).
        let override = species == .dog ? sizeClassOverride : nil

        if let pet = existingPet {
            pet.name = trimmedName
            pet.speciesValue = species
            pet.breed = trimmedBreed
            pet.birthDate = hasBirthDate ? birthDate : nil
            pet.weightTargetMinKg = minKg
            pet.weightTargetMaxKg = maxKg
            pet.isFemale = isFemale
            pet.isNeutered = isNeutered
            pet.sizeClassOverride = override
            pet.photoData = photoData
            try? context.save()
        } else if isNew {
            let pet = Pet(
                name: trimmedName,
                species: species,
                breed: trimmedBreed,
                birthDate: hasBirthDate ? birthDate : nil,
                weightTargetMinKg: minKg,
                weightTargetMaxKg: maxKg,
                isFemale: isFemale,
                isNeutered: isNeutered,
                sizeClassOverride: override
            )
            pet.photoData = photoData
            context.insert(pet)
            try? context.save()
            // Das neu angelegte Tier ist das, mit dem der Nutzer weiterarbeiten
            // will — sonst zeigen alle Tabs weiter das alte.
            appState.selectedPetID = pet.id
        }
        // Kein weiterer Fall: `petID` gesetzt, Tier aber nicht gefunden, heißt
        // „zwischenzeitlich gelöscht". Dann wäre ein Neuanlegen eine Kopie, die
        // niemand angefordert hat.

        dismiss()
    }
}

/// Zustand eines Gewichtsfeldes. Drei Fälle statt eines `Double?`, damit
/// „leer" und „unlesbar" unterscheidbar bleiben: eine unlesbare Eingabe darf
/// nicht stillschweigend als 0 (= nicht gesetzt) gespeichert werden.
private enum PetWeightField {
    case empty
    case invalid
    case value(Double)

    init(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self = .empty
            return
        }
        // Deutsche Tastatur liefert das Komma als Dezimaltrennzeichen; den Punkt
        // ebenfalls zulassen, damit Einfügen aus anderen Quellen funktioniert.
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(normalized), parsed.isFinite, parsed > 0 else {
            self = .invalid
            return
        }
        self = .value(parsed)
    }

    /// `0` = nicht gesetzt, wie es `Pet.weightTargetMinKg` erwartet.
    var kilograms: Double {
        if case .value(let parsed) = self { return parsed }
        return 0
    }

    /// Vorbelegung des Textfeldes. **Ohne Tausendertrennzeichen** — im deutschen
    /// Format wäre das ein Punkt, und der würde beim Zurücklesen als
    /// Dezimalpunkt verstanden.
    static func text(for kilograms: Double) -> String {
        guard kilograms > 0 else { return "" }
        return kilograms.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }
}

/// Verkleinert ein Foto und kodiert es als JPEG.
///
/// Ein Original aus der Fotos-App ist mehrere Megabyte groß. Für ein
/// Avatar-Bild ist das sinnlos, in einem späteren CloudKit-Sync teuer — und
/// `Pet.photoData` liegt zwar in `.externalStorage`, aber gelesen wird es
/// trotzdem bei jedem Anzeigen.
private enum PetPhoto {
    static let maxDimension: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.8

    static func downscaledJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let source = image.size
        let longestSide = max(source.width, source.height)
        guard longestSide > 0 else { return nil }

        // Nie hochskalieren: kleine Bilder bleiben, wie sie sind.
        let factor = min(1, maxDimension / longestSide)
        let target = CGSize(
            width: max(1, (source.width * factor).rounded()),
            height: max(1, (source.height * factor).rounded())
        )

        // `scale = 1` ist hier wesentlich: ohne das rechnet der Renderer in
        // Punkten und liefert auf einem 3x-Display ein dreimal zu großes Bild.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: jpegQuality)
    }
}

/// Vorschau des gewählten Fotos. Kann nicht `PetAvatar` sein: das braucht ein
/// `Pet`, und beim Anlegen gibt es noch keines.
private struct PetPhotoThumbnail: View {
    let photoData: Data?
    let species: Species

    private let size: CGFloat = 76

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.accentColor.opacity(0.15)
                    Image(systemName: species.symbolName)
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
