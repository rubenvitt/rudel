---
version: alpha
name: Rudel
description: Ein persönliches Gesundheitsjournal für Hunde und Katzen, inspiriert von Pfotenplan.
colors:
  primary: "#244F42"
  forest: "#173D33"
  cream: "#FAF7ED"
  sage: "#D1E0C9"
  apricot: "#F7C9A6"
  background: "#F5F5ED"
  surface: "#FFFFFF"
  ink: "#203C32"
  muted: "#5D6C61"
  soft-sage: "#E5EBDF"
  soft-apricot: "#F9E5D4"
  warning: "#8E501A"
  danger: "#B2333E"
  success: "#2E654D"
typography:
  display:
    fontFamily: "New York, ui-serif, serif"
  body:
    fontFamily: "SF Pro, system-ui, sans-serif"
rounded:
  card: "24px"
  action: "20px"
  button: "18px"
spacing:
  card-padding: "24px"
  section-gap: "22px"
  action-gap: "12px"
components:
  primary-button:
    backgroundColor: "{colors.forest}"
    textColor: "{colors.cream}"
    rounded: "{rounded.button}"
  pet-hero:
    backgroundColor: "{colors.forest}"
    textColor: "{colors.cream}"
    rounded: "{rounded.card}"
  avatar:
    backgroundColor: "{colors.sage}"
    textColor: "{colors.forest}"
  welcome-cat:
    backgroundColor: "{colors.apricot}"
    textColor: "{colors.forest}"
  quick-action:
    backgroundColor: "{colors.soft-sage}"
    textColor: "{colors.ink}"
  quick-action-medication:
    backgroundColor: "{colors.soft-apricot}"
    textColor: "{colors.ink}"
  secondary-text:
    textColor: "{colors.muted}"
  warning-label:
    textColor: "{colors.warning}"
  danger-label:
    textColor: "{colors.danger}"
  success-label:
    textColor: "{colors.success}"
---

# Rudel Design

## Overview

Die Referenz ist Pfotenplan aus dem Chat „Datei suchen“: Tannengrün,
Salbei und Apricot. Gewünscht ist eine deutliche Aufwertung der bestehenden
nativen App. Der Chat liefert die Farbrichtung; eine pixelgenaue Kopie der
HTML-Datei ist nicht Grundlage dieses Entwurfs.

Rudel begleitet deutschsprachige Tierhalter beim täglichen Dokumentieren.
Das Produkt bleibt ein lokales Gesundheitsjournal, mit nativen iOS-Abläufen.
Sein Erkennungsmerkmal ist der tannengrüne Tierkopf mit großer Serifenschrift
und dem eigenen Foto beziehungsweise einem Art-Symbol. Er gehört auf Heute
und Profil. Medizinische Hinweise erhalten die Aufmerksamkeit, die ihre
Dringlichkeit erfordert.

## Colors

Laufzeitquelle ist `Rudel/Support/RudelTheme.swift`. Diese Datei dokumentiert
deren Werte; sie erzeugt keine CSS-Dateien. Die CSS-kompatiblen Längen oben
entsprechen SwiftUI-Punkten, nicht physischen Displaypixeln.

Salbei und Apricot gliedern Schnellaktionen und Kontextflächen. Sie sind
keine Gesundheitsbewertungen. Warnung und Gefahr behalten zusätzlich Text
und Symbol. Der grüne Tierkopf behauptet keinen Gesundheitszustand.

| Rolle | Hell | Dunkel |
|---|---|---|
| accent | #244F42 | #BDD8C3 |
| canvas | #F5F5ED | #141D19 |
| surface | #FFFFFF | #202D26 |
| ink | #203C32 | #EDF2E8 |
| muted | #5D6C61 | #B1C0B3 |
| line | #DEE5D9 | #39493F |
| softSage | #E5EBDF | #2A3D30 |
| softApricot | #F9E5D4 | #463529 |
| warning | #8E501A | #F4BE85 |
| danger | #B2333E | #FFACB2 |
| success | #2E654D | #BDD8C3 |

