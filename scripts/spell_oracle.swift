// Reads one word per line on stdin, prints "1" (known in German or English) or "0" per line.
// Same NSSpellChecker calls as GlossaryFastLearner.isKnownWordInDictationLanguages.
// Build: swiftc -O scripts/spell_oracle.swift -o ~/.cache/whisper-shortcut/spell_oracle
import AppKit

func isKnown(_ word: String) -> Bool {
  let checker = NSSpellChecker.shared
  checker.automaticallyIdentifiesLanguages = false
  for language in ["de", "en"] {
    guard checker.setLanguage(language) else { continue }
    if checker.checkSpelling(of: word, startingAt: 0).location == NSNotFound { return true }
  }
  return false
}

while let line = readLine(strippingNewline: true) {
  print(isKnown(line) ? "1" : "0")
}
