# Vorsorge statt Wecker, Tierarzttermine und Praxen

Anlass (05.10.2026): Medikamente sind entweder **zeitkritisch** oder
**Vorsorge**. Vorsorge darf nie einen Wecker auslösen, muss sich auslassen und
manuell zurückstellen lassen (Zeckentablette im Winter), und manche Vorsorge
braucht erst einen Tierarzttermin. Dazu kommt eine Tierarztverwaltung.

## 1. Erinnerungsklasse je Plan

`MedicationCareClass { timeCritical, preventive }` (Engine).

| Art | Standard |
|---|---|
| Laufendes Medikament | zeitkritisch |
| Wurmkur, Zeckenschutz, Tollwut | Vorsorge |

Gespeichert als `MedicationPlan.careClassOverride: MedicationCareClass?`;
`nil` heißt „Standard der Art". Begründung: Bestandspläne behalten ohne
Migration ihr bisheriges Verhalten für Dauermedikamente und verlieren den
Wecker für Vorsorge — genau die gewünschte Korrektur. Ein Dauermedikament
ohne Uhrzeitbezug (Gelenktabletten) lässt sich auf Vorsorge stellen.

- **Zeitkritisch**: unverändert — Vorwarnung, AlarmKit-Alarm, Schlummern,
  Bestätigung.
- `MedicationReminderPlanner` liefert weiterhin Termine **aller** Pläne, weil
  `NotificationPlanner` Dosis-Mitteilungen ausschließlich aus dieser Liste
  nimmt. Jeder Termin trägt `usesAlarm`; gefiltert wird an der Grenze zum
  Alarmdienst (`NotificationService` vor `reconcile`). Damit gelangt Vorsorge
  nie in AlarmKit, behält aber ihre Mitteilungen.
- **Vorsorge**: ausschließlich normale Mitteilungen über die bestehenden
  Vorwarnzeiten in Tagen (`NotificationPlanner`, Uhrzeit aus den
  Einstellungen). Kein AlarmKit, keine Live Activity.
- Ein auf Vorsorge gestelltes Dauermedikament erzeugt weiterhin
  Dosis-Mitteilungen zur Gabezeit, aber keinen Alarm.

## 2. Auslassen und Zurückstellen (Vorsorge)

