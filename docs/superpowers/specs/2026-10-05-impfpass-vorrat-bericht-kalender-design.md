# Impfpass, Medikamentenvorrat, Tierarzt-Bericht und Kalender

Folgeauftrag vom 05.10.2026 zu [Vorsorge und Tierarzt](2026-10-05-vorsorge-und-tierarzt-design.md):
Praxis direkt im Termin-Formular anlegen, PDF-Bericht für den Tierarzt,
weitere Impfungen, Medikamentenvorrat, Termine in den Kalender übernehmen.

## 1. Weitere Impfungen (Impfpass)

- Neue Art `MedicationKind.vaccination` (allgemeine Impfung). Rechnet wie
  Tollwut: Gültigkeitsdauer, Restwirksamkeit, Vorsorge, Standard
  „Tierarzttermin nötig".
- `MedicationPlan.vaccineValue: VaccineType?` benennt die Impfung.
  `VaccineType` (Engine) enthält die gängigen Impfungen für Hund und Katze plus
  `.other` (Freitext im Produktnamen). Standard-Gültigkeiten kommen aus einem
  Katalog nach der StIKo-Vet-Leitlinie; sie sind nur Vorbelegung — maßgeblich
  sind Impfpass und Tierarzt, und das Feld bleibt editierbar.
- **Tollwut bleibt `.rabiesVaccination`** (Bestandsdaten). In der Oberfläche
  gibt es nur noch eine Art „Impfung" mit Auswahl der Impfung; „Tollwut"
  speichert weiter als `.rabiesVaccination`. Die Medikamentenliste fasst beide
  Arten im Abschnitt „Impfungen" zusammen (Impfpass-Ansicht).

### Umsetzung und Entscheidungen (Impfungen)

- Katalog `VaccineType` (Engine): Hund — SHP (Staupe, Hepatitis, Parvovirose),
  Kombiimpfung SHPPi + L, Leptospirose, Zwingerhusten (Parainfluenza),
  Borreliose, Leishmaniose; Katze — Katzenseuche (Panleukopenie),
  Katzenschnupfen, Kombiimpfung RCP, Leukose (FeLV); dazu „Andere Impfung“
  (Name = Präparat). Der Picker zeigt Tollwut zuerst, dann die Impfungen der
  Tierart; eine gespeicherte, nicht passende Wahl bleibt auswählbar.
- Standard-Gültigkeit nach StIKo Vet am FLI, „Leitlinie zur Impfung von
  Kleintieren“, 6. Auflage, Stand 06.01.2025 (Volltext geprüft,
  Empfehlungsabschnitte je Erkrankung):

  | Impfung | Leitlinie | Vorbelegung |
  |---|---|---|
  | SHP (Staupe, HCC, Parvovirose) | „im Abstand von 3 Jahren“ | 3 Jahre |
  | Leptospirose | „jährlich“ | 1 Jahr |
  | Parainfluenza / Bordetella | „jährlich“ | 1 Jahr |
  | Borreliose, Leishmaniose | „jährlich“ | 1 Jahr |
  | Kombiimpfung SHPPi + L | kürzeste Komponente (Pi, L) | 1 Jahr |
  | Panleukopenie | „3 Jahren (oder mehr)“ | 3 Jahre |
  | Katzenschnupfen (FHV, FCV) | „bis zu 3 Jahren“ | 1 Jahr (Spanne → kürzer) |
  | Leukose (FeLV) | „bis zu 3 Jahren“ | 1 Jahr (Spanne → kürzer) |
  | Kombiimpfung RCP | kürzeste Komponente | 1 Jahr |
  | Tollwut | „im Abstand von 3 Jahren“ | 3 Jahre (unverändert) |

  Bei SHP nennt die Leitlinie zusätzlich, dass die Gebrauchsinformationen der
  Impfstoffe 1 bis 3 Jahre vorsehen. Die Vorbelegung folgt hier der festen
  Empfehlung (3 Jahre), nicht der Herstellerspanne — sonst wäre jede
  SHP-Impfung jährlich vorbelegt, was die Leitlinie ausdrücklich nicht
  empfiehlt. Wer einen Impfstoff mit 1 Jahr hat, übernimmt den Wert aus dem
  Impfpass; das Feld bleibt editierbar.
- Vorbelegung nur bei Nutzer-Wahl im Picker und nur, solange zum Plan nichts
  dokumentiert ist. Das Laden eines Plans setzt die Wahl direkt, damit eine
  eigene Gültigkeit eines Bestands-Tollwutplans beim Speichern erhalten bleibt.
- Die Engine kennt die Impfung (`MedicationInput.vaccine`) und betitelt Items
  und Mitteilungen mit dem Impfnamen („Leptospirose“), das Präparat steht im
  Zusatz.
- Liste: Abschnitt „Impfungen“ mit Impfname, Präparat, „Zuletzt geimpft …“,
  „Gültig bis …“ und Status. Vorrat gibt es für Impfungen nicht.

