# Medikamentengaben mit Vorwarnung und Alarm

Vom Nutzer am 05.09.2026 freigegeben: 30 Minuten Vorwarnung mit Live Activity,
Alarm zum Termin, 10 Minuten Schlummern, einstellbare Zeiten und offene Gabe bis
zur expliziten Bestätigung. Ein Alarmstopp ist keine dokumentierte Gabe.

## Verhalten

- Gilt für laufende Medikamente sowie Wurmkur, Zeckenschutz und Tollwut-Fälligkeiten.
- Der Countdown zeigt Tier, Präparat, Dosis und planmäßigen Termin. Die Live
  Activity führt direkt zur Bestätigung der konkreten Gabe.
- AlarmKit plant lokal, auch wenn die App geschlossen ist. Schlummern startet
  einen neuen Countdown. Stoppen ohne Bestätigung plant erneut nach der
  Schlummerzeit; Berechtigungsentzug und Systemlimits können Alarme verhindern.
- Erst erfolgreich gespeicherte Gaben entfernen zugehörige Alarme. Mehrfaches
  Bestätigen darf nicht doppelt protokollieren. Abgesetzte/geänderte Pläne werden
  mit bestehenden Alarmen abgeglichen.
- Bei fehlender Alarmberechtigung oder Planungsfehlern bleiben normale
  Mitteilungen als Ersatz verfügbar; die App zeigt den eingeschränkten Zustand.
- Vorwarnung und Schlummerzeit sind in Minuten einstellbar. Standard: 30 und 10.
- Der Hauptschalter schaltet Mitteilungen und Medikamentenalarme gemeinsam aus.
- Vorwarnungen in Tagen für Intervallmedikamente und Zyklushinweise bleiben
  Bestandteil der bestehenden Benachrichtigungsplanung.

## Architektur

Die Engine erzeugt selbstbeschreibende Medikamententermine unabhängig von der
heutigen Dashboard-Liste. Das beseitigt den reproduzierten Verlust aller
künftigen Gaben beim Planen an Pausentagen. Abgehakte Dosen gelangen nicht über
Dashboard-Items erneut in den Plan.

Ein zentraler, serialisierter Alarmdienst gleicht die Termine gegen persistierte
Registrierungen und AlarmManager ab. Offene bereits geplante Termine bleiben
über Mitternacht erhalten. Persistenz und geplante Termine werden nach
App-Aktivierung, Datenänderung und Alarmaktion abgeglichen. Die Widget-Extension
stellt den von AlarmKit verwalteten Countdown dar. Deep Links öffnen eine
gezielte Bestätigungsansicht. Alles bleibt lokal, ohne Server oder App Group.

## Grenzen und Abnahme

iOS behält Kontrolle über Stopp, Berechtigungen, Lautstärke und die Systemanzeige.
Eine Garantie für ununterbrochenes Klingeln wird nicht gegeben. Der Alarmdienst
zeigt Fehler statt Vollständigkeit zu behaupten; das Planungsfenster ist begrenzt.

Regressionstests prüfen Pausentage, künftigen Start, geloggte und überfällige
Dosen, Datumswechsel und stabile Identität. App-Tests prüfen Bestätigung,
Idempotenz, Fehler und Alarm-Abgleich mit einem Systemadapter. Build und
UI-Smoke-Test prüfen App und Extension. Lautstärke, Sperrbildschirm, Fokus,
Neustart und echte Zustellung benötigen zusätzlich einen Gerätetest.
