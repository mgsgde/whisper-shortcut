// SpokenPunctuation.swift is symlinked from the app and names PunctuationMode on
// apply(to:mode:). The benchmark only reads SpokenPunctuation.commandWords
// (ParakeetVocabularyGuard). These cases exist so that file compiles; they do
// not reimplement the app's punctuation-mode logic.
enum PunctuationMode: String, Equatable {
  case automatic
  case spokenOnly
}
