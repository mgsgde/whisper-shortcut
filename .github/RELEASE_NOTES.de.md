## Offline-Diktat
- Normales Diktieren mit einem Offline-Modell bereitet den Text jetzt so auf wie Dictate Live: Füllwörter fallen weg, ein angehängtes „…punkt“ wird getrennt, „GdB“ wird einheitlich geschrieben, und gesprochene Mengenangaben werden zu Ziffern. Zahlwörter im normalen Fließtext bleiben Wörter.

## Verbundene KI-Apps (MCP)
- ChatGPT, Claude und andere verbundene Apps können jetzt die Dokumentation von WhisperShortcut auflisten und lesen, einschließlich des Praxis-Playbooks. So beantworten sie Fragen zur App aus der Dokumentation statt zu raten.

## Einstellungen
- Im Modus „Nur Diktat“ bleibt der Tab „Konten“ sichtbar, solange ein Cloud-Modell zur Transkription gewählt ist, damit Sie dessen Schlüssel eintragen können.
- Einstellungen, Chat in der App und MCP sind sich jetzt einig, ob ein alter eigener Prompt den eingebauten ersetzt.

## Behoben
- Dienste → Dictate Prompt beachtet den Modus „Nur Diktat“.
- Der Modell-Import öffnet Ihren echten Benutzerordner (für ~/.cache/huggingface und ~/.lmstudio/models) und überspringt versteckte Ordner wie unfertige Downloads.
- Beim Umwandeln eines alten eigenen Prompts in Zusätze wird kein alter eingebauter Prompt mehr mitkopiert.
- Praxis-Playbook aktualisiert (v1.1).

## Installation
Laden Sie das DMG von der [Release-Seite](https://github.com/mgsgde/whisper-shortcut/releases), öffnen Sie es und ziehen Sie WhisperShortcut in den Ordner „Programme“.

**Alle Änderungen:** https://github.com/mgsgde/whisper-shortcut/compare/v8.99...v9.00