**Auslassen** („Diesmal auslassen"): schreibt einen Journal-Eintrag
`MedicationEvent` mit `outcome = .skipped`. Die nächste Fälligkeit rechnet ab
dem späteren von letzter Gabe und letzter Auslassung. Der Schutzbalken rechnet
nur ab echten Gaben — eine ausgelassene Zeckentablette schützt nicht.
Engine: `MedicationInput.lastSkippedOn`.

**Zurückstellen** („Zurückstellen bis …", Schnellwahl 1 Woche, 1 Monat,
„bis 1. März", eigenes Datum): `MedicationPlan.deferredUntil` +
`deferredAt`. Solange aktiv, ist `dueOn = max(reguläre Fälligkeit,
deferredUntil)`; das Item trägt `deferredUntil`, damit die UI „zurückgestellt
bis …" zeigt. Mitteilungen richten sich nach dem verschobenen Datum.
Eine danach dokumentierte Gabe oder Auslassung hebt die Zurückstellung auf
(`engineInput()` gibt `deferredUntil` nur weiter, wenn kein Journal-Eintrag
nach `deferredAt` erfasst wurde) — so muss nicht jeder Erfassungsweg daran
denken. „Zurückstellung aufheben" setzt beide Felder auf `nil`.

Auslassen bei zeitkritischen Einzelgaben: `DoseLogEntry.wasSkipped`. Die
Bestätigungsansicht eines Alarms bietet „Gabe ausgelassen" — sonst re-armiert
der Alarm endlos, wenn der Tierarzt eine Gabe aussetzen lässt. Ausgelassene
Dosen gelten wie abgehakte als erledigt, werden in der Historie aber als
„ausgelassen" gezeigt.

## 3. Tierarzttermin nötig

`MedicationPlan.requiresVetVisitOverride: Bool?` (`nil` = Standard der Art:
an für Tollwut, sonst aus — als Override, damit Bestands-Tollwutpläne den
Standard bekommen). Engine-Input: `requiresVetVisit`, `hasOpenAppointment`
(ein verknüpfter Termin im Status `planned`, **unabhängig vom Datum** — sonst
taucht nach Terminbeginn, aber vor dem Abschluss wieder „Termin vereinbaren"
auf).

- Ohne geplanten Termin: Item-Flag `needsVetAppointment = true`; Titel bleibt,
  die UI sagt „Tierarzttermin vereinbaren" und bietet „Termin anlegen"
  (vorbelegt mit Tier, Plan und Grund). Mitteilungstext: „Termin beim
  Tierarzt vereinbaren".
- Mit offenem Termin: das Medikamenten-Item entfällt in der Dashboard-Liste
  und erzeugt keine Mitteilungen; der Termin selbst übernimmt (eigenes Item,
  eigene Mitteilungen). Die Medikamentenliste zeigt „Termin am …".
- Nach dem Termin fragt dessen Abschluss „Gabe dokumentieren?" — Abschluss
  mit Häkchen „Behandlung erfolgt" legt eine Gabe am Termintag an.

## 4. Tierarztverwaltung

### Modelle

`VetPractice` (tierübergreifend): `name`, `veterinarian`, `phone`,
`emergencyPhone`, `email`, `address`, `openingHours`, `isEmergencyClinic`,
`notes`, `createdAt`.

`VetAppointment`: `pet`, `practice?`, `medicationPlan?`, `date` (mit
Uhrzeit), `reasonValue: VetVisitReason` (`checkup`, `vaccination`,
`illness`, `followUp`, `surgery`, `dental`, `other`), `title`,
`preparationNotes` (Fragen an die Praxis), `findings` (Befund/Ergebnis),
`costEuro: Double` (0 = nicht erfasst), `statusValue: AppointmentStatus`
(`planned`, `done`, `cancelled`), `createdAt`.

`Pet.primaryPractice: VetPractice?` (Haustierarzt). Für CloudKit hat jede
To-One-Beziehung ein To-Many-Gegenstück: `VetPractice.primaryForPets`,
`VetPractice.appointments`, `MedicationPlan.appointments` (alle nullify),
`Pet.vetAppointments` (cascade). Neu am Tier für die
Notfallkarte: `microchipNumber`, `allergies`, `insuranceInfo`.

CloudKit-Regeln aus `Pet` gelten: Defaults, optionale To-One, `inverse` auf
einer Seite. Löschen eines Tiers löscht seine Termine (cascade); Löschen einer
Praxis lässt Termine bestehen (nullify) — die Historie bleibt.

### Engine

`DueItem.Category.vetAppointment`. Eingabe
`DueItemBuilder.AppointmentInput(sourceID, petID, petName, title, detail,
at: Date, linkedMedicationSourceID: String?)`. Nur geplante Termine; ein Termin
in der Vergangenheit erscheint bis zum Abschluss als „Termin abschließen"
(Dringlichkeit `.dueToday`, damit er nicht vergessen wird, aber nicht als
überfällige Behandlung rot leuchtet). `build(…, appointments:)` mit Default
`[]`, damit bestehende Aufrufer und Tests unverändert bleiben.

Mitteilungen für Termine: am Vortag zur Erinnerungszeit und 2 Stunden vorher
(`Settings.appointmentLeadMinutes`, Standard 120). Normale Mitteilungen,
nie Alarm, **eigener Zweig** im Planer: nach Terminbeginn kommt nichts mehr
(der generische Pfad würde sonst täglich „überfällig" melden).

### Oberfläche

- **Gesundheit-Tab**: dritter Bereich „Tierarzt" neben Symptome und Gewicht —
  kommende Termine, vergangene Termine, Praxen. Ein sechster Tab hätte iOS
  in „Mehr" gezwungen.
- **Sheets**: Termin anlegen/bearbeiten (inkl. Abschluss mit Befund und
  Kosten), Praxis anlegen/bearbeiten.
- **Heute**: Termin-Items mit Uhrzeit und Praxis; „Tierarzttermin
  vereinbaren"-Items mit Aktion „Termin anlegen".
- **Profil**: Abschnitt „Notfall" — Haustierarzt und Notfallpraxis mit
  Anruf-Button (`tel:`), Chipnummer, Allergien, Versicherung.

## API-Vertrag (Engine)

```swift
public enum MedicationCareClass: String, Sendable, Codable, CaseIterable, Hashable {
    case timeCritical, preventive
}
extension MedicationKind {
    public var defaultCareClass: MedicationCareClass      // .ongoing → .timeCritical, sonst .preventive
    public var defaultRequiresVetVisit: Bool              // .rabiesVaccination → true, sonst false
}

// DueItemBuilder.MedicationInput – neue Felder, alle mit Init-Default:
public var careClass: MedicationCareClass         // init-Parameter `careClass: MedicationCareClass? = nil` → kind.defaultCareClass
public var lastSkippedOn: Date?                   // = nil
public var deferredUntil: Date?                   // = nil
public var requiresVetVisit: Bool                 // = false
public var hasOpenAppointment: Bool               // = false

// DueItem – neue Felder, alle mit Init-Default:
public var careClass: MedicationCareClass?        // nur Medikamenten-Kategorien
public var needsVetAppointment: Bool              // = false
public var deferredUntil: Date?                   // = nil, gesetzt solange zurückgestellt
// DueItem.Category: neuer Fall `.vetAppointment`

public struct AppointmentInput: Sendable, Equatable, Hashable {   // DueItemBuilder.AppointmentInput
    public var sourceID: String
    public var petID: String
    public var petName: String
    public var title: String
    public var detail: String?
    public var at: Date
    public init(sourceID:petID:petName:title:detail: = nil, at:)
}
// DueItemBuilder.build(medications:cycles:appointments: [AppointmentInput] = [], asOf:forecastHorizonDays:)
//   Termin-Item: id "appt:<sourceID>", category .vetAppointment, dueOn = at (mit Uhrzeit),
//   künftig: Urgency(daysUntilDue:), nur innerhalb forecastHorizonDays;
//   vergangen und offen: immer enthalten, urgency .dueToday, daysUntilDue 0.

// MedicationReminder – neues Feld:
public var usesAlarm: Bool     // init-Default true; Decoding mit decodeIfPresent → true
                               // (Registry-Dateien enthalten das Feld noch nicht)

// NotificationPlanner.Settings – neues Feld:
public var appointmentLeadMinutes: Int   // init-Default 120
```

Regeln im `DueItemBuilder`:

- Basis der Fälligkeit = später von `lastGivenOn` und `lastSkippedOn`.
  Schutzbalken nur aus `lastGivenOn` (fehlt sie: 0).
- `deferredUntil` (auf Tagesbeginn) gilt für **alle** Pfade inklusive „noch
  nie gegeben": `dueOn = max(regulär, deferredUntil)`, Dringlichkeit aus dem
  verschobenen Datum.
- `hasOpenAppointment` ⇒ kein Medikamenten-Item.
- `requiresVetVisit` und kein offener Termin ⇒ `needsVetAppointment = true`.

## Bewusst nicht in diesem Schritt

PDF-Bericht für den Tierarzt, Kalender-Export (EventKit), Anhänge an Terminen,
weitere Impfarten neben Tollwut, Medikamentenvorrat. Siehe Vorschläge in der
Übergabe.