## 2. Medikamentenvorrat

- Vorratsverwaltung ist pro Plan optional. Felder an `MedicationPlan`:
  `stockCountedAt: Date?` (`nil` = keine Vorratsverwaltung), `stockAmount`
  (Bestand bei dieser Zählung), `stockUnit` („Tabletten"), `amountPerGiving`
  (Standard 1), `restockLeadDays` (Standard 7), `needsPrescription`.
- **Restbestand wird abgeleitet, nicht heruntergezählt:** Bestand bei der
  Zählung minus (Gaben + nicht ausgelassene Einzelgaben seit der Zählung) ×
  Menge je Gabe. Das hält das Journal append-only — gelöschte Fehleinträge
  korrigieren den Bestand automatisch.
- „Aufgefüllt" setzt Bestand und Zählzeitpunkt neu (Schnellwahl „+ 1 Packung"
  über `packageSize`, oder exakte Zählung).
- Engine projiziert die Reichweite aus Dosierschema bzw. Intervall und erzeugt
  ein Item `DueItem.Category.restock`, sobald die Reichweite unter
  `restockLeadDays` fällt. Text nennt „Rezept beim Tierarzt anfordern", wenn
  `needsPrescription`. Nur Mitteilung, nie Alarm.

### Umsetzung und Entscheidungen (Vorrat)

- Zusätzlich `packageSize` (0 = unbekannt). Gezählt werden echte Gaben
  (`MedicationEvent.loggedAt` nach der Zählung, weil `givenOn` auf Mitternacht
  steht) und nicht ausgelassene Einzelgaben (`DoseLogEntry.takenAt`).
- Engine: `MedicationInput.stock: StockInput?`, öffentliche
  `DueItemBuilder.stockProjection(for:asOf:)`. Dauermedikament: Gaben aus dem
  Schema ab Tagesbeginn (bzw. Ende der Zurückstellung), heute schon erfasste
  Einzelgaben abgezogen (`dosesHandledToday`), Schemaende beachtet, Rechengrenze
  3 Jahre. Intervall- und Wirkdauer-Arten: eine Gabe je Intervall ab der
  nächsten Fälligkeit, nie vor heute; ein offener Termin unterdrückt die
  Fälligkeit, nicht den Vorrat.
- `DueItem.Category.restock`, id `restock:<sourceID>`, `dueOn` = Tag der
  ersten nicht mehr gedeckten Gabe, Dringlichkeit daraus, `DueItem.stock`
  trägt die Projektion. Erzeugt, wenn die Reichweite ≤ `restockLeadDays` ist
  oder nicht einmal die nächste Gabe gedeckt ist. Nie ein
  `MedicationReminder`, also nie ein Alarm.
- Mitteilung: eigener Zweig im `NotificationPlanner`, genau eine zum nächsten
  Erinnerungszeitpunkt („Rex — Vorrat Apoquel“, „Reicht noch etwa 5 Tage.
  Rezept beim Tierarzt anfordern.“; Tage ab der Mitteilung gezählt). Damit
  höchstens eine pro Tag, solange der Vorrat knapp bleibt. Priorität 25:
  unter fälligen Behandlungen und Vorwarnungen, über künftigen Einzelgaben.
  Bewusst keine vorausgeplante Mitteilung für den Tag, an dem die Schwelle
  erst erreicht wird — die Neuplanung läuft bei jedem App-Start und jeder
  Erfassung.
- Bearbeiten: Das Formular zeigt den abgeleiteten Rest. Eine neue Zählung
  (Bestand + jetzt) entsteht nur beim Einschalten oder wenn Bestand oder Menge
  je Gabe geändert wurden — sonst würden die Gaben seit der alten Zählung
  doppelt abgezogen. „Aufgefüllt“ (eigenes Sheet) setzt Bestand und
  Zählzeitpunkt; „+ 1 Packung“ = Rest + Packungsgröße.

## 3. Praxis im Termin-Formular

