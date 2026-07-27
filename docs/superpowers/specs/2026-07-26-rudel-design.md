# Rudel – Design-Entscheidungen

**Stand:** 26. Juli 2026 · Grundlage: PRD v0.1

Dieses Dokument hält die Entscheidungen fest, die die PRD offen lässt (§11) oder
in denen die PRD rechnerisch nicht aufgeht. Es ersetzt kein Brainstorming — der
Auftrag war „du kennst Zielbild, implementiere". Die Annahmen stehen hier, damit
sie prüfbar sind, wenn in sechs Monaten eine Konstante hinterfragt wird.

## 1. Umfang

PRD §5 vollständig: Profile, Medikamente/Intervalle, Läufigkeit, Symptome,
Gewicht, Dashboard + Notifications. Keine Reduktion auf ein Teilprojekt.

**Impfpass** (§11): aufgenommen, aber nur als `MedicationKind.rabiesVaccination`.
Tollwut-Gültigkeit ist rechnerisch identisch zum Zeckenschutz (Datum +
Wirkdauer), kostet also einen Enum-Fall. Ein vollständiger Impfpass mit weiteren
Impfungen, Chipnummer und Reisedokumenten bleibt draußen — das wäre ein eigenes
Modul, nicht ein Feld.

**Nicht umgesetzt:** Mehrbenutzer-Sharing, Muster-Erkennung bei Symptomen
(PRD selbst: v1.1), Zucht-/Deckplanung über die Datenfelder hinaus.

## 2. Plattform und Aufbau

Native iOS-App, SwiftUI + SwiftData, Deployment-Target iOS 26.0, Swift 6
Language Mode mit `SWIFT_STRICT_CONCURRENCY = complete`.

Das Xcode-Projekt wird von **xcodegen** aus `project.yml` erzeugt und ist nicht
eingecheckt. Die Sources sind als Ordner-Glob eingebunden: neue Dateien landen
automatisch im Target, `project.yml` muss dafür nie angefasst werden.

**RudelEngine** ist ein lokales Swift-Package und importiert weder SwiftData noch
SwiftUI (PRD §7). Es nimmt Value-Types (`[Date]` von Tag-1-Ankern,
`PhaseSignals`, `DoseSchedule`) und gibt Prognose-Structs zurück. Die
`@Model`-Typen der App sind Adapter. Damit läuft `swift test` ohne Xcode und
ohne ModelContainer — sonst wären die Fixtures langsam und flaky.

## 3. CloudKit (§11: „v1 oder später?")

**Entscheidung: Sync in v1 aus, Schema von Tag 1 an CloudKit-kompatibel.**

In SwiftData ist das keine nachgelagerte Entscheidung. CloudKit-Stores verlangen,
dass jede nicht-optionale Property einen Default hat, verbieten
`@Attribute(.unique)` und wollen Beziehungen auf der To-One-Seite optional. Wer
das später nachrüstet, migriert das Schema. Wer es von Anfang an einhält, zahlt
fast nichts.

Also: `ModelConfiguration(cloudKitDatabase: .none)` in `RudelApp`, aber alle
Modelle nach diesen Regeln gebaut. Umstellung auf `.private(...)` später ist
eine Zeile plus Entitlements.

Folge: `AppSettings` erzwingt seine Einmaligkeit nicht per Constraint, sondern in
`loadOrCreate(in:)`, das Duplikate deterministisch abräumt.

## 4. Zyklus-Berechnung: Korrekturen an §6.1

### 4.1 Der Anker heißt nicht „Interöstrus-Intervall"

§6.1 nennt zwei Größen — „Zyklus ~6 Monate" und „Interöstrus-Intervall
~7 Monate" — und die Cold-Start-Regel greift dann stillschweigend zu 6 Monaten.
Das sind zwei verschiedene Dinge für eine Prognose.

Zusätzlich ist der Begriff selbst uneindeutig: die Literatur benutzt
„interestrous interval" teils für Tag-1→Tag-1, teils für Ende Östrus → Beginn
nächster Proöstrus. Die beiden unterscheiden sich um die Proöstrus+Östrus-Dauer,
also etwa 18 Tage.

