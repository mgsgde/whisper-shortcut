---
name: ""
overview: ""
todos: []
isProject: false
---

# Analytics Integration: Etablierte Alternativen zu TelemetryDeck

## Dein Punkt

TelemetryDeck hat nur ~206 GitHub-Stars – das spricht für eine kleine Nische. Du möchtest etwas mit **größerer Verbreitung** und sichtbarer Community, damit das Tool langfristig stabil und vertrauenswürdig ist.

---

## Etablierte Alternativen (mehr Stars / größere Firma)

### 1. **PostHog** (stärkste Alternative bei „Verbreitung“)

- **Hauptprojekt**: [posthog/posthog](https://github.com/PostHog/posthog) – **~31.000 GitHub-Stars**, 400+ Contributors, 118+ Mitarbeiter.
- **Client für Apple**: [posthog-ios](https://github.com/PostHog/posthog-ios) – offizielles iOS/macOS SDK (Swift), SPM/CocoaPods. Das iOS-SDK-Repo hat wenige Stars, weil die Masse beim Hauptprojekt liegt.
- **Funktionen**: Events, Funnels, Retention, Feature Flags, optional Session Replay. Du sendest nur die Events, die du willst (z.B. „featureUsed“ mit `mode`).
- **Datenschutz**: Cloud (inkl. EU) oder Self-Hosted. Du entscheidest, welche Daten du sendest; für „nur Feature-Nutzung“ kannst du anonyme Events ohne PII senden. Opt-out in den Einstellungen ist üblich.
- **Kosten**: Großzügiger Free-Tier, danach bezahlt.
- **Fazit**: Sehr verbreitet, produktionsreif, gleicher Use-Case wie bei TelemetryDeck („welche Features werden genutzt“) – mit deutlich größerem Ökosystem.

### 2. **Matomo (App-SDK)**

- **Hauptprojekt**: [matomo-org/matomo](https://github.com/matomo-org/matomo) – sehr groß, lange etabliert, datenschutzorientiert.
- **App-SDK**: [matomo-sdk-ios](https://github.com/matomo-org/matomo-sdk-ios) – **~390 Stars**, Swift, unterstützt iOS/macOS/tvOS.
- **Funktionen**: Event-Tracking, Custom Dimensions, Besuche/Sessions. Gut für „Feature X genutzt“.
- **Datenschutz**: Open Source, Self-Hosted oder Matomo Cloud, GDPR-freundlich, keine Cookies nötig.
- **Fazit**: Etabliert und privacy-first; Swift-SDK etwas kleiner als PostHog-Ökosystem, aber solide.

### 3. **Mixpanel**

- **Swift-SDK**: [mixpanel-swift](https://github.com/mixpanel/mixpanel-swift) – **~454 Stars**, aktiv gepflegt.
- **Firma**: Sehr verbreitet in der Industrie (Product Analytics).
- **Funktionen**: Events, Funnels, Retention, User Properties. Du kannst dich auf reine Feature-Events beschränken.
- **Datenschutz**: Klassischer Analytics-Anbieter (USA/Cloud). Du musst bewusst nur anonyme/aggregierte Nutzungsdaten senden und ggf. Opt-out anbieten (DSGVO).
- **Fazit**: Sehr etabliert; eher „Full Product Analytics“. Passt, wenn du bewusst nur Feature-Nutzung trackst und Opt-out einbaust.

### 4. **Amplitude**

- Ähnlich Mixpanel: großer Anbieter, Swift/iOS SDK, SPM/CocoaPods. Weniger explizit „Privacy-first“, aber weit verbreitet. Gleiche Überlegung wie Mixpanel: nur gewünschte Events senden, Opt-out anbieten.

---

## Kurzvergleich (für „Feature-Nutzung“ + Verbreitung)

| Tool              | „Verbreitung“ (Stars/Firma)    | Privacy-First            | Swift/macOS | Self-Host möglich |
| ----------------- | ------------------------------ | ------------------------ | ----------- | ----------------- |
| **PostHog**       | Sehr hoch (~31k, große Firma)  | Konfigurierbar           | Ja          | Ja                |
| **Matomo**        | Hoch (großes Ökosystem)        | Ja                       | Ja          | Ja                |
| **Mixpanel**      | Hoch (454* Swift, große Firma) | Nein, aber einschränkbar | Ja          | Nein (Cloud)      |
| **TelemetryDeck** | Niedrig (~206)                 | Ja                       | Ja          | Nein              |

 Mixpanel: 454 Stars auf dem Swift-SDK; Firma insgesamt sehr groß.

---

## Empfehlung bei Fokus auf „stark verbreitet“

- **Beste Balance Verbreitung + Datenschutz + gleicher Use-Case**: **PostHog**. Großes Open-Source-Projekt, klare Roadmap, iOS/macOS-SDK, du sendest nur anonyme Feature-Events, optional Self-Host oder EU-Cloud.
- **Wenn du explizit Open Source + Privacy-first willst und Self-Host magst**: **Matomo** (matomo-sdk-ios für Swift/macOS).
- **Wenn dir Unternehmensgröße wichtiger ist als Privacy-First**: **Mixpanel** oder **Amplitude** – dann bewusst nur anonyme Nutzungs-Events senden und Opt-out in den Einstellungen.

Die technische Integration bleibt ähnlich wie im ersten Plan: ein Analytics-Helper, der bei `feedback(.success(...))` (und optional Settings/Chat) ein Event sendet, plus Einstellung „Anonymous usage statistics“ und Aktualisierung der Datenschutzerklärung.

Wenn du möchtest, kann der nächste Schritt ein konkreter Implementierungsplan für **PostHog** sein (SPM, Init, Event-Namen, Privacy-Text).
