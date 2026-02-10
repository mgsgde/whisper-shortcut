---
name: ""
overview: ""
todos: []
isProject: false
---

---

name: Update Context Limits
overview: "Sinnvolle Limits und gestaffeltes Recency-Sampling für „Update Kontext" einführen, damit neuere Interaktionen stärker gewichtet werden und die Datenmenge kontrolliert bleibt."
todos:

- id: defaults-keys
content: "UserDefaultsKeys + AppConstants: Keys und Default-Werte für Limits anlegen"
- id: tiered-sampling
content: "UserContextDerivation: Gestaffeltes Recency-Sampling (50/30/20) implementieren"
- id: char-limit-sort
content: "UserContextDerivation: Nach ts sortieren vor Zeichenlimit, neueste behalten"
- id: settings-ui
content: "UserContextSettingsTab: UI für max Einträge pro Modus + max Zeichen"
- id: feedback
content: "Statusmeldung erweitern: X Einträge, ~Y Zeichen verwendet"
isProject: false

---

# Limits für „Update Kontext" mit Recency-Bias

## Ausgangslage

Beim Klick auf **Update Context** werden Interaktionslogs geladen, aggregiert und an Gemini zur Analyse geschickt. Aktuell gelten in [UserContextDerivation.swift](WhisperShortcut/UserContextDerivation.swift) feste Grenzen:

- Zeitfenster: letzte **30 Tage**
- Einträge pro Modus: **50** (transcription, prompt, readAloud) → max. 150 gesamt
- Zeichen pro Feld: **2000**
- Gesamtzeichen: **100.000**

Schwächen:

1. **Nicht konfigurierbar** – bei viel Nutzung kann man die Menge nicht reduzieren.
2. **Kein Recency-Bias** – ältere und neuere Einträge werden gleich behandelt.
3. **Reihenfolge beim Kappen willkürlich** – Dictionary-Iteration, nicht chronologisch.

---

## Lösung: Gestaffeltes Recency-Sampling (50 / 30 / 20)

### Kernidee

Statt gleichmäßig über 30 Tage zu samplen, wird nach **Aktualität gestaffelt**:

| Zeitraum      | Anteil am Budget | Beispiel bei 30 Einträgen/Modus |
| ------------- | ---------------- | ------------------------------- |
| Letzte 7 Tage | **50%**          | 15 Einträge                     |
| Tag 8–14      | **30%**          | 9 Einträge                      |
| Tag 15–30     | **20%**          | 6 Einträge                      |

Pro Modus wird das Budget auf die drei Zeitfenster aufgeteilt. Innerhalb jedes Fensters wird wie bisher gleichmäßig gesampelt.

**Vorteil**: Neueste Daten dominieren, ältere fließen noch ein (für Langzeit-Muster), aber mit geringerem Gewicht.

---

## Umsetzung

### 1. UserDefaultsKeys + AppConstants

[UserDefaultsKeys.swift](WhisperShortcut/UserDefaultsKeys.swift) – neue Keys:

```swift
static let userContextMaxEntriesPerMode = "userContextMaxEntriesPerMode"
static let userContextMaxTotalChars = "userContextMaxTotalChars"
```

[AppConstants.swift](WhisperShortcut/AppConstants.swift) – Defaults:

```swift
// MARK: - User Context Derivation Limits
static let userContextDefaultMaxEntriesPerMode: Int = 30
static let userContextDefaultMaxTotalChars: Int = 60_000

// Tiered sampling ratios (must sum to 1.0)
static let userContextTier1Days: Int = 7      // most recent
static let userContextTier1Ratio: Double = 0.50
static let userContextTier2Days: Int = 14     // up to day 14
static let userContextTier2Ratio: Double = 0.30
static let userContextTier3Days: Int = 30     // up to day 30
static let userContextTier3Ratio: Double = 0.20
```

### 2. UserContextDerivation – Gestaffeltes Sampling

In `loadAndSampleLogs()` die Sampling-Logik ersetzen:

