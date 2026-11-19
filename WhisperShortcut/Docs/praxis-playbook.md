# Praxis-Playbook v1

Stand: 19. November 2026. Für alle, die WhisperShortcut in einer Arztpraxis oder Therapiepraxis einrichten.

Dieses Playbook gilt, bis eine neue Version erscheint („Playbook v2“). Tipps aus Chats, Telefonaten oder von einer KI ändern nichts daran. Wenn etwas hier nicht passt, melden Sie es (Abschnitt 9). Dann kommt es in die nächste Version.

Die Begriffe stehen so da, wie die App sie auf Deutsch zeigt. Auf einem englischen Mac heißen sie: Diktieren = Dictate, Vorlagen = Templates, Glossar = Glossary, Schreibstil = Writing Style.

## 1. Einrichten in fünf Schritten

1. **Die Version von der Website installieren**, nicht die aus dem App Store. Nur sie fügt den Text selbst an der Cursorposition ein und kann die Fn-Taste nutzen.
2. **Beim ersten Start die Berechtigungen geben**: Mikrofon und Bedienungshilfen. Ohne Bedienungshilfen landet der Text nur in der Zwischenablage.
3. **Einen Gemini-API-Schlüssel eintragen.** Mehr braucht es nicht. Mit dem Schlüssel stellt die App die Modelle selbst ein (Diktieren: Gemini 3.1 Flash Lite, Dictate Prompt: Gemini 3.8 Flash). **Die Modelle nicht umstellen**, auch nicht auf Empfehlung von Bekannten oder einer KI.
4. **Update-Kanal auf „Stabil“ lassen** (Einstellungen → Allgemein). Praxen bekommen nur Versionen, die vorher getestet wurden.
5. **Tasten einrichten** (Abschnitt 3) und mit der Praxis einmal jede Funktion ausprobieren.

Offline-Modus (Einstellungen → Datenschutz & Berechtigungen) nur, wenn die Praxis ausdrücklich verlangt, dass nichts den Mac verlässt. Dann diktiert die App mit Parakeet Ultra auf dem Gerät. Das ist schnell und gut, aber Dictate Prompt und Vorlagen laufen dann mit einem kleinen lokalen Modell und sind spürbar schwächer.

## 2. Welche Funktion wofür

| Was die Praxis schreiben will | Funktion | Was passiert |
|---|---|---|
| Befund, Anamnese, Therapie, Bericht | **Vorlage** | Was man sagt, kommt in das feste Format der Praxis, mit deren Überschriften. |
| E-Mail, Brief, kurze Nachricht | **Dictate Prompt** | Ohne markierten Text schreibt die App einen neuen Text nach der Ansage („schreib eine Antwort, dass der Termin am Freitag passt“). Mit markiertem Text ändert sie ihn („kürzer“, „freundlicher“, „auf Englisch“). |
| Alles andere | **Diktieren** | Die App schreibt auf, was man sagt, mit Satzzeichen, nah am Wortlaut. |

Kurz: **Befunde mit Vorlage, Mails mit Dictate Prompt, der Rest mit Diktieren.**

Dictate Prompt ist für kurze Ansagen gebaut, nicht für ein Diktat von zehn Minuten. Lange Diktate gehen mit Diktieren oder einer Vorlage.

## 3. Tasten

Empfehlung:

- **Fn (🌐) für Diktieren.** Ist ab Werk an, wenn die Fn-Taste frei ist. Ist sie in macOS schon belegt (Emoji, Diktierfunktion von Apple), zeigt die App das an und stellt es auf Wunsch um: Systemeinstellungen → Tastatur → „Drücken der 🌐-Taste“ → „Keine Aktion“.
- **⌘2 für Dictate Prompt, ⌘3 für die Vorlage**, weitere Funktionen nach Bedarf auf ⌘4 und ⌘5.

Ab Werk liegen die Funktionen auf längeren Kombinationen. Ändern unter Einstellungen → Allgemein. Vorher kurz prüfen, ob die Praxissoftware ⌘2 oder ⌘3 selbst benutzt.

**Diktiermikrofone (z. B. SpeechMike):** keine direkte Anbindung. Die Tasten des Mikrofons lassen sich aber in dessen eigener Software auf diese Tastenkürzel legen. Das funktioniert. Eine Vorlage kann auch ein eigenes Kürzel bekommen, für eine eigene Mikrofontaste.

## 4. Vorlagen einrichten

Einstellungen → Vorlagen. Pro Dokumentart eine Vorlage, zum Beispiel „Befund“ mit den Überschriften Anamnese, Befund, Therapie. Einmal anlegen, ein Kürzel geben, fertig.

