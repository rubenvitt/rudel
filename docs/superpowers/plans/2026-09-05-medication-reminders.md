# Medication Reminders Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent engine task. The main agent owns iOS integration and verification; implementation agents do not edit each other's files.

**Goal:** Medikamentengaben vorab sichtbar machen und bis zur Bestätigung erinnern.

**Architecture:** Selbstbeschreibende Engine-Termine speisen einen serialisierten AlarmKit-Abgleich. Persistierte Registrierungen erhalten offene Gaben und Schlummerzeiten; eine Widget-Extension zeigt den Countdown.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, AlarmKit, ActivityKit, WidgetKit, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-09-05-medication-reminders-design.md`

## Global Constraints

- iOS 26.0 minimum; Swift 6 strict concurrency; keine externen Abhängigkeiten.
- Alle Daten lokal. Bestehende SwiftData-Felder und gespeicherte Daten erhalten.
- Standard-Vorlauf 30 Minuten, Standard-Schlummerzeit 10 Minuten.
- Alarmstopp erzeugt keinen Gabe-Eintrag; erst erfolgreicher Save bestätigt.
- Shell-Kommandos mit `rtk`; kein Push und keine Veröffentlichung.

## Task 1: Vollständige Medikamententermine in der Engine

**Ownership:** `Packages/RudelEngine` only. Main agent owns every app file.

**Files:** create `Sources/RudelEngine/MedicationReminderPlanner.swift`, modify `NotificationPlanner.swift`, add engine tests.

**Interfaces:**

```swift
public struct MedicationReminder: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String // sourceID + category + planned due timestamp
    public var sourceID: String
    public var petID: String
    public var petName: String
    public var title: String
    public var detail: String?
    public var category: DueItem.Category
    public var dueAt: Date
}
public struct MedicationReminderPlanner: Sendable {
    public init(dayMath: DayMath = .utc)
    public func plan(medications: [DueItemBuilder.MedicationInput],
                     loggedDoses: [String: [Date]],
                     reminderTime: TimeOfDay, horizonDays: Int,
                     asOf: Date) -> [MedicationReminder]
}
```

Add an optional `medicationReminders: [MedicationReminder]? = nil` argument to
`NotificationPlanner.plan`. When supplied, that list is authoritative for dose
notifications: no doses from dashboard items or legacy `doseOccurrences`; keep
legacy behavior when nil. Non-dose notification behavior stays unchanged.

- [x] Write regression tests: a plan every 2 days beginning Sept 4 planned Sept 5 yields Sept 6/8 occurrences; tomorrow's start yields tomorrow's dose; logged dose excluded; today's missed 08:00 dose retained at 09:00; duplicates deduplicated and IDs stable.
- [x] Run tests and record expected failure. For a new API a missing-symbol compile failure is acceptable before creating the minimal type, then demonstrate assertion failures.
- [x] Implement planner using `MedicationCalculator.doseOccurrences` from startOfDay(asOf) through horizon, independent of today's dashboard items. Use `DueItemBuilder` for non-dose due dates, setting reminderTime on that day. Exclude inactive plans. Preserve overdue non-dose due day. Sort chronologically then by ID.
- [x] Add tests for authoritative notification input: known metadata without today's dashboard row schedules future doses; empty authoritative array suppresses already logged dashboard doses.
- [x] Run full engine suite. Report files changed, exact test command/result and concerns. Do not commit or spawn other agents.

## Task 2: iOS alarms and persistence

**Files:** new `Rudel/Services/MedicationAlarmService.swift`, reminder snapshot/registration store, `Rudel/Services/MedicationReminderData.swift`, stop intent and shared metadata under `Shared/`; modify `NotificationService.swift`, `RudelApp.swift`, `AppSettings.swift`.

- [x] First test the store-to-engine mapping for Pausentage and already logged doses using current code, record failures.
- [x] Map all active plans and logs into the new planner. For notifications pass authoritative reminders.
- [x] Persist alarm registrations with occurrence metadata, system UUID, next fire time and configuration signature; serialize all reconciliation and alarm actions.
- [x] Diff current system alarms against desired registrations. Retain overdue registered occurrences only while active schedule/logs still validate them; remove given and obsolete entries. Keep native snooze intact during ordinary rescheduling. Re-arm a stopped, unconfirmed alarm after the configured snooze delay using a fresh UUID.
- [x] Configure `Alarm.CountdownDuration(preAlert: leadMinutes * 60, postAlert: snoozeMinutes * 60)`, fixed due schedule, native `.countdown` secondary action, and a stop intent that never logs a dose.
- [x] Make permission and schedule failures observable; fall back to existing notifications for unhandled reminders. Persist the alarm mapping before scheduling; never install an alarm without a durable mapping.
- [x] Add meaningful fake-system tests for retained snooze, removal after log, stop without log, failed scheduling and serial updates.

## Task 3: Live Activity, settings and confirmation

**Files:** `RudelWidgets/MedicationAlarmWidget.swift`, `Shared/MedicationAlarmMetadata.swift`, `Rudel/Features/Medication/MedicationReminderConfirmationSheet.swift`, `RootView.swift`, `SettingsSheet.swift`, `project.yml`.

- [x] Add embedded widget extension with `ActivityConfiguration(for: AlarmAttributes<MedicationAlarmMetadata>.self)`, lock-screen and Dynamic Island layouts. Use the actual countdown fireDate from system state.
- [x] Configure `NSAlarmKitUsageDescription`, `NSSupportsLiveActivities`, URL scheme `rudel`, extension target and shared source membership.
- [x] Add settings for medication alarms, lead time (0...120 minutes), snooze (5...60 minutes), permission state, installed count and actionable failures.
- [x] Route exact occurrence deep links to a confirmation view. Save a `DoseLogEntry` or `MedicationEvent` on explicit user confirmation; check existing logs and only cancel/reconcile after successful persistence.
- [x] Add store tests for duplicate confirmation and stop remaining unconfirmed. Exercise the settings and confirmation screens with UI smoke tests.

## Task 4: Verification and delivery

- [x] Run engine suite, generate Xcode project, run app unit tests and UI smoke tests on an isolated simulator. Confirm the extension embeds and both targets compile for iOS 26.
- [x] Request independent code review of the complete diff and fix material findings. Rerun affected tests.
- [x] Update README with reminder behavior and actual platform limitations; record device-only acceptance steps. Mark this checklist with evidence and leave the completed change available in the user workspace.


## Ergänzungen aus Review und UI-Abnahme

- Alarmfilterung vor dem Mitteilungsbudget: 61 Gaben werden vollständig durch
  32 Alarme und 29 Mitteilungen abgedeckt.
- Eine unlesbare Alarmregistrierung blockiert weder normale Mitteilungen noch
  das Abschalten. Ein fehlgeschlagener Wiederholungsalarm erzeugt eine zukünftige
  Ersatz-Mitteilung, ohne eine Gabe zu speichern.
- Offene Termine werden zusätzlich in Pending-/Delivered-Mitteilungen gespeichert.
  Diese Snapshots erhalten Ersatz-Erinnerungen unabhängig von Alarmberechtigung
  und Alarmbudget über Mitternacht. Der aktuelle medizinische Store validiert sie.
- Der Abgleich erhält unveränderte Wiederholungs-Countdowns. Erledigte zugestellte
  Medikamentenmitteilungen werden entfernt; Zyklushinweise bleiben davon unberührt.
- Live-Activity-Verweise verwenden stabile Termin-IDs, keine wechselnden Alarm-UUIDs.
- Der Wischpfad bei laufenden Medikamenten öffnet eine konkrete Gabe-Erfassung.
  Der Erfassungsbutton sitzt oberhalb der Tab-Leiste; ein UI-Test hat die vorherige
  Überdeckung aufgedeckt und den korrigierten Speichervorgang nachgewiesen.
- Drei unabhängige Reviews: drei wichtige erste Findings und ein ergänzender
  Mitternachtsfall behoben; Abschlussreview ohne Critical-/Important-Findings.
  Der abschließende Layout-Nachreview hat ebenfalls keine materiellen Befunde.
- Änderungen wurden bytegleich aus dem isolierten Worktree in das zuvor saubere
  Projektverzeichnis übernommen. Git-Historie und Remote wurden nicht verändert.

Die Geräteabnahme aus README ist weiterhin offen. Simulator- und Compilerergebnisse
bestätigen keine reale Alarmzustellung bei Fokus, Stummmodus oder Geräteneustart.


## Abschlussnachweis · 5. September 2026

Ausgeführt im Projektverzeichnis `/Users/rubeen/dev/personal/apps/rudel` mit
Xcode 27.0 (27A5194q), Swift 6, iPhone 17 Simulator mit iOS 27.0.
Deployment Target von App und Widget: iOS 26.0.

- Engine: **266 Tests / 12 Suites, Exit 0**, Log `/private/tmp/rudel-workspace-engine.log`.
- App: **83 Unit-Tests und 5 UI-Tests, 88 bestanden, 0 fehlgeschlagen, 0 übersprungen,
  Exit 0**, Ergebnis `/private/tmp/rudel-workspace-final.xcresult`.
- Unsignierter iPhone-Build: **BUILD SUCCEEDED, Exit 0**, Log `/private/tmp/rudel-iphone-build.log`.
- Info.plist und Einbettung geprüft: `NSSupportsLiveActivities`,
  `NSAlarmKitUsageDescription`, URL-Schema `rudel`, `PlugIns/RudelWidgets.appex`
  mit `com.apple.widgetkit-extension`; beide Mindestversionen 26.0.
- UI-Screenshots aus dem erfolgreichen Lauf exportiert und Einstellungen,
  erledigten Bestätigungsverweis sowie konkrete Erfassung/Doppelschutz geprüft.
- `git diff --check`: ohne Befund. Kein Commit, Push oder Deployment.

Reproduzierbare Kommandos (Simulator-ID bei Bedarf ersetzen):

```sh
rtk proxy env CLANG_MODULE_CACHE_PATH=/private/tmp/rudel-main-module-cache swift test --package-path Packages/RudelEngine --scratch-path /private/tmp/rudel-main-engine-build --disable-sandbox
rtk proxy xcodegen generate
rtk proxy xcodebuild test -project Rudel.xcodeproj -scheme Rudel -destination 'platform=iOS Simulator,id=5158CB3F-9EDA-488E-B1F5-57162C90CE27' -derivedDataPath /private/tmp/rudel-workspace-final-derived -parallel-testing-enabled NO -enableCodeCoverage NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO
rtk proxy xcodebuild build -project Rudel.xcodeproj -scheme Rudel -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/rudel-iphone-build CODE_SIGNING_ALLOWED=NO
```

Bei den vorherigen roten UI-Läufen hing Xcodes ausführliche Diagnose-Sammlung
nach Ende der Tests. `-collect-test-diagnostics never` verhindert diese Hänger;
Screenshots und strukturierte Testergebnisse blieben verfügbar. Die finalen
Läufe endeten regulär mit Exit 0.
