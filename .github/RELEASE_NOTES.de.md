## Sicherheit
- **Ihre Schlüssel bleiben, wo sie hingehören.** Ihr OpenAI-Schlüssel und Tokens für eigene Server gehen nicht mehr an unverschlüsselte http-Hosts in Ihrem Netzwerk (localhost funktioniert weiter) und werden bei einer Weiterleitung auf einen anderen Server entfernt. Das gilt jetzt auch für die Meeting-Transkription.
- **Sicherere Links im Chat.** Links in Chat-Antworten öffnen sich nur noch für http, https und mailto. file://- und andere Links tun nichts.
- Fehlerprotokolle von Mail, Aufgaben und Trello enthalten keine Titel, Anweisungen oder Trello-Schlüssel mehr.
- Eine manipulierte, tief verschachtelte E-Mail kann die App nicht mehr einfrieren oder abstürzen lassen.

## Offline-Diktat
- **„Nur wenn gesprochen“ behält Satzzeichen am Satzende.** Punkte, Fragezeichen, Ausrufezeichen und Doppelpunkte, die das Modell setzt, bleiben jetzt stehen; nur seine Kommas und Semikolons werden entfernt. Gesprochene Satzzeichen funktionieren wie bisher.
- **Das Glossar ist vorsichtiger.** Das Offline-Modell lässt keine Laborwerte wie „HbA1c 7,2“ mehr weg und tauscht kein Glossar-Medikament gegen ein anderes. Die Schreibweise aus dem Glossar bleibt erhalten („GdB 50“).
- „…schrägstrich“ und „3-Pünktchen“ werden auch umgewandelt, wenn das Modell sie an das vorherige Wort hängt.

## Neu: Dienste-Menü
Text in einer beliebigen App markieren, Rechtsklick → Dienste: **Read Aloud with WhisperShortcut**, **Add to WhisperShortcut Glossary** und **Dictate Prompt with WhisperShortcut**. Ohne Bedienungshilfen-Berechtigung.

## Chat
- Antworten behalten ihre Zeilenumbrüche. „5 $“, `$HOME` und Windows-Pfade wie C:\Users\… erscheinen so, wie sie geschrieben sind; echte Formeln werden weiter dargestellt.
- Claude bricht in der letzten Tool-Runde nicht mehr mit einem Fehler ab.
- Chat mit OpenAI, Anthropic, xAI und anderen versucht es automatisch erneut, wenn der Anbieter kurz drosselt.
- Leere Antworten nach dem Beenden mitten in einer Antwort werden repariert; eingefügte HEIC-/TIFF-Bilder werden umgewandelt; Suche und automatische Titel verbessert.
- Ein lokaler Server ohne Schlüssel wird als bereit angezeigt.

## Meetings
- Text, der erst nach dem Ende eines Meetings fertig transkribiert ist, landet in diesem Meeting und in der richtigen Reihenfolge, nicht im nächsten.
- Ein zweiter Druck auf den Meeting-Kurzbefehl während der Verarbeitung beendet das Meeting nicht mehr.
- Ein zweites Stopp, während ein Meeting abgeschlossen wird, hängt nicht mehr.

## Fehlerbehebungen
- **Zurücksetzen in den Einstellungen löscht alle privaten Daten** (geladene Modelle und Workspace-Backups bleiben). Gespeicherte Audio-Proben werden nach 30 Tagen gelöscht.
- Vorlesen endet sauber nach einem Fehler mitten im Satz.
- Ein Glossar-Begriff, den der Chat hinzufügt, während der Glossar-Editor offen ist, wird nicht mehr überschrieben.
- Klarere Status- und Fehlertexte („Dictate Prompt“, „Read Aloud“, „Ungültiger API-Schlüssel“ → Einstellungen → Konten).
- Klarere Gemini-Fehler bei fehlendem Abo und Drosselung.
- API-Schlüssel-Felder speichern einmal pro Tipp-Pause.
- Kalendertermine wechseln korrekt zwischen ganztägig und mit Uhrzeit; MCP-Meetinglisten hängen nicht mehr, während ein Dialog offen ist.
- Die Direkt-Version fordert nicht mehr zum Bewerten oder Kaufen im App Store auf.

## Installation
Laden Sie das DMG von der [Release-Seite](https://github.com/mgsgde/whisper-shortcut/releases), öffnen Sie es und ziehen Sie WhisperShortcut in den Ordner „Programme“.

**Alle Änderungen:** https://github.com/mgsgde/whisper-shortcut/compare/v8.77...v8.78