Forest, cream, sage und apricot bleiben in beiden Modi identisch und werden
nur als geprüfte Vorder-/Hintergrundpaare verwendet. Primäre Buttons behalten
cream auf forest, unabhängig vom globalen Tint.

## Typography

SwiftUI `.serif` nutzt die System-Serife für Tiernamen und wichtige Überschriften.
Fließtext, Formulare und Statusinformationen bleiben in der System-Sans.
Alle Schriftgrößen folgen Textstilen oder `ScaledMetric`; der Tiername startet
bei 42 Punkten und bricht um. Bei Accessibility-Schriftgrößen steht das Foto
unter dem Namen. Zahlen bekommen bei Bedarf `monospacedDigit()`.

## Layout

Native `List` bleibt für Zeilen mit Wischaktionen zuständig. Freie Tierköpfe
und Aktionsraster werden als separatorlose Zeilen eingebettet. Offene Aufgaben
und Einzelgaben stehen auf Heute vor Schnellaktionen und weiterem Kontext.
Das adaptive Aktionsraster nutzt eine Mindestbreite von 135 Punkten.
Leerzustände sind scrollbar und auf 560 Punkte begrenzt; der Einstieg auf 600.
Tierauswahl, Navigation und Fußaktionen respektieren Safe Areas.

## Elevation & Depth

Hierarchie entsteht durch Farbflächen und Abstand. Keine dekorativen Schatten,
Verläufe oder dauernden Animationen. Systemglas bleibt auf nativen
Navigationsaktionen, Tabs und Overlays; die Wortmarke erhält keinen Glasknopf.

## Shapes

Eigene Karten: 24 Punkte, Aktionskacheln: 20, primäre Buttons: 18.
Avatare sind rund. Die native Geometrie von Formularen, Menüs und Tabs bleibt
plattformgesteuert. Eigene Sheets erhalten 28 Punkte Eckenradius.

## Components

| Eigentümer | Verwendung |
|---|---|
| RudelTheme | Farben und Display-Typografie |
| rudelListStyle / rudelFormStyle | Listen- und Formularflächen |
| RudelPetHero | Tierkopf auf Heute und Profil |
| RudelFeatureHeading / RudelSectionHeading | Kontext und Abschnittshierarchie |
| RudelEmptyState | Leere Medikamente, Zyklus, Symptome und Gewicht |
| RudelQuickAction | Beschriftete Schnellaktionen |
| RudelPrimaryButtonStyle | Primäre Aktionen, dunkel/hell identisch kontrastreich |
| RudelTileButtonStyle | Gedrückt-Rückmeldung und Pointer-Hervorhebung |
| PetScope | Tab-Titel und gemeinsame Tierauswahl |

Buttons sind echte SwiftUI-Buttons, mit nativer Fokus- und VoiceOver-Semantik.
Primäre Buttons sind mindestens 52 Punkte hoch und reduzieren ihre Deckkraft
bei deaktiviertem Zustand. Die gedrückte Rückmeldung verändert keine Geometrie.
Native Picker, DatePicker, PhotosPicker und Formulare behalten ihre Interaktion.
Alle Symbole stammen aus SF Symbols; reine Dekoration ist für VoiceOver verborgen.
Es gibt keine zusätzliche Bewegungsanimation; Systemanimation und bestehende
Erfolgshaptik bleiben erhalten.

Prognosen zeigen weiterhin Spanne, Konfidenz und Herkunft zusammen. Die
Gewichtskurve und Symptom-Punktdarstellung behalten ihre Datenbedeutung.

## Do's and Don'ts

- Den Tiernamen, die tatsächlichen Aufgaben und das Journal gestalten.
- Neue wiederkehrende Oberflächen aus den gemeinsamen Bausteinen zusammensetzen.
- Keine erfundenen Termine, Gesundheitswerte, Fotos oder Fortschrittsanzeigen.
- Keine bloße Standardliste mit ausgetauschter Akzentfarbe.
- Keine Information allein durch Farbe kommunizieren oder für Dekoration entfernen.
