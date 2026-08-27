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
