## Vorlesen
- OpenAI stellt seine Sprachausgabe-Modelle am 6. Januar 2027 ein. Vorlesen bietet jetzt GPT-Realtime 2.1 mini an, den von OpenAI genannten Nachfolger. Haben Sie bisher die alte OpenAI-Stimme genutzt und einen OpenAI-Schlüssel hinterlegt, wechselt Vorlesen automatisch auf das neue Modell.

## Offline-Modelle
- Liegen die Dateien eines Offline-Modells schon auf Ihrem Mac (von Hugging Face oder LM Studio), bietet „Laden“ jetzt an, sie zu importieren, statt sie erneut herunterzuladen.

## Dictate Prompt
- Eine Antwort, die fast nur aus den Überlegungen des Modells besteht oder viel zu lang ist, wird nicht mehr eingefügt. Ihre Auswahl bleibt unverändert, und Sie können es erneut versuchen.
- Bei lokalen Modellen wird eine nicht verstandene Anweisung abgelehnt, bevor das Modell läuft, und eine kurze Anweisung, die fast wie einer Ihrer gespeicherten Prompts klingt, verwendet diesen Prompt.

## Chat
- Fragen Sie den Chat, warum ein Ergebnis falsch war, prüft er Ihre letzten Ergebnisse und Ihre Konfiguration. Dann nennt er entweder die Einstellung, die es verursacht hat, mit einer Korrektur, oder schlägt vor, mit `/feedback` einen Bericht zu senden.

## Problem melden
- Berichte zu einem Dictate-Prompt-Ergebnis zeigen jetzt, ob Text um den Cursor und frühere Gesprächsschritte mitgeschickt wurden.

## Intern
- Das Nutzungsprotokoll hält pro Dictate-Prompt-Ergebnis fest, wie viel Text um den Cursor und wie viele frühere Gesprächsschritte mitgeschickt wurden.
- Ungenutzter Code entfernt und gemeinsame Hilfsfunktionen zusammengelegt.

## Installation
Laden Sie das DMG von der [Release-Seite](https://github.com/mgsgde/whisper-shortcut/releases), öffnen Sie es und ziehen Sie WhisperShortcut in den Ordner „Programme“.

**Alle Änderungen:** https://github.com/mgsgde/whisper-shortcut/compare/v9.04...v9.05
