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

**Wer die Neuplanung auslöst.** Ein rollierendes Fenster ist nur so gut wie das,
was es vorrückt. `RootView` plant bei `scenePhase == .active` neu und außerdem,
sobald sich `notificationFingerprint` ändert — Zähler über die append-only
Journal-Typen plus die wenigen Felder, die Erinnerungen beeinflussen, ohne einen
Datensatz anzulegen (abgesetzter Plan, geändertes Dosierschema, erfasstes Ende
der sichtbaren Hitze).

Das ist keine Feinheit: bis zum 27. Juli lief `reschedule` **ausschließlich** aus
dem Einstellungs-Sheet. Die App hätte nur Erinnerungen gesetzt, wenn der Nutzer
die Einstellungen öffnet — §10.1 war damit nicht erfüllt, obwohl alle Tests grün
waren, weil sie sämtlich die reine Funktion `plannedNotifications` prüften und
nie die Frage, wer sie aufruft.

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

## 8. App-Icon (Nachtrag, 27. Juli 2026)

Generiert mit **fal.ai / `fal-ai/nano-banana-pro`** (Gemini 3 Pro Image), 2048 px
PNG, auf 1024×1024 skaliert. Liegt als `AppIcon.appiconset` mit **einem**
Single-Size-Slot in `Rudel/Resources/Assets.xcassets` — Xcode leitet die
restlichen Größen ab. `ASSETCATALOG_COMPILER_APPICON_NAME` setzt xcodegen
bereits selbst, `project.yml` musste dafür nicht angefasst werden.

**Kein Icon Composer / `.icon`-Bundle.** Die geschichteten iOS-26-Icons sind
opt-in und entstehen in einem GUI-Tool, das sich nicht skripten lässt.
`.appiconset` baut unverändert; ein Wechsel wäre ein eigener, manueller Schritt.

**Motiv: eine Hundekopf-Silhouette im Profil, anthrazit auf einem Verlauf von
Pfirsich zu Altrosa.** Vier Kandidaten wurden bei 512, 180, 120 und 40 px
gegeneinander geprüft. Zwei davon schieden an der Lesbarkeit aus, zwischen den
verbliebenen entschied die Ästhetik:

- Die naheliegende Kombination Hundekopf **plus** Zyklusring oder Kalender ist
  gar nicht erst generiert worden. Zwei Motive werden bei 40 px zu Matsch.
- Die Variante mit zwei überlappenden Köpfen („Rudel" wörtlich, passend zur
  Mehrhund-Fähigkeit der App) hält bei 120 px noch, zerfällt bei 40 px aber: der
  hintere Kopf wird zu einem hellgrauen Auswuchs an der Hauptsilhouette. Die
  inhaltlich treffendere Idee verliert gegen die lesbarere.
- Frontalansicht mit Augen/Nase als Negativform verliert bei 40 px genau diese
  Details und wird zu einem beliebigen hellen Fleck.
- Übrig blieben zwei tragfähige Silhouetten: cremeweiß auf Koralle→Bernstein und
  die gewählte anthrazit auf Pfirsich→Altrosa. Die erste ist bei 40 px minimal
  robuster, hat aber ein vom Kopf abgesetztes hinteres Ohr; die gewählte kommt
  ohne freistehendes Element aus, hat die ruhigere Kontur und den weicheren
  Farbverlauf. Der Unterschied in der Kleinlesbarkeit ist gering genug, dass die
  Optik den Ausschlag geben darf — die dünn ausgesparte Ohrlinie verschwindet bei
  40 px, die Silhouette bleibt.

**Dunkle Wallpapers.** Der helle Verlauf hat gegen helle Hintergründe weniger
Trennschärfe als ein dunkler. Falls das im Alltag stört, liegt die Alternative
in Koralle vor und ist ein reiner Dateitausch.

Der Prompt verbietet explizit runde Ecken, Rahmen, Schlagschatten und Mockups:
Bildmodelle rendern bei „App Icon" gern ein fertig maskiertes Icon *auf* einem
Hintergrund. iOS maskiert selbst zum Squircle — ein solches Bild ist unbrauchbar
und lässt sich auch nicht wegcroppen. Das PNG ist deshalb randlos und **ohne
Alpha-Kanal**; ein transparentes App-Icon wird vom App Store abgelehnt.

## 9. Beobachtbarkeit statt Vollständigkeit (Nachtrag, 27. August 2026)

Nachträglich beauftragt, mit einer Beobachtung aus dem Alltag: Menge und Farbe
des Ausflusses sowie die Konsistenz der Vulva sind nicht täglich zu erheben.
Wer keinen Deckakt plant, greift seinem Hund nicht jeden Morgen zwischen die
Hinterbeine. Die App verlangte damit genau die Felder, die im echten Betrieb
leer bleiben — und stellte gleichzeitig ein „fruchtbares Fenster" mit „bestem
Zeitpunkt" nach vorn, also die Antwort auf eine Frage, die hier niemand stellt.

