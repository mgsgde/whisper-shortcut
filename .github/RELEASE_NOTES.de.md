## Datenschutz und Datensicherheit
- **Meetings bleiben ohne Meeting-Schlüssel lokal.** Ist für Meetings kein Schlüssel gesetzt, wechselt die Meeting-Transkription nicht mehr zu einem Cloud-Modell.
- **Der Chatverlauf wird nie überschrieben.** Lässt sich der Chat-Speicher nicht lesen, bleibt er unangetastet, statt durch einen leeren ersetzt zu werden.

## Meetings
- Beim Beenden der App oder wenn die Aufnahme während eines Meetings ausfällt, geht weniger Audio verloren.
- Nach dem Fortsetzen eines Meetings werden Notizen und Zusammenfassung wieder aktualisiert, und neue Abschnitte stehen an der richtigen Zeit.
- Notizen eines fortgesetzten Meetings werden durch eine spätere Bearbeitung nicht mehr gelöscht.

## Vorlesen
- **Ihr eigener Server.** Vorlesen kann jetzt über Ihren eigenen OpenAI-kompatiblen Server sprechen (Einstellungen → Vorlesen → Eigener Server).
- Die letzte Silbe wird nicht mehr abgeschnitten.
- Qwen3-Stimmen beginnen nicht mehr mit langer Stille vor Text, der mit einer Webadresse oder Autorenzeile anfängt.
- Als Referenzstimme importierte Stereoaufnahmen kommen nicht mehr fast stumm an.

## Chat
- Nummerierte und verschachtelte Listen werden richtig angezeigt, und Text mit einem „|“ erscheint nicht mehr als Tabelle.
- Rückgängig (⌘Z) funktioniert im Eingabefeld nach dem Einfügen eines Chips und nach dem Senden.
- Korrekturen für Google Tasks (Fälligkeitsdaten, ausgeblendete und lange Listen), das Blättern im Google Kalender und Suchen mit „+“ in Gmail und Trello.
- Der Chat und über MCP verbundene KI-Apps können WhisperShortcut jetzt auf Wunsch anhand Ihres Nutzungsprotokolls anpassen. Die automatische Smart Improvement entfällt; ihre Einstellungen finden Sie jetzt unter Datenschutz & Berechtigungen und Dictate Prompt.

## Diktat und Einrichtung
- Die Offline-Karte im Onboarding geht erst weiter, wenn das Offline-Modell fertig heruntergeladen ist.
- Gesprochene Satzzeichen erzeugen weniger falsche Zeichen, und das Qwen3-Diktat nutzt Ihr Glossar.
- Die Einstellungen erklären, dass Ihr eigener Server den Diktat-Prompt ignoriert; „Prüfen“ testet jetzt dieselbe Adresse, die das Diktat verwendet.
- Zwischenablage: „Zum Glossar hinzufügen“ stellt Ihre Zwischenablage wieder her, und Glossar und Vorlesen greifen keine alte Zwischenablage mehr auf. Eine VS-Code-Zeilenkopie ohne Auswahl gilt als „nichts ausgewählt“.
- Korrekturen für die Fn-Abbruchtaste, das Symbol bei fehlender Einrichtung, das Mikrofon nach einer abgebrochenen Berechtigungsabfrage, Zeitüberschreitungen bei der OpenRouter-Transkription, die Aufnahmeanzeige nach Bildschirmwechseln und Systemaudio nach Gerätewechseln.
- Das Verbinden von Claude Desktop aus einer Kopie, die nicht im Programme-Ordner liegt, wird mit einer Erklärung abgelehnt.

## Installation
Laden Sie das DMG von der [Release-Seite](https://github.com/mgsgde/whisper-shortcut/releases), öffnen Sie es und ziehen Sie WhisperShortcut in den Ordner „Programme“.

**Alle Änderungen:** https://github.com/mgsgde/whisper-shortcut/compare/v8.87...v8.88