**Entscheidung:** Die Konstante heißt `StudyConstants.day1ToDay1IntervalDays`
und beschreibt, was die App messen kann — den Abstand zweier beobachteter
Tag-1-Anker. Startwert **210 Tage (7 Monate)** nach Concannon (2011). Die
verbreitete „alle 6 Monate"-Faustregel wird bewusst nicht zur Berechnung
verwendet; sie ist der Median populärer Darstellung, nicht der publizierte
Mittelwert. Die definitorische Unschärfe steht als Kommentar an der Konstante,
damit der Quellenkommentar dem Code nicht widersprechen kann.

### 4.2 Das Konfidenzband kollabierte bei zwei Zyklen

§6.1: „≥ 2 Zyklen: letzter Tag-1 + Mittelwert der eigenen Intervalle;
Konfidenzband = ± Standardabweichung."

Zwei geloggte Tag-1-Daten ergeben **ein** Intervall. Der Mittelwert einer
Einzelstichprobe ist sie selbst, ihre Standardabweichung ist 0 — das Band wäre
auf Breite null zusammengefallen, genau dort, wo es sich laut PRD erst anfangen
soll zu verengen. Die App hätte in dem Moment maximale Scheingenauigkeit
angezeigt, in dem sie am wenigsten weiß.

**Entscheidung:** drei Korrekturen.

1. **Alle Schwellen hängen an der Anzahl Intervalle** (`n = Anker − 1`), nicht an
   der Anzahl Zyklen. `Confidence(ownIntervalCount:)` bildet das ab:
   0 → `.low`, 1–2 → `.moderate`, ab 3 → `.high`.

2. **Punktschätzer per Shrinkage** statt Umschalten an einer Schwelle:

   ```
   w  = n / (n + k)        k = 2
   μ̂  = w · μ_eigen + (1 − w) · μ_pop
   ```

   Die Prognose wandert stetig von der Population zu den eigenen Daten. Bei
   einem eigenen Intervall zählt es ein Drittel, bei vier bereits zwei Drittel —
   das trifft die PRD-Aussage „ab 2–3 eigenen Zyklen rechnet die App mit den
   individuell geloggten Intervallen", ohne Sprungstelle.

3. **Untere Schranke für die Bandbreite:** `intervalBandFloorDays = 7`. Das ist
   ausdrücklich eine UX-Schranke gegen Scheingenauigkeit, kein biologischer
   Befund — auch bei perfekt regelmäßigen Zyklen ist schon der Tag-1-Anker
   selbst eine Beobachtung mit Unsicherheit.

### 4.3 Invarianten statt Schätzer-Diskussion

Als Tests festgeschrieben, nicht als Kommentar:

1. Bandbreite ist bei jedem `n` mindestens `intervalBandFloorDays`.
2. Das Band enthält immer `expectedDate`.
3. Ab einem eigenen Intervall ist das Band nie breiter als die
   Populationsspanne — durch Datenzugewinn kann nicht mehr Unsicherheit
   entstehen als „wir wissen nichts über dieses Tier".
4. Bei **konstanten** eigenen Intervallen verengt sich das Band monoton mit `n`.
   Bei variablen darf es breiter werden: ein unregelmäßiger Zyklus soll ehrlich
   als unsicher erscheinen, nicht künstlich verengt.

### 4.4 Rassespezifischer Startwert (§11)

Statt einer Rassen-Datenbank ein Bias über die **Größenklasse**
(`DogSizeClass`, aus dem letzten Gewicht abgeleitet, manuell überschreibbar):
−15 / 0 / +15 / +30 Tage für klein / mittel / groß / riesig. Ein Ridgeback fällt
damit auf `.large` und startet bei 225 Tagen.

Das ist als Heuristik gekennzeichnet: UC Davis beschreibt, dass große Rassen ans
obere Ende der Spanne tendieren, nennt aber keine Punktwerte je Größenklasse.
Der Bias ist deshalb bewusst klein gegenüber der Populations-SD (41 Tage) und
wird von eigenen Intervallen schnell überstimmt.

### 4.5 Katzen haben keinen Zyklus in diesem Modell

