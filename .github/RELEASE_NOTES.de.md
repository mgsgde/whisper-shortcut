## Live-Diktat
- **Text kommt in Chrome zuverlässig an.** In Chrome, Edge, Brave, Arc und anderen Chromium-Browsern tippt das Live-Diktat jeden Abschnitt jetzt ein, statt ihn einzufügen, weil diese Browser das Einfügen manchmal verschluckt haben. In anderen Apps prüft WhisperShortcut, ob jeder Abschnitt angekommen ist, und fügt ihn sonst noch einmal ein.
- **Das nächste Diktat schließt an das letzte an.** Ein zweites Live-Diktat in derselben App bekommt jetzt ein Leerzeichen und die richtige Groß- und Kleinschreibung, auch wenn die App WhisperShortcut die Cursorposition nicht lesen lässt. Das wird vergessen, sobald Sie klicken, tippen oder die App wechseln.

## Gesprochene Satzzeichen
Bei Satzzeichen „Nur wenn gesprochen“:
- Kommas und Punkte, die das Modell setzt, bleiben nur dort stehen, wo Sie tatsächlich eine Pause gemacht haben. Geratene Frage- und Ausrufezeichen fallen weg.
- Nach einem entfernten Punkt wird das nächste Wort nicht mehr großgeschrieben („mal weiter“ statt „mal. Weiter“).
- Ein Komma, das am nächsten Wort klebt, bekommt sein Leerzeichen.

## Chat
- **Einfrieren behoben.** Das Chat-Fenster konnte mit hoher CPU-Last hängen, wenn es Meeting-Notizen, einen Hinweis oder die Mail-Anmeldekarte zeigte.

## Installation
Laden Sie das DMG von der [Release-Seite](https://github.com/mgsgde/whisper-shortcut/releases), öffnen Sie es und ziehen Sie WhisperShortcut in den Ordner „Programme“.

**Alle Änderungen:** https://github.com/mgsgde/whisper-shortcut/compare/v8.78...v8.79