`VetPracticeEditSheet` bekommt einen optionalen Rückruf für die neu angelegte
Praxis. Das Termin-Formular öffnet es als lokales Sheet über sich („Neue
Praxis …" im Praxis-Picker) und wählt die neue Praxis direkt aus. Das globale
„ein Sheet zur Zeit" von `AppState` bleibt unberührt, weil das lokale Sheet zum
Formular gehört.

Umsetzung: `VetPracticeEditSheet(practiceID:petForPrimary:onCreate:)`, der
bisherige Aufruf `init(practiceID:)` bleibt gültig. „Neue Praxis …" steht als
Knopf unter dem Picker (ein SwiftUI-Picker kann keine Aktion enthalten). Hat
das Tier noch keinen Haustierarzt, bietet das Praxis-Formular in diesem
Einstieg „Haustierarzt von <Tier>" an, **standardmäßig an**: wer aus einem
Termin heraus die erste Praxis anlegt, legt fast immer den eigenen Tierarzt an.
Ein vorhandener Haustierarzt wird nie still ersetzt.

## 4. Tierarzt-Bericht (PDF)

- Inhalt als reiner, testbarer Wert (`VetReportContent`), getrennt vom
  Zeichnen. Abschnitte: Tier und Notfalldaten, Anlass mit „Fragen an die
  Praxis" (wenn aus einem Termin heraus), aktuelle Medikamente mit Schema,
  letzter Gabe und Vorrat, Impfungen und Vorsorge mit Status, Gewicht der
  letzten 12 Monate mit Trend, Symptome seit dem letzten erledigten Termin
  (mindestens 90 Tage), Läufigkeit (nur wenn relevant), letzte Termine mit
  Befund.
- Zeichnen mit `UIGraphicsPDFRenderer`, A4, mehrseitig mit Seitenzahlen.
  Teilen über `ShareLink` als `Rudel-Bericht-<Tier>-<Datum>.pdf`.
- Einstiege: Termin-Formular, Tierarzt-Bereich, Profil.

Umsetzung (`Rudel/Features/Report/`):

- `VetReportContent` ist `Sendable` und hält nur Werte; `sections` formatiert.
  Der Anlass ist ein Schnappschuss (`Occasion`), damit das Termin-Formular
  auch ungespeicherte Fragen mitgibt. Medikamente werden nur nach
  „Dauermedikament" vs. „alles andere" getrennt — neue Arten (Impfungen)
  landen ohne Anpassung unter „Impfungen und Vorsorge".
- Symptome ab dem früheren von „Tagesbeginn des letzten erledigten Termins"
  (ohne den Anlass-Termin selbst) und „Stichtag − 90 Tage". Gewicht: Einträge
  der letzten 12 Monate, Trend = letzter − erster Wert, unter 2 % des
  Startwerts „stabil". Läufigkeit nur bei `tracksCycle`, mit den letzten vier
  Tag-1-Daten, eigenen Intervallen und der Prognosespanne aus derselben
  Rechnung wie die Zyklus-Übersicht. Bis zu fünf erledigte Termine mit Befund.
- Leere Abschnitte bleiben mit „Keine Einträge" stehen (auch „nichts erfasst"
  ist für die Praxis eine Aussage); nur Anlass und Läufigkeit entfallen.
- Vorrat: `VetReportContent.stockLine(for:asOf:dayMath:)` über
  `MedicationDisplay.stockText`. Impfungen heißen nach der Krankheit
  (`MedicationDisplay.vaccineName`), das Präparat steht in Klammern dahinter.
- Rendern mit TextKit 1 (`NSLayoutManager` + ein `NSTextContainer` je Seite):
  erst alle Seiten auslegen, dann zeichnen, damit „Seite x von y" stimmt.
  Feste Hellwerte aus `RudelTheme`, weil Papier keinen Dunkelmodus hat.
- Teilen über `VetReportRequest: Transferable` mit `FileRepresentation`: nur
  IDs, Anlass, `ModelContainer` und `DayMath` werden mitgegeben; das PDF
  entsteht erst beim Export auf dem Main Actor, in einem eigenen
  Temp-Unterordner, damit der Dateiname exakt bleibt.
- Einstiege: Termin-Formular („Bericht für diesen Termin", auch für neue
  Termine), Tierarzt-Bereich (Zeile unter der Überschrift), Profil (Aktionen).

## 5. Termine in den Kalender

`EKEventEditViewController` mit vorbelegtem Termin (Titel, Beginn, 1 Stunde,
Ort = Praxisadresse, Notizen = Fragen + Telefon). Ab iOS 17 läuft diese
Systemansicht außerhalb der App und braucht keine Kalenderberechtigung.
Nach dem Sichern merkt sich der Termin `calendarExportedAt` und das damals
exportierte Datum; ändert sich der Termin später, weist das Formular darauf
hin, dass der Kalendereintrag nicht automatisch mitwandert (ohne Lesezugriff
kann Rudel ihn nicht aktualisieren).

Umsetzung: `VetCalendarEditor` (`UIViewControllerRepresentable` um
`EKEventEditViewController`), Delegate über `editViewDelegate`. Rudel fragt
nie nach Kalenderzugriff und liest weder `defaultCalendarForNewEvents` noch das
gesicherte Ereignis — beides würde den berechtigungsfreien Weg verlassen.
Kein Alarm am Ereignis, Rudel erinnert selbst. Der Knopf erscheint nur für
gespeicherte, geplante Termine; das Ereignis nimmt den aktuellen
Formularstand. Nach `.saved` werden nur `calendarExportedAt` und
`calendarExportedDate` geschrieben und gesichert (die übrigen Eingaben liegen
in lokalen Kopien). Weicht das Datum im Formular vom exportierten ab, erscheint
der Hinweis plus „Erneut in Kalender übernehmen".
