import Foundation

/// Everyday German words, so a glossary term cannot replace one.
///
/// FluidAudio's CTC rescorer adds the same flat boost to every glossary term. A term one
/// letter away from a common word then wins ("weiter" → "Seiter").
/// `ParakeetVocabularyGuard` rejects a replacement whose every word is in this list.
/// Clinical vocabulary, drug names, abbreviations and proper names are absent: those are
/// what a glossary is for.
enum GermanCommonWords {
  /// Lowercase. `contains` folds case and diacritics with `GlossaryDocument.fold`.
  static let all: Set<String> = [
    // Articles, determiners, pronouns
    "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "einem", "einen", "eines",
    "kein", "keine", "keiner", "keinem", "keinen", "keines", "mein", "meine", "meiner", "meinem",
    "meinen", "meines", "dein", "deine", "deiner", "deinem", "deinen", "deines", "sein", "seine",
    "seiner", "seinem", "seinen", "seines", "ihr", "ihre", "ihrer", "ihrem", "ihren", "ihres",
    "unser", "unsere", "unserer", "unserem", "unseren", "unseres", "euer", "eure", "dieser",
    "diese", "dieses", "diesem", "diesen", "jeder", "jede", "jedes", "jedem", "jeden", "alle",
    "aller", "allem", "allen", "alles", "beide", "beiden", "einige", "einigen", "viele", "vielen",
    "andere", "anderer", "anderen", "anderes", "welche", "welcher", "welches", "welchen", "welchem",
    "ich", "du", "er", "sie", "es", "wir", "mich", "dich", "ihn", "uns", "euch", "mir", "dir",
    "ihm", "ihnen", "sich", "selbst", "selber", "man", "jemand", "niemand", "etwas", "nichts",
    "wer", "wen", "wem", "wessen", "was",
    // Prepositions and conjunctions
    "in", "im", "ins", "an", "am", "ans", "auf", "aus", "bei", "beim", "mit", "nach", "von", "vom",
    "vor", "zu", "zum", "zur", "über", "unter", "hinter", "neben", "zwischen", "gegen", "ohne",
    "um", "durch", "für", "seit", "bis", "ab", "außer", "wegen", "während", "trotz", "statt", "und",
    "oder", "aber", "sondern", "denn", "weil", "dass", "ob", "wenn", "als", "wie", "sowie", "bevor",
    "ehe", "nachdem", "sobald", "solange", "obwohl", "falls", "sofern", "damit", "sodass", "wobei",
    "warum", "wieso", "weshalb", "wohin", "woher", "wo", "wann", "weder", "noch", "entweder",
    // Auxiliaries and modals
    "bin", "bist", "ist", "sind", "seid", "war", "warst", "waren", "wart", "gewesen", "sei", "wäre",
    "wären", "habe", "hab", "hast", "hat", "haben", "habt", "hatte", "hattest", "hatten", "hattet",
    "gehabt", "hätte", "hätten", "werde", "wirst", "wird", "werden", "werdet", "wurde", "wurdest",
    "wurden", "wurdet", "geworden", "würde", "würden", "kann", "kannst", "können", "könnt",
    "konnte", "konntest", "konnten", "gekonnt", "könnte", "könnten", "muss", "musst", "müssen",
    "müsst", "musste", "musstest", "mussten", "musstet", "müsste", "müssten", "soll", "sollst",
    "sollen", "sollt", "sollte", "solltest", "sollten", "solltet", "will", "willst", "wollen",
    "wollt", "wollte", "wolltest", "wollten", "wolltet", "gewollt", "darf", "darfst", "dürfen",
    "dürft", "durfte", "durften", "dürfte", "dürften", "mag", "magst", "mögen", "möchte",
    "möchtest", "möchten", "mochte",
    // Adverbs and particles
    "weiter", "dann", "jetzt", "mal", "schon", "auch", "nur", "sehr", "eigentlich", "wieder",
    "immer", "gerade", "heute", "morgen", "gestern", "hier", "dort", "da", "so", "doch", "eben",
    "vielleicht", "also", "dabei", "dazu", "daher", "deshalb", "trotzdem", "bereits", "nie", "oft",
    "sonst", "zwar", "jedoch", "insgesamt", "ebenfalls", "weiterhin", "zudem", "außerdem",
    "allerdings", "eher", "kaum", "fast", "ganz", "wirklich", "natürlich", "leider", "bitte",
    "danke", "gern", "gerne", "sofort", "später", "früher", "bald", "endlich", "plötzlich", "etwa",
    "ungefähr", "genau", "einfach", "besonders", "sogar", "nämlich", "übrigens", "durchaus",
    "überhaupt", "schließlich", "inzwischen", "bisher", "zuerst", "danach", "darauf", "darüber",
    "dafür", "davon", "irgendwie", "irgendwo", "manchmal", "häufig", "selten", "oben", "unten",
    "hinten", "links", "rechts", "zusammen", "allein", "zurück", "nicht", "ja", "nein", "nochmal",
    "einmal", "wahrscheinlich", "hoffentlich", "genug", "sicher", "klar", "wohl", "direkt",
    "deutlich", "ziemlich",
    // Common nouns
    "seite", "seiten", "zeit", "zeiten", "jahr", "jahre", "tag", "tage", "woche", "wochen", "monat",
    "monate", "mensch", "menschen", "frau", "frauen", "mann", "männer", "kind", "kinder", "arbeit",
    "hand", "hände", "teil", "teile", "leiter", "weg", "wege", "fall", "fälle", "frage", "fragen",
    "grund", "gründe", "prinzip", "stunde", "stunden", "minute", "minuten", "abend", "nacht",
    "mittag", "anfang", "ende", "mitte", "uhr", "leben", "welt", "land", "stadt", "haus", "wohnung",
    "zimmer", "tür", "fenster", "straße", "platz", "ort", "stelle", "familie", "eltern", "mutter",
    "vater", "sohn", "tochter", "bruder", "schwester", "freund", "freundin", "leute", "person",
    "name", "wort", "wörter", "satz", "buch", "sprache", "brief", "nachricht", "nummer", "schule",
    "lehrer", "klasse", "unterricht", "beruf", "büro", "firma", "geld", "preis", "euro", "termin",
    "pause", "urlaub", "wasser", "kaffee", "tee", "brot", "milch", "essen", "auto", "bus", "bahn",
    "zug", "fahrrad", "problem", "lösung", "idee", "beispiel", "ziel", "plan", "thema", "punkt",
    "sache", "ding", "art", "weise", "form", "meinung", "gefühl", "interesse", "antwort",
    "information", "entscheidung", "ergebnis", "fehler", "gruppe", "zahl", "geschichte", "spiel",
    "farbe", "tisch", "stuhl", "bett", "licht", "wetter", "sonne", "regen", "kopf", "auge", "ohr",
    "nase", "mund", "arm", "bein", "fuß", "haar", "montag", "dienstag", "mittwoch", "donnerstag",
    "freitag", "samstag", "sonntag", "januar", "februar", "märz", "april", "mai", "juni", "juli",
    "august", "september", "oktober", "november", "dezember", "frühling", "sommer", "herbst",
    "winter", "staat", "recht", "gesetz", "regel", "ordnung", "chance", "hilfe", "herr", "gespräch",
    "bild", "computer", "handy", "internet", "prozent", "hälfte", "rest", "liste", "reihe", "menge",
    "garten",
    // Common adjectives
    "gut", "gute", "guter", "gutes", "guten", "besser", "bessere", "besten", "beste", "neu", "neue",
    "neuer", "neuen", "neues", "groß", "große", "großer", "großen", "größer", "größte", "klein",
    "kleine", "kleiner", "kleinen", "kleines", "lang", "lange", "langer", "langen", "länger", "alt",
    "alte", "alter", "alten", "älter", "weit", "weite", "weitere", "weiteren", "kurz", "kurze",
    "kurzen", "kürzer", "hoch", "hohe", "hohen", "höher", "schnell", "schneller", "langsam", "früh",
    "spät", "jung", "junge", "jungen", "schön", "schöne", "schönen", "schlecht", "schlechte",
    "schlechter", "richtig", "richtige", "richtigen", "falsch", "möglich", "mögliche", "möglichen",
    "wichtig", "wichtige", "wichtigen", "nötig", "notwendig", "einfache", "einfachen", "schwierig",
    "schwer", "leicht", "gleich", "gleiche", "gleichen", "anders", "ähnlich", "letzte", "letzten",
    "erste", "ersten", "nächste", "nächsten", "voll", "leer", "offen", "frei", "warm", "kalt",
    "heiß", "hell", "dunkel", "laut", "leise", "stark", "starke", "schwach", "nett", "freundlich",
    "ruhig", "glücklich", "traurig", "müde", "fertig", "eigen", "eigene", "eigenen", "ganze",
    "ganzen", "halb", "deutsch", "deutsche", "deutschen", "teuer", "billig", "günstig", "wahr",
    "nah", "nahe", "viel", "wenig", "mehr",
    // Number words
    "null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
    "elf", "zwölf", "dreizehn", "vierzehn", "fünfzehn", "sechzehn", "siebzehn", "achtzehn",
    "neunzehn", "zwanzig", "dreißig", "vierzig", "fünfzig", "sechzig", "siebzig", "achtzig",
    "neunzig", "hundert", "tausend", "zweite", "dritte", "vierte", "fünfte",
    // Common verbs
    "arbeiten", "arbeite", "arbeitest", "arbeitet", "arbeitete", "gearbeitet", "machen", "mache",
    "machst", "macht", "machte", "gemacht", "gehen", "gehe", "gehst", "geht", "ging", "gegangen",
    "kommen", "komme", "kommst", "kommt", "kam", "gekommen", "sagen", "sage", "sagst", "sagt",
    "sagte", "gesagt", "sehen", "sehe", "siehst", "sieht", "sah", "gesehen", "geben", "gebe",
    "gibst", "gibt", "gab", "gegeben", "nehmen", "nehme", "nimmst", "nimmt", "nahm", "genommen",
    "bleiben", "bleibe", "bleibst", "bleibt", "blieb", "geblieben", "stehen", "stehe", "stehst",
    "steht", "stand", "gestanden", "liegen", "liege", "liegst", "liegt", "lag", "gelegen", "finden",
    "finde", "findest", "findet", "fand", "gefunden", "zeigen", "zeige", "zeigst", "zeigt",
    "zeigte", "gezeigt", "lassen", "lasse", "lässt", "ließ", "gelassen", "wissen", "weiß", "weißt",
    "wusste", "gewusst", "tun", "tue", "tust", "tut", "tat", "getan", "bringen", "bringe", "bringt",
    "brachte", "gebracht", "denken", "denke", "denkt", "dachte", "gedacht", "glauben", "glaube",
    "glaubt", "glaubte", "geglaubt", "kennen", "kenne", "kennt", "kannte", "gekannt", "meint",
    "meinte", "gemeint", "fragt", "fragte", "gefragt", "heißen", "heißt", "hieß", "sprechen",
    "spricht", "sprach", "gesprochen", "schreiben", "schreibt", "schrieb", "geschrieben", "lesen",
    "liest", "las", "gelesen", "hören", "hört", "hörte", "gehört",
  ]

  /// Folded once from `all` and from `SpokenPunctuation.functionWords`.
  private static let folded: Set<String> = Set(all.map(GlossaryDocument.fold))
    .union(SpokenPunctuation.functionWords.map(GlossaryDocument.fold))

  static func contains(_ word: String) -> Bool {
    folded.contains(GlossaryDocument.fold(word))
  }
}