```swift
private func loadAndSampleLogs() throws -> String {
  let maxPerMode = UserDefaults.standard.object(forKey: UserDefaultsKeys.userContextMaxEntriesPerMode) as? Int
    ?? AppConstants.userContextDefaultMaxEntriesPerMode
  let maxChars = UserDefaults.standard.object(forKey: UserDefaultsKeys.userContextMaxTotalChars) as? Int
    ?? AppConstants.userContextDefaultMaxTotalChars

  // Load all entries from last 30 days, grouped by mode
  let logFiles = UserContextLogger.shared.interactionLogFiles(lastDays: AppConstants.userContextTier3Days)
  // ... parse into entriesByMode ...

  // Tiered sampling per mode
  var sampledEntries: [InteractionLogEntry] = []
  let now = Date()
  let tier1Cutoff = Calendar.current.date(byAdding: .day, value: -AppConstants.userContextTier1Days, to: now)!
  let tier2Cutoff = Calendar.current.date(byAdding: .day, value: -AppConstants.userContextTier2Days, to: now)!

  for (_, entries) in entriesByMode {
    // Split entries into tiers by timestamp
    let tier1 = entries.filter { parseDate($0.ts) >= tier1Cutoff }
    let tier2 = entries.filter { let d = parseDate($0.ts); return d < tier1Cutoff && d >= tier2Cutoff }
    let tier3 = entries.filter { parseDate($0.ts) < tier2Cutoff }

    // Calculate budget per tier
    let budget1 = Int(Double(maxPerMode) * AppConstants.userContextTier1Ratio)  // 50%
    let budget2 = Int(Double(maxPerMode) * AppConstants.userContextTier2Ratio)  // 30%
    let budget3 = maxPerMode - budget1 - budget2                                 // 20%

    // Sample evenly within each tier
    sampledEntries.append(contentsOf: evenSample(tier1, max: budget1))
    sampledEntries.append(contentsOf: evenSample(tier2, max: budget2))
    sampledEntries.append(contentsOf: evenSample(tier3, max: budget3))
  }

  // Sort by timestamp (oldest first) so oldest get dropped first at char limit
  sampledEntries.sort { $0.ts < $1.ts }

  // Build aggregated text with char limit (oldest dropped first)
  // ... existing logic with maxChars ...
}

private func evenSample(_ entries: [InteractionLogEntry], max: Int) -> [InteractionLogEntry] {
  guard entries.count > max else { return entries }
  let step = Double(entries.count) / Double(max)
  return (0..<max).map { entries[Int(Double($0) * step)] }
}

private func parseDate(_ iso: String) -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.date(from: iso) ?? .distantPast
}
```

### 3. Zeichenlimit mit neueste-behalten-Logik

Nach dem Sortieren (`$0.ts < $1.ts` → älteste zuerst) beim Aggregieren:

- Einträge von vorne durchgehen (= älteste zuerst).
- Bei Überschreitung von `maxTotalChars` mit `break` stoppen.
- **Ergebnis**: Die neuesten Einträge bleiben im Aggregat.

### 4. Settings-UI

[UserContextSettingsTab.swift](WhisperShortcut/Settings/Tabs/UserContextSettingsTab.swift) – neuer Bereich unter „Update Context":

```swift
// MARK: - Limits Section
@AppStorage(UserDefaultsKeys.userContextMaxEntriesPerMode) 
private var maxEntriesPerMode: Int = AppConstants.userContextDefaultMaxEntriesPerMode

@AppStorage(UserDefaultsKeys.userContextMaxTotalChars) 
private var maxTotalChars: Int = AppConstants.userContextDefaultMaxTotalChars

private var limitsSection: some View {
  VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
    SectionHeader(
      title: "Update Limits",
      subtitle: "Control how much data is analyzed"
    )

    Stepper("Max entries per mode: \(maxEntriesPerMode)", 
            value: $maxEntriesPerMode, in: 10...100, step: 10)

    Stepper("Max total characters: \(maxTotalChars / 1000)k", 
            value: $maxTotalChars, in: 20_000...150_000, step: 10_000)

    Text("Recent interactions are prioritized: 50% from last 7 days, 30% from days 8–14, 20% from older.")
      .font(.callout)
      .foregroundColor(.secondary)
  }
}
```

### 5. Statusmeldung erweitern

Nach erfolgreichem Update in [UserContextSettingsTab.swift](WhisperShortcut/Settings/Tabs/UserContextSettingsTab.swift):

```swift
statusMessage = "Context updated (\(entryCount) entries, ~\(charCount / 1000)k chars)"
```

Dazu `updateContextFromLogs()` so erweitern, dass es die Statistik zurückgibt (z.B. als Tuple oder kleine Struct).

---

## Zusammenfassung

1. **Gestaffeltes Sampling**: 50% neueste Woche, 30% Woche 2, 20% älter → Recency-Bias
2. **Konfigurierbare Limits**: Max Einträge/Modus (default 30), Max Zeichen (default 60k)
3. **Chronologische Priorisierung**: Bei Zeichenlimit werden älteste Einträge zuerst weggelassen
4. **Feedback**: Statusmeldung zeigt, wie viel tatsächlich verwendet wurde

Keine Änderung an Log-Rotation (90 Tage) oder am Gemini-Prompt selbst.
