# Rudel

iOS-App zur Gesundheitsdokumentation für Hunde: Medikamente und Intervalle,
Läufigkeit, Symptome, Gewicht — mit lokalen Benachrichtigungen und
Prognosen, die immer als Spanne mit Konfidenz auftreten, nie als Punktwert.

## Worum es geht

Der Schwerpunkt des Zyklus-Teils liegt auf **Tracking und Risiko**, nicht auf
Deckplanung: Die App beantwortet „muss sie heute an der Leine bleiben?",
nicht „wann ist der beste Deckzeitpunkt?". Beides ist implementiert, aber die
Deckplanung ist nachrangig und trägt in jeder Ansicht ihren Vorbehalt mit —
ohne Progesteronverlauf ist der Eisprung nicht bestimmbar.

Die Beobachtungsfelder sind danach sortiert, **wie leicht sie tatsächlich zu
erheben sind**: Alltagszeichen (vermehrtes Urinieren, Belecken, sichtbare
Schwellung) stehen vor dem, was Anfassen oder eine Tierarztpraxis braucht.

## Aufbau

| Verzeichnis | Inhalt |
|---|---|
| `Packages/RudelEngine` | Reine Rechen-Engine. Kein SwiftUI, kein SwiftData — Value-Types rein, Prognose-Structs raus. Läuft mit `swift test`. |
| `Rudel` | SwiftUI-App, SwiftData-Modelle als Adapter auf die Engine-Typen. |
| `RudelWidgets` / `Shared` | Live Activity für Medikamentenalarme und gemeinsame Alarm-Metadaten. |
| `Tests` | Unit- und UI-Smoke-Tests der App-Schicht. |
| `docs/superpowers/specs` | Design-Entscheidungen inklusive Begründungen und bekannter Grenzen. |

Das Xcode-Projekt ist **nicht eingecheckt** — es entsteht aus `project.yml`.

## Bauen

```sh
brew install xcodegen
xcodegen generate
open Rudel.xcodeproj
```

Engine-Tests ohne Xcode:

```sh
swift test --package-path Packages/RudelEngine
```

Anforderungen: iOS 26.0, Swift 6 (Language Mode, `SWIFT_STRICT_CONCURRENCY = complete`).

## Medikamentenerinnerungen

Jeder Plan ist entweder **zeitkritisch** (Standard für laufende Medikamente)
oder **Vorsorge** (Standard für Wurmkur, Zeckenschutz und Tollwut). Nur
zeitkritische Pläne bekommen Alarme; Vorsorge meldet sich ausschließlich per
Mitteilung, lässt sich auslassen oder bis zu einem Datum zurückstellen und kann
einen Tierarzttermin voraussetzen. Details:
[Vorsorge und Tierarzt](docs/superpowers/specs/2026-10-05-vorsorge-und-tierarzt-design.md).

Medikamentenalarme sind standardmäßig eingeschaltet. Rudel plant die konkreten
Gaben unabhängig davon, was gerade auf dem Dashboard sichtbar ist. Auch bei
mehrtägigen Einnahmeabständen werden die nächsten Gabetage berücksichtigt.

- **30 Minuten vorher:** Mitteilung und AlarmKit-Countdown als Live Activity
  auf dem Sperrbildschirm bzw. in der Dynamic Island. Vorlauf: 0 bis 120 Minuten.
- **Zur Gabezeit:** Systemalarm mit Schlummerfunktion, standardmäßig 10 Minuten
  (einstellbar von 5 bis 60 Minuten).
- **Stopp bestätigt keine Gabe:** Solange der Termin offen ist, plant Rudel nach
  dem Stoppen einen neuen Alarm nach der Schlummerzeit. Erst eine gespeicherte
  Bestätigung beendet die Erinnerungen für genau diese Gabe.
- **Gabe bestätigen:** Der Link in der Live Activity öffnet die Bestätigung mit
  Tier, Präparat, Dosis und geplantem Termin. Auch das normale Erfassungsformular
  ordnet Dauermedikamente einer konkreten Gabezeit zu.

Alarmberechtigung, Vorlauf und Schlummerzeit stehen unter **Profil → Einstellungen**.
Fehler und fehlende Berechtigungen werden dort und als Hinweis in der App
angezeigt. Ohne verfügbaren Alarm plant Rudel normale Mitteilungen; für bereits
überfällige offene Gaben werden diese im Schlummerabstand wiederholt. Dafür muss
die Mitteilungsberechtigung erteilt sein. Unveränderte Alarme und wiederholte
Mitteilungen behalten beim Abgleich ihren laufenden Countdown.

Die Planung ist begrenzt und wird beim Öffnen sowie nach Änderungen erneuert:
höchstens 32 Systemalarme und 56 normale Mitteilungen innerhalb des eingestellten
Fensters. Nach einem Neustart benötigt der lokale Datenspeicher zunächst die
erste Geräteentsperrung. iOS erlaubt dem Nutzer, Alarme, Live Activities und
Berechtigungen zu deaktivieren; ein technisch unabschaltbarer Alarm ist daher
nicht möglich. Normale Mitteilungen haben nicht dieselben Zustellungs- und
Ton-Eigenschaften wie Systemalarme.

### Geräteabnahme

Automatische Tests prüfen Planung, Fehlerwege, Bestätigung und die App-Oberfläche.
Vor einer Auslieferung auf einem echten iPhone zusätzlich prüfen:

1. Eine Testgabe wenige Minuten voraus planen und Alarm-/Mitteilungsberechtigung
   erteilen; Live Activity vor Fälligkeit, Sperrbildschirm und Dynamic Island prüfen.
2. Alarm bei gesperrtem Gerät, Stummmodus und Fokus prüfen; native Schlummerfunktion
   mehrfach verwenden. Der Countdown muss jeweils die neue Zeit zeigen.
3. **Stopp** betätigen, App geschlossen lassen und den erneuten Alarm abwarten.
   Es darf kein Gabe-Eintrag entstehen.
4. Über die Live Activity bestätigen; genau ein Eintrag zur ursprünglichen Gabezeit,
   kein weiterer Alarm für diese Gabe. Die nächste Gabe bleibt geplant.
5. Prozessende und Geräteneustart, Berechtigungsentzug, Planänderung sowie den
   Hauptschalter prüfen. Ablehnung muss sichtbar bleiben und der verfügbare
   Mitteilungsweg weiterhin funktionieren.

Diese Geräteabnahme ist durch Simulator-Ergebnisse allein nicht belegt.

## Datenhaltung

Alles lokal. `ModelConfiguration(cloudKitDatabase: .none)` — das Schema ist
allerdings von Tag 1 an CloudKit-kompatibel gebaut (Defaults für jede
nicht-optionale Property, keine `@Attribute(.unique)`, To-One-Beziehungen
optional), damit Sync später eine Zeile plus Entitlements ist und keine
Migration.

## Grundlagen und Grenzen

Die Populationswerte stammen aus der Literatur (Concannon 2011; Cornell CVM;
UC Davis SVM) und sind **Startwerte**: ab zwei bis drei eigenen geloggten
Zyklen dominieren die individuellen Intervalle. Wo eine Konstante eine
Heuristik ohne publizierten Punktwert ist, steht das im Doc-Kommentar und in
`docs/superpowers/specs/2026-07-26-rudel-design.md`, Abschnitt „Bekannte
Grenzen".

**Kein Medizinprodukt und kein Ersatz für tierärztliche Beratung.** Jede
Phasen- und Zeitpunktschätzung ist eine Schätzung aus Populationswerten und
eigenen Beobachtungen, kein Befund.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