Hegel ist eine Katze; Katzen sind saisonal polyöstrisch mit induzierter
Ovulation, Östrus alle 2–3 Wochen innerhalb der Saison. Die Engine modelliert
das nicht. `Pet.tracksCycle` ist nur für unkastrierte Hündinnen wahr, und der
Zyklus-Tab erscheint nur, wenn mindestens ein Tier ihn braucht.

## 5. Notifications: das 64er-Limit

iOS hält pro App maximal 64 ausstehende `UNNotificationRequest`s und verwirft
überzählige stillschweigend — nicht notwendigerweise die unwichtigsten. Ein
Dauermedikament mit zwei Gaben täglich verbraucht das Budget in 32 Tagen und
würde die Wurmkur-Erinnerung verdrängen. Genau das bricht Erfolgskriterium
§10.1.

**Entscheidung:** `NotificationPlanner` plant ein rollierendes Fenster
(Default 14 Tage) mit einem Budget von 56 (64 − 8 Reserve) und priorisiert hart:
überfällig/heute fällig zuerst, dann heutige Einzelgaben, dann Fälligkeiten
innerhalb der Vorwarnzeit, dann künftige Gaben, zuletzt Zyklus-Prognosen (die
unschärfste Kategorie). Neuplanung bei App-Vordergrund und nach jedem Log.

Als Test festgeschrieben: ein überfälliges Item wird nie von Dosis-Erinnerungen
verdrängt, auch nicht bei 20 Dauermedikamenten.

## 5a. Kritische Tage (Nachtrag, 27. Juli 2026)

Nachträglich beauftragt: Benachrichtigungen für die Tage einer Läufigkeit, an
denen aufgepasst werden muss. `CyclePhaseEstimator` und `FertileWindowEstimator`
liefen bis dahin **nur in die UI** — während einer laufenden Läufigkeit gab es
keine einzige Benachrichtigung.

`CriticalDaysAdvisor` erzeugt einen Hinweis pro Kalendertag, in drei Stufen:

| Stufe | Zeitraum | Aussage |
|---|---|---|
| `.elevated` | Tag 1 bis kritischer Beginn | Rüden zeigen Interesse, Deckung noch nicht möglich |
| `.critical` | ab Tag 9 (bzw. früher, s. u.) bis Ende sichtbare Hitze | Deckung möglich |
| `.subsiding` | 3 Tage danach | Duldung klingt ab, Restrisiko |

Drei Stufen statt einer, weil eine einzige Warnung über drei Wochen stumpf wird
und dann ignoriert. Danach ist Ruhe — im Anöstrus gibt es nichts zu warnen.

**Der Beginn ist konservativ nach vorn gesetzt.** Der Median-Übergang Proöstrus →
Östrus liegt bei Tag 10, die Spanne reicht von Tag 4 bis 18. Eine Warnung, die
dem Median folgt, kommt in einem von zwei Fällen zu spät — und „zu spät" heißt
hier ein Deckakt, der nicht rückgängig zu machen ist. Also beginnt `.critical`
bereits an Tag 9, und Beobachtungen (Standhitze, Flagging, strohfarbener oder
rosa Ausfluss, weich werdende Vulva, Progesteron über der LH-Schwelle) ziehen ihn
weiter nach vorn — **nie nach hinten**. Eine erst an Tag 14 dokumentierte
Standhitze darf den kritischen Beginn nicht auf Tag 14 verschieben: bis dahin war
die Hündin genauso gefährdet, nur hat niemand hingesehen.

**Das Ende ist großzügig.** Ohne erfasstes Hitze-Ende läuft `.critical` bis
Tag 30 (Proöstrus-Median + maximale Östrus-Dauer). Wer das sichtbare Ende
einträgt, beendet die Hinweise früher — ein Anreiz zum Loggen, der in die
richtige Richtung zeigt. Der Puffer von 3 Tagen danach steht, weil die
Duldungsbereitschaft nicht schlagartig endet und Spermien im Genitaltrakt
mehrere Tage befruchtungsfähig bleiben.

**Priorität über allem.** `.critical` rangiert im `NotificationPlanner` über
überfälligen Fälligkeiten (55 gegen 50). Begründung: jede andere Kategorie ist
nachholbar — eine Wurmkur kann man einen Tag später geben. Ein verpasster
kritischer Tag ist die einzige Kategorie mit irreversibler Folge. Als Invariante 5
festgeschrieben: bei 20 Dauermedikamenten mit je 3 Gaben täglich plus 30
überfälligen Behandlungen bleibt der kritische Tag im Ergebnis. `.elevated` und
`.subsiding` rangieren dagegen unter den überfälligen Fälligkeiten.

