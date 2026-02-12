---
name: Auto-Improvement System Prompts
overview: "Automatische Verbesserung der System-Prompts im Hintergrund (Standard: alle 7 Tage), Intervall konfigurierbar (Nie / 7 / 14 / 30 Tage), mit Pop-up zum Übernehmen/Verwerfen und Option zum vollständigen Deaktivieren (inkl. Interaktions-Logging)."
todos: []
isProject: false
---

# Automatische System-Prompt-Verbesserung (konfigurierbares Intervall, opt-out)

## Ziel

- **Standard: alle 7 Tage** – Automatische Verbesserung und Interaktions-Logging sind aktiv; das Intervall ist konfigurierbar (Nie, 7, 14, 30 Tage).
- **Je nach gewähltem Intervall** (außer „Nie“) läuft im Hintergrund die Gemini-Auswertung; es werden Vorschläge für alle vier Bereiche erzeugt (User Context, Dictation, Dictate Prompt, Dictate Prompt & Read).
- **Ein Pop-up** erscheint mit Hinweistext und Vergleich (Current vs. Suggested); Nutzer kann pro Bereich „Übernehmen“ oder „Aktuelles behalten“. Im Pop-up und in den Einstellungen kann man **komplett deaktivieren** (smarte Verbesserung + Interaktions-Tracking).
- Bestehende „Generate with AI“-Buttons in den Tabs bleiben unverändert.

---

## 1. Einstellungen und Logger-Anbindung

**Neue UserDefaults-Keys** in [UserDefaultsKeys.swift](WhisperShortcut/UserDefaultsKeys.swift):

- `autoPromptImprovementIntervalDays` (Int oder String für Enum-RawValue) – konfiguriertes Intervall: **Nie** (0 oder spezieller Wert), **7**, **14**, **30** Tage. Default: **7**.
- `userContextLoggingEnabled` existiert bereits; wird aktuell in [UserContextLogger.swift](WhisperShortcut/UserContextLogger.swift) nicht ausgewertet (`isLoggingEnabled` ist fest `true`).

**Änderungen:**

- In `UserContextLogger`: `isLoggingEnabled` aus UserDefaults lesen (`UserDefaultsKeys.userContextLoggingEnabled`), Default `true`. Wenn `false`: keine neuen Einträge schreiben, bestehende Logs bleiben.
- Beide Toggles **logisch koppeln**: Wenn Nutzer „Smarte Verbesserung“ deaktiviert, kann optional auch Logging automatisch ausgestellt werden (oder separat steuerbar bleiben – siehe Offene Punkte).

---

## 2. Scheduler: konfigurierbares Intervall (7 / 14 / 30 Tage oder Nie), 4 Fokusse

**Neuer Service** (z. B. `AutoPromptImprovementScheduler.swift`):

- **Singleton**, prüft beim Start (z. B. in `applicationDidFinishLaunching` oder beim ersten Öffnen der App) und bei Gelegenheit (z. B. nach Nutzeraktionen), ob das konfigurierte Intervall seit `lastAutoImprovementRunDate` vergangen ist.
- **Bedingungen**: `autoPromptImprovementIntervalDays` != „Nie“ (z. B. 7, 14 oder 30), `userContextLoggingEnabled == true`, API-Key vorhanden, ausreichend Interaktionsdaten (z. B. wie bisher „last 30 days“).
- **Intervall-Logik**: Gespeicherter Wert z. B. `AutoImprovementInterval`: `.never` (0), `.days7` (7), `.days14` (14), `.days30` (30). Default: `.days7`. Prüfung: `daysSince(lastAutoImprovementRunDate) >= intervalInDays` (bei `lastAutoImprovementRunDate == nil`: erste Frist = gewähltes Intervall ab jetzt).
- **Ablauf**: Nacheinander `UserContextDerivation().updateFromLogs(focus:)` für `.userContext`, `.dictation`, `.promptMode`, `.promptAndRead` aufrufen (4 Gemini-Calls). Nach jedem Fokus prüfen, ob ein nicht-leerer Vorschlag in der jeweiligen `suggested-*.txt` / `suggested-user-context.md` steht; nur dann diesen Fokus in die „Pending“-Liste aufnehmen.
- **Nach Abschluss**: `lastAutoImprovementRunDate = now` speichern; Liste der Fokusse mit Vorschlägen in einen **persistenten Pending-Store** (UserDefaults oder Datei, damit sie beim nächsten App-Start verfügbar ist).
- **Pop-up anzeigen**: 
  - **Wenn App läuft**: `SettingsManager.shared.showSettings()` aufrufen (öffnet Settings-Fenster) + `Notification.Name.autoImprovementSuggestionsReady` posten, damit SettingsView das Sheet anzeigt.
  - **Beim App-Start**: Prüfen, ob Pending-Liste existiert. Wenn ja: Settings öffnen + Notification posten (siehe Abschnitt 3).

