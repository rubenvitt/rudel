import Foundation
import Synchronization

/// Sprachwahl für die Texte, die die Engine selbst erzeugt (Mitteilungen,
/// Tageshinweise, Caveats, Impfnamen …).
///
/// Die Engine löst ihre Texte aus `Bundle.module` auf — klassische
/// `Localizable.strings`/`.stringsdict` je Sprache, damit `swift test` ohne Xcode
/// läuft. Welche Sprache gilt, entscheidet in dieser Reihenfolge:
///
/// 1. ein mit `withLanguage(_:operation:)` gesetzter Task-lokaler Wert,
/// 2. ein mit `overrideLanguage(_:)` gesetzter globaler Wert,
/// 3. die beste Übereinstimmung von `Bundle.main.preferredLocalizations` bzw.
///    `Locale.preferredLanguages` mit `supportedLanguages`,
/// 4. Deutsch.
///
/// Deutsch bleibt Quell- und Rückfallsprache: fehlt ein Schlüssel in einer
/// Sprache, kommt der deutsche Text.
public enum EngineLocalization {
    /// Alle Sprachen, für die die Engine Texte mitbringt.
    public static let supportedLanguages: [String] = [
        "de", "en", "nl", "fr", "es", "it", "pt", "sv", "nb", "da", "fi", "ja", "ko",
    ]

    /// Quell- und Rückfallsprache.
    public static let fallbackLanguage = "de"

    private static let forcedLanguage = Mutex<String?>(nil)

    @TaskLocal static var scopedLanguage: String? = nil

    /// Erzwingt eine Sprache für alle Engine-Texte (z. B. `"de"` in Tests).
    /// `nil` stellt die automatische Wahl wieder her. Nicht unterstützte Codes
    /// werden ignoriert, als wäre `nil` übergeben worden.
    public static func overrideLanguage(_ code: String?) {
        let normalized = code.flatMap(normalize)
        forcedLanguage.withLock { $0 = normalized }
    }

    /// Führt `operation` mit einer festen Sprache aus, nur für den aktuellen
    /// Task (und dessen Kind-Tasks). Hat Vorrang vor `overrideLanguage(_:)` —
    /// damit lassen sich andere Sprachen testen, ohne parallel laufende Tests zu
    /// stören.
    public static func withLanguage<R>(_ code: String, operation: () throws -> R) rethrows -> R {
        try $scopedLanguage.withValue(normalize(code) ?? fallbackLanguage, operation: operation)
    }

    /// Die Sprache, in der die Engine gerade textet.
    public static var currentLanguage: String {
        if let scoped = scopedLanguage { return scoped }
        if let forced = forcedLanguage.withLock({ $0 }) { return forced }
        return automaticLanguage
    }

    /// Einmal bestimmt: iOS startet die App bei einem Sprachwechsel neu.
    private static let automaticLanguage: String = {
        // Zuerst die Sprache, in der die App selbst läuft — sonst textete die
        // Engine z. B. Polnisch-Nutzern auf Englisch, während die App (mangels
        // Polnisch) auf Deutsch zurückfällt.
        let candidates = Bundle.main.preferredLocalizations + Locale.preferredLanguages
        for candidate in candidates {
            if let code = normalize(candidate) { return code }
        }
        return fallbackLanguage
    }()

    /// `"pt-BR"` → `"pt"`, `"nb_NO"` → `"nb"`, `"no"`/`"nn"` → `"nb"`.
    /// `nil`, wenn die Sprache nicht unterstützt wird.
    static func normalize(_ identifier: String) -> String? {
        let lowered = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        let base = lowered.split(separator: "-").first.map(String.init) ?? lowered
        let mapped: String
        switch base {
        case "no", "nn": mapped = "nb"
        default: mapped = base
        }
        return supportedLanguages.contains(mapped) ? mapped : nil
    }
}

/// Interne Auflösung der Engine-Texte.
enum L10n {
    private static let missingMarker = "\u{1F}rudel-engine-missing\u{1F}"

    /// Text zu `key` in der aktuellen Sprache, mit `arguments` formatiert.
    /// Plural-Schlüssel stehen in `Localizable.stringsdict` und werden über das
    /// Zahl-Argument aufgelöst.
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let language = EngineLocalization.currentLanguage
        let format = localizedFormat(key, language: language)
        guard !arguments.isEmpty else { return format }
        // Die Locale der gewählten Sprache bestimmt die Pluralregel.
        return String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }

    private static func localizedFormat(_ key: String, language: String) -> String {
        if let value = lookup(key, language: language) { return value }
        let fallback = EngineLocalization.fallbackLanguage
        if language != fallback, let value = lookup(key, language: fallback) { return value }
        return key
    }

    /// Unformatierter Eintrag zu `key` im lproj von `language`, `nil` wenn er
    /// dort fehlt. Der Rückgabewert wird nicht verändert: bei Plural-Schlüsseln
    /// trägt er die `.stringsdict`-Regel, die erst `String(format:)` auswertet.
    static func lookup(_ key: String, language: String) -> String? {
        guard let bundle = bundle(for: language) else { return nil }
        let value = bundle.localizedString(forKey: key, value: missingMarker, table: nil)
        return value == missingMarker ? nil : value
    }

    private static func bundle(for language: String) -> Bundle? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    /// Ob die Engine gerade deutsch textet. Deutsch behält die bisherigen,
    /// locale-unabhängigen Formate (`01.03.2026`, `08:00`, `1,5`) byte-genau.
    static var isGerman: Bool {
        EngineLocalization.currentLanguage == EngineLocalization.fallbackLanguage
    }

    /// Locale für Datums-, Zeit- und Zahlformate in nicht-deutschen Texten:
    /// die Gerätelocale, wenn sie dieselbe Sprache spricht (Regionalformat
    /// bleibt erhalten), sonst die Sprache mit der Region des Geräts.
    static var displayLocale: Locale {
        let language = EngineLocalization.currentLanguage
        let current = Locale.current
        if let code = current.language.languageCode?.identifier,
           EngineLocalization.normalize(code) == language {
            return current
        }
        if let region = current.region?.identifier {
            return Locale(identifier: "\(language)_\(region)")
        }
        return Locale(identifier: language)
    }

    /// Kalenderdatum im mittleren Stil der Anzeigesprache.
    static func dateText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Uhrzeit im kurzen Stil der Anzeigesprache (12/24 h nach Locale).
    static func timeText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