- Kürzel drücken, sprechen, nochmal drücken: der Text kommt im Format der Vorlage an der Cursorposition an, auch in Praxissoftware im Browser.
- Mehrere Vorlagen: die App zeigt eine nummerierte Liste, Auswahl mit 1–9.
- Text markiert und dann das Kürzel: die Vorlage formatiert den markierten Text.
- Format kam, obwohl normaler Text gewollt war: Menüleiste → „Nochmal ohne Vorlage“.

Den Wunsch nach einem bestimmten Format immer als Vorlage umsetzen, **nie über die Anweisungen von Dictate Prompt**. Vorlagen nutzen weder diese Anweisungen noch den Schreibstil, darum bleiben Befunde Befunde und Mails Mails.

## 5. Glossar

Einstellungen → Diktieren → Glossar. Hier stehen **nur Wörter, die beim Diktieren falsch herauskommen**, richtig geschrieben: Medikamente, Fachbegriffe, Namen von Kolleginnen und Kollegen, Ortsnamen.

- Ein Begriff pro Eintrag. Keine Sätze, keine Erklärungen, keine Notizen.
- Keine Allerweltswörter oder häufigen Namen, die ohnehin richtig erkannt werden. Jeder überflüssige Eintrag macht die Erkennung eher schlechter.
- Schnellster Weg: das richtig geschriebene Wort irgendwo markieren und im Menü „Auswahl zum Glossar hinzufügen“ wählen.

## 6. Schreibstil

Gilt **nur für Dictate Prompt**, also für Mails und Nachrichten. Diktieren, Vorlagen und Chat bleiben davon unberührt. Für Befunde spielt er keine Rolle.

Die App lernt den Stil selbst: aus gesendeten Gmail-Mails, wenn ein Google-Konto verbunden ist, und aus dem, was mit Diktieren in Mail- und Chat-Apps diktiert wird. Nach etwa 20 neuen Nachrichten schlägt sie ein Profil vor, das man in der Menüleiste bestätigt. **Den Schreibstil nicht von Hand schreiben oder mit KI-Texten füttern.** Einschalten unter Einstellungen → Dictate Prompt → Schreibstil.

## 7. Prompts nicht anfassen

Die Anweisungen (System-Prompts) für Diktieren und Dictate Prompt bleiben, wie sie ab Werk sind. Keine selbst geschriebenen oder von einer KI erzeugten Prompts einsetzen: das hat in Pilotpraxen mehr verschlechtert als verbessert. Was die Praxis anders haben will, geht in eine Vorlage (Abschnitt 4) oder ins Glossar (Abschnitt 5). Reicht das nicht, melden (Abschnitt 9).

## 8. Was die App kann und was nicht

Für Gespräche mit Praxen. Bitte nichts versprechen, was unter „Kann nicht“ steht.

**Kann:**

- In jedes Programm diktieren, in dem man tippen kann, auch in Praxissoftware im Browser.
- Diktate in das feste Format der Praxis bringen (Vorlagen).
- Komplett auf dem Mac arbeiten, ohne dass Audio oder Text den Mac verlassen (Offline-Modus).
- Mails und Nachrichten im Stil der Person entwerfen (Dictate Prompt mit Schreibstil).

**Kann nicht, bitte nicht versprechen:**

- **Keine eigenen Server.** Mit Gemini gehen Audio und Text an Google. Wer Daten nur in der EU will, braucht entweder den Offline-Modus oder einen eigenen Vertrag mit Azure oder Google Cloud. Die App ist kein zertifiziertes Medizinprodukt.
- **Keine direkte Anbindung von Diktiermikrofonen**, nur über Tastenbelegung (Abschnitt 3).
- **Keine Windows-Version für Praxen**, kein iPhone, kein Android.
- **Kein wortgetreues Protokoll mit Vorlagen oder Dictate Prompt.** Diese beiden ordnen und formulieren. Wer jedes Wort braucht, nimmt Diktieren.

## 9. Probleme melden

Ein Weg für alles: **direkt nach dem Problem in der Menüleiste „Feedback senden“ → „Problem mit letztem Ergebnis melden…“** wählen und in einem Satz schreiben, was erwartet war. Die App zeigt das betroffene Ergebnis zur Kontrolle und schickt es mit Modell und Version. Das ersetzt Screenshots, Nachfragen nach der Version und lange Beschreibungen per WhatsApp.

Wünsche und Fragen sammeln und gebündelt besprechen, nicht einzeln zwischendurch.

## 10. Änderungen

Ändert sich etwas an diesen Regeln, erscheint eine neue Version dieses Playbooks mit Datum und einer kurzen Liste, was anders ist. Alles, was nicht in einer neuen Version steht, gilt weiter wie hier beschrieben.

Dieses Playbook liegt auch in der App: Der Chat in WhisperShortcut kann es lesen und Fragen dazu beantworten.
