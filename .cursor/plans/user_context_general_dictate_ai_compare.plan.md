---
name: ""
overview: ""
todos: []
isProject: false
---

# User Context in General + „Generate with AI“ mit Vergleichsfenster im Dictate-Tab

## Ziele

1. **User Context in General**: Logging-Info, „Context in Prompt“-Toggle und optional „Update Context“ in den General-Tab. **Interaction Logging ist immer an – keine Option, es auszuschalten** (erster Schritt: einfach immer an).
2. **Dictate-Tab**: Bei Prompt und bei Difficult Words einen Button **„Generate with AI“**; nach dem Generieren ein **Vergleichsfenster** (Alt vs. Neu, editierbar, Use current / Use suggested).
3. **User-Context-Tab**: Entweder entfernen oder auf Rest-Funktionen reduzieren.

---

## 1. Interaction Logging immer an (keine Ausschalt-Option)

- **Vorgabe**: Im ersten Schritt ist Interaction Logging **immer eingeschaltet**. Es gibt **keine Einstellung und keinen Toggle** zum Deaktivieren.
- **Code**:
  - In [UserContextLogger.swift](WhisperShortcut/UserContextLogger.swift): Die Prüfung `guard isLoggingEnabled else { return }` entfällt oder `isLoggingEnabled` liefert immer `true` (z. B. fest `return true` statt UserDefaults zu lesen). So wird bei jedem Aufruf geloggt.
  - Optional: Key `userContextLoggingEnabled` in [UserDefaultsKeys](WhisperShortcut/UserDefaultsKeys.swift) und alle UI-Referenzen darauf entfernen (UserContextSettingsTab, später General), damit nirgends mehr eine „Logging an/aus“-Option angeboten wird.
- **UI in General**: Im User-Context-Bereich nur ein **Hinweistext**, z. B.: „Interactions are logged locally to improve AI suggestions. Logs are automatically deleted after 90 days.“ – **kein Toggle**, kein Schalter.

---

## 2. User-Context-Einstellungen in General

- In [GeneralSettingsTab.swift](WhisperShortcut/Settings/Tabs/GeneralSettingsTab.swift):
  - **User-Context-Bereich** mit:
    - Hinweis: Interaction Logging ist aktiv (siehe oben, nur Text).
    - **Toggle „Include user context in system prompt“** (`UserDefaultsKeys.userContextInPromptEnabled`).
    - Optional: **Button „Update Context“** + Status; ruft `UserContextDerivation().updateContextFromLogs()` auf.
- Kein eigener Tab mehr nötig für „Logging an/aus“, da Logging immer an ist.

---

## 3. Dictate-Tab: „Generate with AI“ + Vergleichsfenster

- **Ort**: [SpeechToTextSettingsTab.swift](WhisperShortcut/Settings/Tabs/SpeechToTextSettingsTab.swift), nur bei Gemini-Modell (wie Prompt- und Difficult-Words-Sektionen).
- **Prompt-Sektion**: Button **„Generate with AI“** → Loading → `updateContextFromLogs()` → Sheet mit **Vergleichsfenster**: Current vs. Suggested (editierbar), Buttons „Use current“ / „Use suggested“ (ggf. „Restore previous“).
- **Difficult-Words-Sektion**: Analog Button „Generate with AI“, gleiches Vergleichsfenster-Pattern.
- **Gemeinsame View**: z. B. `CompareAndEditSuggestionView` (oldText, suggestedText Binding, onUseCurrent, onUseSuggested, optional onRestorePrevious).

---

## 4. User-Context-Tab

- **Option A**: Tab entfernen; alle Inhalte in General (Logging-Info, Context-in-Prompt, Update Context) bzw. Dictate-Tab (Generate with AI + Vergleichsfenster). Andere Suggestions (System Prompts, user-context.md) ggf. kompakter Block in General.
- **Option B**: Tab nur noch für „Delete Data“, „Open Folder“, evtl. Apply/Restore für System Prompts und user-context.md.

---

## 5. Wichtige Dateien

| Änderung                                                                | Datei                                                                                                               |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Logging immer an (Check entfernen oder immer true)                      | [UserContextLogger.swift](WhisperShortcut/UserContextLogger.swift)                                                  |
| Kein Logging-Toggle in UI                                               | [UserContextSettingsTab.swift](WhisperShortcut/Settings/Tabs/UserContextSettingsTab.swift) bzw. nach Umzug: General |
| User-Context-Bereich (nur Hinweis + Context-in-Prompt + Update Context) | [GeneralSettingsTab.swift](WhisperShortcut/Settings/Tabs/GeneralSettingsTab.swift)                                  |
| „Generate with AI“ + Sheet                                              | [SpeechToTextSettingsTab.swift](WhisperShortcut/Settings/Tabs/SpeechToTextSettingsTab.swift)                        |
| Vergleichs-View                                                         | Neue View, z. B. `CompareAndEditSuggestionView.swift`                                                               |

---

## Kurzfassung „Interaction Logging“

- **An**: Immer.
- **Aus**: Nicht vorgesehen (keine Option im ersten Schritt).
- **Umsetzung**: Logging-Code immer ausführen (Guard/Toggle entfernen oder fest auf „an“), in der UI nirgends einen Schalter zum Deaktivieren anbieten.
