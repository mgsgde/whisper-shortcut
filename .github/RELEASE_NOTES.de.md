## Glossar
- **Der Glossar-Kurzbefehl lernt, was falsch verstanden wurde:** Korrigieren Sie ein Wort aus Ihrem letzten Diktat, markieren Sie es und drücken Sie den Glossar-Kurzbefehl. WhisperShortcut speichert jetzt auch die gehörte Form, sodass das Offline-Diktat (Parakeet) das Wort beim nächsten Mal richtig schreibt. Die Bestätigung zeigt beides, etwa: „Lasègue“ zum Glossar hinzugefügt (gehört als „Lasse“).
- Neue Glossar-Begriffe kommen in eine eigene Zeile, wenn Ihr Glossar einen Begriff pro Zeile hat, statt an die letzte Zeile angehängt zu werden.

## Kurzbefehle
- Ein Kurzbefehl, der wegen eines Konflikts wartet („Wird gerade genutzt von …“), wird neu geprüft, sobald Sie einen anderen Kurzbefehl ändern, und zugewiesen, sobald seine Taste frei ist.
- Die Konfliktprüfung und „Neu zuweisen“ berücksichtigen jetzt auch die Tasten von Vorlagen und die Taste für die Vorlagenauswahl.

## MCP
- `get_configuration` listet jetzt alle Kurzbefehle, einschließlich Dictate Live und Vorlagentasten, und Ihre Vorlagen.
- Neue Tools `create_template`, `update_template` und `delete_template`, mit denselben Freigabestufen und demselben Rückgängig wie `save_command`.

## Installation
Laden Sie das DMG von der [Release-Seite](https://github.com/mgsgde/whisper-shortcut/releases), öffnen Sie es und ziehen Sie WhisperShortcut in den Ordner „Programme“.

**Alle Änderungen:** https://github.com/mgsgde/whisper-shortcut/compare/v8.94...v8.95