**Neue UserDefaults:**

- `lastAutoImprovementRunDate` (Date?) – zuletzt durchgeführter Lauf.
- `autoPromptImprovementIntervalDays` – gewähltes Intervall (0 = Nie, 7, 14, 30); Default 7.

---

## 3. Pop-up / Vergleichs-UI („hintereinander“)

**Empfehlung:** Vier Bereiche **nacheinander** in einem Pop-up (Sheet) abarbeiten – gleiche UI wie die bestehende „Generate with AI“-Vergleichsansicht, aber mit klarem Kontext „Automatische Verbesserung“.

**Ablauf:**

1. Scheduler schreibt Vorschläge und setzt `pendingAutoImprovementKinds` (z. B. in einem **Singleton** `AutoImprovementPendingStore` oder in UserDefaults als Codable-Array von `GenerationKind`-RawValues).
2. Scheduler ruft `SettingsManager.shared.showSettings()` auf und postet z. B. `Notification.Name.autoImprovementSuggestionsReady`.
3. **SettingsView** (oder zentraler Ort, der das Sheet steuert) reagiert auf diese Notification (oder prüft in `.onAppear`, ob Pending-Liste nicht leer ist): lädt den **ersten** Fokus aus der Pending-Liste, setzt `pendingSheetKind`, lädt den vorgeschlagenen Text aus der jeweiligen Datei, setzt `showGenerationCompareSheet = true`.
4. **Sheet-Inhalt**: Wie bisher [CompareAndEditSuggestionView](WhisperShortcut/Settings/Components/CompareAndEditSuggestionView.swift), aber mit **zusätzlichem Kopftext**, z. B.: „Wir haben auf Basis Ihrer Nutzung Vorschläge für Ihre System-Prompts erstellt. Bitte prüfen Sie die Änderungen und übernehmen Sie sie oder behalten Sie die aktuelle Version.“
5. **Zusätzlich im Sheet**: Link/Button **„Smarte Verbesserung und Interaktions-Tracking deaktivieren“**. Aktion: Intervall auf „Nie“ setzen (`autoPromptImprovementIntervalDays = 0` bzw. `.never`), `userContextLoggingEnabled = false` setzen, Pending-Liste leeren, Sheet schließen.
6. Bei **„Use current“ / „Use suggested“**: wie bisher (Apply/Restore-Logik im [SettingsViewModel](WhisperShortcut/Settings/Shared/SettingsViewModel.swift)); danach aktuellen Fokus aus Pending-Liste entfernen. Wenn weitere Fokusse in der Liste sind: nächsten Fokus setzen, Sheet-Inhalt wechseln (gleiche Sheet-Instanz, nur andere `pendingSheetKind`/Texte), Sheet offen lassen. Wenn Liste leer: Sheet schließen.

**Technik:** Die bestehende Logik in `SettingsViewModel` (pendingSheetKind, suggestedTextForGeneration, applySuggested*, dismissGenerationSheet) wird wiederverwendet. Neu: eine **Queue** `pendingAutoImprovementKinds: [GenerationKind]`, die beim Öffnen des Sheets bzw. nach Dismiss gefüllt/abgearbeitet wird. Die Queue kann im ViewModel gehalten werden, der initiale Inhalt kommt aus dem Singleton/UserDefaults (vom Scheduler gesetzt).

---

## 4. Einstellungen-UI: Intervall-Auswahl + Logging-Toggle

**Ort:** [GeneralSettingsTab.swift](WhisperShortcut/Settings/Tabs/GeneralSettingsTab.swift) (z. B. im Bereich User Context / Feedback oder eigener Abschnitt „Smarte Verbesserung“).

- **Intervall-Auswahl (Picker/Dropdown):** „Automatische Verbesserung der System-Prompts“ – Optionen: **Nie** | **Alle 7 Tage** | **Alle 14 Tage** | **Alle 30 Tage**. Default: **Alle 7 Tage**. Gebunden an `autoPromptImprovementIntervalDays` (z. B. Enum `AutoImprovementInterval` mit RawValue Int: 0, 7, 14, 30). Hilfstext: Erläutert, dass im Hintergrund auf Basis der Nutzung Vorschläge erzeugt werden und ein Pop-up zur Bestätigung erscheint.
- **Toggle:** „Interaktions-Logging für Vorschläge“ – gebunden an `userContextLoggingEnabled`. Hilfstext: Erläutert, dass Nutzungsdaten lokal für „Generate with AI“ und die automatischen Vorschläge genutzt werden; bei Aus werden keine neuen Interaktionen geloggt.