**Geschlüsselt nach `petID`, nicht nach `sourceID`.** Anders als
`doseOccurrences`: eine `CriticalDayNotice` bringt Titel und Text schon mit, ihr
fehlt nur die `petID` — die kommt über den Schlüssel herein. Damit entfällt die
Abhängigkeit von einem passenden `DueItem`, an der Dosis-Termine ohne Gegenstück
verworfen werden müssen.

**Nur für unkastrierte Hündinnen**, über `Pet.tracksCycle`. Abschaltbar über
`AppSettings.criticalDayRemindersEnabled`, standardmäßig an.

Beim Bau gefunden: ein erfasstes Hitze-Ende vor dem geschätzten kritischen
Beginn (kurzer Proöstrus oder Tippfehler) erzeugte eine invertierte
`ClosedRange` und **stürzte ab**. Die Stufen-Einteilung arbeitet deshalb mit
Vergleichen statt Ranges, und der Beginn wird bei Bedarf mitgezogen.

## 6. Persistenz-Entscheidungen

**Plan getrennt von Gabe.** `MedicationPlan` hält die veränderliche
Konfiguration (Intervall, Wirkdauer, Dosierschema), `MedicationEvent` ist das
append-only Journal der Gaben. Steckte beides in einem Modell, würde eine
Intervall-Änderung die Historie rückwirkend verfälschen.

**Nur abgehakte Gaben werden gespeichert.** `DoseLogEntry` existiert nur für
tatsächlich gegebene Einzeldosen; eine fehlende Zeile heißt „nicht gegeben".
Das hält das Journal append-only und erspart Platzhalter für jeden Tag.

**Kein In-Memory-Fallback.** Öffnet der Store nicht, zeigt die App den Fehler
und schreibt nichts. Ein stiller Rückfall auf In-Memory wirkt funktionsfähig und
verliert jeden Eintrag beim Beenden — bei einer App, deren Zweck lückenlose
Historie ist, der schlimmste Fehlermodus.

**Beobachtungsfelder sind alle optional.** Ein nicht gesetztes Feld heißt „nicht
beobachtet", nicht „nicht vorhanden"; die Engine unterscheidet das über
`PhaseSignals.isEmpty`. Sonst würde ein unvollständig dokumentierter Tag die
Phasenschätzung Richtung Anöstrus ziehen.

## 7. Bekannte Grenzen

- Das fruchtbare Fenster ist ohne Progesteronverlauf nicht belastbar. Jede
  Rückgabe trägt ein `caveat`, das die UI anzeigen muss (PRD §6.3).
- Die Populations-SD (41 Tage) ist aus der Spanne 135–300 Tage unter
  Normalverteilungsannahme geschätzt, weil die Primärquellen die Spanne, nicht
  die SD berichten.
- Der Größenklassen-Bias ist eine Heuristik ohne publizierte Punktwerte (§4.4).
- Symptom-Muster-Erkennung fehlt (PRD selbst: v1.1).
- **Zwei Quellen für dieselben deutschen Begriffe.** `DueItem.title` entsteht in
  der Engine („Wurmkur", „Zeckenschutz", …), `Format.label(_:)` in der App
  liefert dieselben Wörter. Das ist strukturell, nicht nachlässig: die Engine
  darf `Rudel/Support` nicht importieren (§2). Wer einen dieser Begriffe
  umbenennt, muss beide Stellen anfassen — sonst zeigt das Dashboard eine
  andere Bezeichnung als die Benachrichtigung zur selben Sache.
- `usesFecalSampleInstead` reicht nicht bis in die Engine: `MedicationInput`
  trägt das Feld nicht, deshalb formuliert die Engine „Wurmkur", und die
  Umbenennung in „Kotprobe" macht die UI (`MedicationDisplay`, `DashboardView`).
  In einer Benachrichtigung steht daher „Wurmkur fällig", auch wenn der Plan auf
  Kotprobe steht.
