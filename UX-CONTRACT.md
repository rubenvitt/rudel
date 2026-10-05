# Rudel UI-Verhalten

Die visuelle Richtung steht in [DESIGN.md](DESIGN.md). Die Domänenregeln
stehen in [der Produktspezifikation](docs/superpowers/specs/2026-07-26-rudel-design.md)
und [den Medikamentenerinnerungen](docs/superpowers/specs/2026-09-05-medication-reminders-design.md).
Die UI-Überarbeitung ändert weder Persistenz noch Berechnung oder Alarmplanung.

| Fähigkeit | Gemeinsamer Eigentümer | Vertrag |
|---|---|---|
| Navigation | RootView, AppState | Native Tabs und zentrale Sheet-Präsentation |
| Tierauswahl | PetScope | Gewählte Tier-ID und vollständiger Tierwechsler gelten für alle Tabs; Zyklus zeigt für ungeeignete Tiere einen Hinweis ohne Erfassungsaktionen und wechselt nie automatisch auf ein anderes Tier |
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

Die Texte sind deutsch. Native Datums-/Zahlenformate folgen wie bisher den
Geräteeinstellungen, die Tagesrechnung der Gerätezeitzone. Der ausgeschriebene
Dashboard-Datumskopf ist deutsch. Eine vollständige Mehrsprachigkeit wird durch
diesen visuellen Umbau nicht eingeführt.

Dynamic Type, Light/Dark Mode, VoiceOver-Namen und native Fokusbedienung sind
Teil des UI-Vertrags. Lange Namen dürfen umbrechen. Bei mehreren Tieren bleibt
die Auswahl horizontal scrollbar; sie darf den Inhalt nicht verdrängen.
Die Bildschirmdarstellung wird im iOS-Simulator geprüft, nicht in einem Browser.
Ein Simulator-Test bestätigt keine Alarmzustellung auf einem echten iPhone.