### 9.1 Duldung und Flagging sind nicht dasselbe

Beide beschreiben denselben Reflex in unterschiedlichem Ausmaß:

| | Auslöser | Aussage | Zeitpunkt |
|---|---|---|---|
| **Flagging** | Streichen über Kruppe/Rutenansatz | Schwanz wird zur Seite gelegt — Teilreflex | früher, teils schon im späten Proöstrus |
| **Duldung** | fester Druck auf die Lendenpartie | ganzer Reflex: steht, stemmt sich, hebt die Hinterhand, Schwanz zur Seite | später, praktisch nur im Östrus |

Flagging ist damit die **frühere, weniger spezifische** Teilmenge. Für eine
Risikoeinschätzung ist genau das die nützlichere Eigenschaft — und deshalb
ziehen beide in `CriticalDaysAdvisor.criticalStartDay` die Stufe `.critical`
gleich weit nach vorn.

**Beide brauchen keinen Rüden.** Die UI behauptete das Gegenteil („wenn ein
Rüde aufreitet") und machte damit das stärkste Signal des ganzen Modells für
einen Einzelhund-Haushalt unerfüllbar. Der Handtest steht jetzt in der Fußzeile
des Formulars und in der Schnellfrage der Übersicht — in je einer Zeile.

**Die Begründungen aus diesem Abschnitt stehen bewusst *nicht* im Screen.** Ein
erster Entwurf trug sie als Fußzeilen mit: warum Alltagszeichen keine Phase
benennen, warum die kritischen Tage an Tag 9 beginnen, warum das fruchtbare
Fenster schmaler ist. Das ist alles richtig und gehört hierher — auf dem Screen
war es ein Aufsatz über einer Liste aus vier Schaltern. In der UI bleibt nur,
was zum Handeln nötig ist: wie der Handtest geht, und dass Leerlassen erlaubt
ist.

### 9.2 Drei Alltagszeichen, bewusst ohne Phasenwirkung

`PhaseSignals` bekommt `frequentUrination`, `genitalLicking` und
`vulvaSwellingVisible` — alle drei ohne Anfassen zu erheben und deshalb die
einzigen Felder, die sich lückenlos führen lassen.

Genau deshalb dürfen sie **keine Phase benennen und die Stufe `.critical` nicht
vorziehen**:

- Vermehrtes Urinieren/Markieren setzt mit dem Proöstrus ein und hält über den
  Östrus an.
- Vermehrtes Belecken folgt dem Ausfluss und existiert in beiden Phasen.
- Die sichtbare Schwellung ist im Proöstrus **maximal** und nimmt zum Östrus
  hin eher wieder ab — als Phasenmarker zeigte sie sogar in die falsche
  Richtung.

Wer sie „der Vollständigkeit halber" mit auswertete, bekäme an Tag 2 die Stufe
`.critical` und damit eine Warnung, die drei Wochen durchläuft — das ist der
Zustand, den die Abstufung überhaupt erst verhindern soll. Beide Regelwerke
(`CyclePhaseEstimator.observedPhase`, `CriticalDaysAdvisor.criticalStartDay`)
tragen diese Begründung als Kommentar, und je ein Test hält sie fest.

Was die drei stattdessen können, steht in `PhaseSignals.indicatesActiveHeat`:
„läuft überhaupt eine Läufigkeit?" — zuverlässig beantwortbar, ohne eine
Phasenaussage zu erfinden.

### 9.3 Das Risiko steht jetzt auf dem Screen

`CriticalDaysAdvisor` lief bis hierher **nur** in `NotificationService` — im
Zyklus-Tab stand keine einzige Risikoangabe. Die Übersicht rendert nun als
erste Sektion den Hinweis für heute: Stufe, Kurzaussage, der Text des Advisors
und die Datumsspanne der kritischen Tage.

Der Text kommt **unverändert** aus dem Advisor, nicht aus einer zweiten
Formulierung in der View. §7 führt bereits eine solche Doppelung als bekannte
Grenze; eine weitere wurde nicht angelegt. Aus demselben Grund kommen der
Hinweis für heute und die Spanne aus **einem** `notices(…)`-Aufruf: zwei
Aufrufe mit verschiedenen Fenstern könnten auseinanderlaufen, sobald eine
Beobachtung den Beginn verschiebt.

`CriticalDayNotice.phase` wird bewusst **nicht** gerendert — sie stammt allein
aus dem Kalender und darf von der Phasenschätzung darunter abweichen. Zwei
verschiedene Phasenangaben auf einem Screen wären schlimmer als eine fehlende.

### 9.4 Das fruchtbare Fenster ist eingeklappt, nicht umbenannt

Naheliegend wäre, das fruchtbare Fenster einfach als „Risikofenster" zu
beschriften — die Rechnung ist dieselbe. Das wäre falsch: Das Fenster liegt um
den optimalen Deckzeitpunkt und ist je nach Datenlage ±1 bis ±5 Tage breit. Der
Zeitraum, in dem eine Deckung aufgehen kann, ist deutlich breiter und beginnt
früher — Spermien bleiben im Genitaltrakt mehrere Tage befruchtungsfähig, und
schon die Östrus-Grenze streut über 3 bis 21 Tage.

Umbenannt stünde also eine **schmalere** Zahl auf dem Screen als die, die
`CriticalDaysAdvisor` rechnet: zwei widersprüchliche Antworten auf dieselbe
Frage, und die falsche sähe genauer aus. Die Mathematik bleibt deshalb
unangetastet; die Sektion heißt „Deckplanung", ist zugeklappt und sagt in einer
Zeile, dass ihr Fenster enger ist als der Zeitraum, in dem eine Deckung aufgeht.

### 9.5 Tag 1 ist breiter definiert

Der Anker hieß „erster Tag mit blutigem Ausfluss oder deutlich geschwollener
Vulva" — beides Zeichen, die man erst sieht, wenn man hinsieht. Er heißt jetzt
„erster Tag, an dem die Läufigkeit erkennbar war" und zählt die Alltagszeichen
mit auf. Das Tag-1-Sheet nimmt sie als erste Beobachtung entgegen; Ausfluss und
Tastbefund liegen darunter eingeklappt.

**Nicht gebaut: eine Erkennung „Anzeichen da, aber kein Tag-1-Anker".**
Inhaltlich wäre sie richtig — das Risikowerk schweigt ohne Anker, und die
Alltagszeichen fallen typischerweise vor dem Anker auf. Es fehlt aber der
Speicherweg: `CycleObservation` hängt an einer `CyclePeriod`, eine Beobachtung
ohne Läufigkeit lässt sich gar nicht ablegen. Ein Detektor ohne Datenquelle
wäre eine leere Regel. Dieselbe Information landet stattdessen dort, wo sie
handlungsfähig ist: in der Definition von Tag 1.

### 9.6 Die niedrige Stufe versprach zu viel

Beim Umbau aufgefallen: `.elevated` formulierte „Rüden zeigen Interesse,
gedeckt werden kann sie noch nicht" — an **jedem** Tag vor dem kritischen
Beginn, also bis Tag 8. Das widerspricht der Spanne, mit der dieselbe Datei
rechnet: Der Proöstrus dauert mindestens 3 Tage, der Östrus kann damit
frühestens an Tag 4 beginnen. Für die Tage 4 bis 8 stand also eine
Entwarnung auf dem Screen, die die eigene Populationsspanne nicht deckt — und
das ausgerechnet in der Kategorie, deren Fehler irreversibel ist.

Korrigiert wurde der **Text**, nicht die Stufe: Ab Tag
`proestrusMinDays + 1` heißt es „unwahrscheinlich, aber nicht ausgeschlossen"
mit dem Hinweis, Duldung oder Flagging zu prüfen. Die Stufe auf `.critical`
vorzuziehen wäre der falsche Schluss gewesen — dann wäre praktisch die ganze
Läufigkeit kritisch, und genau das entwertet die Abstufung.

### 9.7 Schema-Erweiterung ohne Migrationsplan

`CycleObservation` bekommt drei neue Properties. Die App hält keinen
`VersionedSchema` und keinen `SchemaMigrationPlan` — sie verlässt sich auf die
implizite Lightweight-Migration von SwiftData. Drei optionale `Bool?` ohne
`@Attribute`-Constraint und ohne Umbenennung sind genau der Fall, den diese
Migration abdeckt; ein vorhandener Store öffnet unverändert.

Das ist hier nicht nur zulässig, sondern semantisch passend: Bereits
gespeicherte Beobachtungen bekommen `nil`, und `nil` heißt in diesem Modell
ohnehin „nicht beobachtet" — genau das, was für einen Tag vor Einführung der
Felder stimmt. Ein Default von `false` hätte rückwirkend Beobachtungen
behauptet, die niemand gemacht hat.

Relevant wird das, weil §6 einen In-Memory-Fallback ausschließt: Öffnet der
Store nicht, zeigt die App den Fehler und schreibt nichts. Eine Schema-Änderung
ist damit die einzige Klasse Fehler, die die gesamte Historie unerreichbar
macht — der Grund, warum das hier festgehalten wird statt als Selbstverständnis
durchzugehen.

**Sobald ein pflichtiges Feld, eine Umbenennung oder ein geänderter Typ dazu
kommt, reicht das nicht mehr.** Dann braucht es einen `VersionedSchema` und
einen Migrationsplan, bevor die Version auf ein Gerät kommt.