Optional: Wenn Intervall „Nie“ ist, kann der Logging-Toggle ausgegraut oder mit Hinweis versehen werden, oder beide unabhängig lassen.

Defaults: Intervall 7 Tage, Logging `true`.

---

## 5. Datenfluss (kurz)

```mermaid
sequenceDiagram
  participant App
  participant Scheduler
  participant Derivation
  participant Gemini
  participant Store
  participant Settings

  App->>Scheduler: Check every launch / periodically
  Scheduler->>Scheduler: interval days since last run?
  Scheduler->>Scheduler: interval != Never + logging on?
  Scheduler->>Derivation: updateFromLogs(userContext)
  Derivation->>Gemini: analyze logs
  Scheduler->>Derivation: updateFromLogs(dictation), then promptMode, then promptAndRead
  Derivation->>Gemini: analyze (each focus)
  Scheduler->>Store: Save pendingKinds, set lastRunDate
  Scheduler->>Settings: showSettings() + post notification
  Settings->>Settings: onAppear / notification: show first sheet
  Settings->>Store: pop first kind, show CompareAndEdit
  User->>Settings: Use suggested / Use current / Disable all
  Settings->>Store: pop next or clear; update UserDefaults if disable
```

---

## 6. Dateien (Überblick)

| Änderung                                                        | Datei                                                                                                                                                                               |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Neue Keys, ggf. Defaults                                        | [UserDefaultsKeys.swift](WhisperShortcut/UserDefaultsKeys.swift)                                                                                                                    |
| Logging nur wenn an                                             | [UserContextLogger.swift](WhisperShortcut/UserContextLogger.swift)                                                                                                                  |
| Scheduler + Pending-Store                                       | Neu: `AutoPromptImprovementScheduler.swift` (oder Scheduler + kleines `AutoImprovementPendingStore`)                                                                                |
| App-Start: Scheduler-Check anstoßen + Pending-Prüfung           | [FullApp.swift](WhisperShortcut/FullApp.swift) oder [MenuBarController](WhisperShortcut/MenuBarController.swift) (z. B. in `applicationDidFinishLaunching` oder beim ersten Öffnen) |
| ViewModel: Pending-Queue abarbeiten, Sheet mit „Disable“-Option | [SettingsViewModel.swift](WhisperShortcut/Settings/Shared/SettingsViewModel.swift)                                                                                                  |
| Sheet: Kopftext + „Deaktivieren“-Button                         | [CompareAndEditSuggestionView.swift](WhisperShortcut/Settings/Components/CompareAndEditSuggestionView.swift) (optional erweiterbar) oder neuer Wrapper nur für Auto-Improvement     |
| Settings-UI: Intervall-Picker + Logging-Toggle                  | [GeneralSettingsTab.swift](WhisperShortcut/Settings/Tabs/GeneralSettingsTab.swift)                                                                                                  |
| Notification + onAppear: Sheet öffnen wenn Pending              | [SettingsView.swift](WhisperShortcut/SettingsView.swift)                                                                                                                            |

---

## 7. Privacy und Hinweise

- [privacy.md](privacy.md) anpassen: Erwähnung, dass bei aktivierter automatischer Verbesserung (konfigurierbar: alle 7, 14 oder 30 Tage) dieselbe Logik wie „Generate with AI“ im Hintergrund läuft (Aggregation der letzten 30 Tage, Sendung an Gemini); Nutzer kann Intervall auf „Nie“ stellen oder im Pop-up komplett deaktivieren. Interaktions-Logging ist standardmäßig an, kann aber (neu) ausgestellt werden.
- Optional: Beim ersten Start nach Update einen kurzen Tooltip/Banner in den Einstellungen (einmalig), dass die neue Funktion aktiv ist und wie man sie ausschaltet.

---

## 8. Offene Punkte / Optionen

- **Kopplung:** Beim Klick „Smarte Verbesserung und Tracking deaktivieren“ im Pop-up: Intervall auf „Nie“ setzen, `userContextLoggingEnabled = false`. In den Einstellungen: Intervall-Picker und Logging-Toggle getrennt, sodass Nutzer nur Logging oder nur Auto-Verbesserung (über „Nie“) ausschalten kann.
- **CompareAndEditSuggestionView:** „Disable“-Link/Button als optionaler Parameter einbauen (nur bei Auto-Improvement-Sheet anzeigen), um Wiederverwendung zu erhalten.
