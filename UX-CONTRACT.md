# Rudel UI-Verhalten

Die visuelle Richtung steht in [DESIGN.md](DESIGN.md). Die Domänenregeln
stehen in [der Produktspezifikation](docs/superpowers/specs/2026-07-26-rudel-design.md)
und [den Medikamentenerinnerungen](docs/superpowers/specs/2026-09-05-medication-reminders-design.md).
Die UI-Überarbeitung ändert weder Persistenz noch Berechnung oder Alarmplanung.

| Fähigkeit | Gemeinsamer Eigentümer | Vertrag |
|---|---|---|
| Navigation | RootView, AppState | Fünf feste Tabs (Heute, Medikamente, Gesundheit, Tierarzt, Rudel), auf dem iPad als Seitenleiste; zentrale Sheet-Präsentation; das „+“ oben rechts ist überall ein beschriftetes Menü (RudelAddMenu); Zeilenaktionen sind zusätzlich zum Wischen über ein sichtbares „⋯“ erreichbar (RudelRowMenu) |
| Tierauswahl | PetScope, PetSwitcher | Gewählte Tier-ID gilt für alle tierbezogenen Tabs; der Wechsler sitzt oben links, ist auch mit einem Tier sichtbar und bietet „Tier hinzufügen“; ein Wechsel führt auf die Startseite des Tabs zurück; der Zyklus erscheint im Gesundheit-Tab nur für Tiere, die ihn brauchen, und die Auswahl wechselt nie automatisch auf ein anderes Tier |
| Listen | Native List, rudelListStyle | Scrollen und bestehende Wischaktionen bleiben erhalten |
| Formulare | Feature-Sheets, rudelFormStyle | Speichern/Abbrechen und bestehende Validierung bleiben erhalten |
| Auswahl und Datum | SwiftUI Picker / DatePicker | Native Popup-Geometrie, Tastatur und Plattformbedienung akzeptiert |
| Fotos | PhotosPicker, vorhandene Bildverarbeitung | Eigene Fotos, bestehende Größenbegrenzung |
| Leerzustände | RudelEmptyState | Titel, Erklärung und ausführbarer Einstieg; scrollbar |
| Primäre Aktionen | RudelPrimaryButtonStyle | Lesbarer aktiver, gedrückter und deaktivierter Zustand |
| Feedback | Vorhandene SwiftUI-Statusanzeigen / Haptik | Fehler bleiben sichtbar; keine neue Toast-Schicht |

Erstellen und Bearbeiten schließen nach erfolgreichem Speichern das jeweilige
Sheet. Abbrechen übernimmt keine Eingaben. Profile und Zyklen behalten ihre
benannten Löschdialoge; Journal-Wischaktionen behalten ihre vorhandene Semantik.
Ein Medikamentenalarm oder dessen Stopp bestätigt weiterhin keine Gabe.

Die kleinen lokalen Datenmengen werden über SwiftData geladen und in nativen
Listen dargestellt. Es gibt keine neue Pagination, Netzwerksuche oder URL-Suche.
Ein nicht ladbarer Store bleibt ein Fehlerzustand, kein leeres Journal.

Deutsch ist die Quellsprache. Übersetzungen gibt es für Englisch,
Niederländisch, Französisch, Spanisch, Italienisch, Portugiesisch, Schwedisch,
Norwegisch (Bokmål), Dänisch, Finnisch, Japanisch und Koreanisch; die App folgt
der Gerätesprache. App-Texte stehen in `Rudel/Resources/Localizable.xcstrings`,
die Texte der Engine (Mitteilungen, Hinweise) in
`Packages/RudelEngine/Sources/RudelEngine/Resources/*.lproj`. Neue Texte
brauchen dort einen Eintrag in allen Sprachen, sonst erscheint das Deutsche.
Native Datums-/Zahlenformate folgen den Geräteeinstellungen, die Tagesrechnung
der Gerätezeitzone. Tests laufen immer auf Deutsch.

Dynamic Type, Light/Dark Mode, VoiceOver-Namen und native Fokusbedienung sind
Teil des UI-Vertrags. Lange Namen dürfen im Inhalt umbrechen; im Tier-Wechsler
oben links werden sie gekürzt, das Menü nennt jedes Tier vollständig. Die
Auswahl darf den Inhalt nicht verdrängen.
Die Bildschirmdarstellung wird im iOS-Simulator geprüft, nicht in einem Browser.
Ein Simulator-Test bestätigt keine Alarmzustellung auf einem echten iPhone.
