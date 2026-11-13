import Foundation

/// German cardinal number words (0–999) written as digits where the text marks them as a quantity.
///
/// Parakeet writes the same spoken number sometimes as digits, sometimes as a word ("Blutdruck 140
/// zu neunzig", "Einzel GdB Psyche zwanzig"). A report wants digits for measured values, but prose
/// keeps small numbers as words ("seit drei Tagen", "um zehn Uhr", "drei Punkte erreicht"). The rule
/// follows the usual German writing convention (DIN 5008): numbers with a unit of measure and
/// assessment values are digits, other numbers up to twelve stay words.
///
/// A number word becomes digits only when one of these holds:
/// - a unit of measure follows ("fünfhundert Meter", "zehn mg", "neunzig Prozent", "zwanzig %");
/// - a time unit follows and the number is above twelve ("dreizehn Uhr", "zwanzig Jahre"), so
///   "um zehn Uhr" and "seit drei Tagen" stay words;
/// - it is a GdB value: right after "GdB", after "GdB von", or after "GdB" and one capitalised
///   word ("Einzel GdB Psyche zwanzig");
/// - it stands on one side of "zu" and the other side is digits, or both sides are number words
///   and one of them is above nine ("140 zu neunzig", "hundertvierzig zu neunzig"; "eins zu eins"
///   stays);
/// - digits stand right next to it, separated only by spaces or "/" ("140 neunzig", "4/fünf").
///
/// "ein" / "eine" are articles and are never read as a number; "eins" only in one of the contexts
/// above. Pure and rule-based: no model, no setting.
enum GermanNumberWords {

  /// `text` with quantity number words as digits. Text without such a word comes back unchanged.
  static func digitizingQuantities(in text: String) -> String {
    var tokens = tokenize(text)
    guard tokens.contains(where: { $0.kind == .word && value(of: $0.text) != nil }) else {
      return text
    }
    var changed = false
    // A conversion can give a neighbour its digit context ("hundertvierzig zu neunzig"), so a
    // second pass picks that up. Every pass only turns words into digits, so it ends.
    for _ in 0..<3 {
      var passChanged = false
      for index in tokens.indices where tokens[index].kind == .word {
        guard let number = value(of: tokens[index].text),
          shouldConvert(at: index, value: number, in: tokens)
        else { continue }
        tokens[index] = Token(text: String(number), kind: .digits)
        passChanged = true
      }
      guard passChanged else { break }
      changed = true
    }
    return changed ? tokens.map(\.text).joined() : text
  }

  /// The value of one German cardinal word from 0 to 999, or nil. Case-insensitive, "ß" or "ss",
  /// "ü" or "ue". "ein" alone is nil (an article); inside a compound it counts ("einundzwanzig").
  static func value(of word: String) -> Int? {
    let folded = word.lowercased()
      .replacingOccurrences(of: "ue", with: "ü")
      .replacingOccurrences(of: "ß", with: "ss")
    if folded == "null" { return 0 }
    return belowThousand(folded)
  }

  // MARK: - Context

  /// Measured quantities: always digits.
  private static let measureUnits: Set<String> = [
    "meter", "metern", "m", "km", "kilometer", "kilometern", "cm", "zentimeter", "mm", "millimeter",
    "mg", "milligramm", "µg", "mikrogramm", "gramm", "kg", "kilo", "kilogramm", "ml", "milliliter",
    "liter", "prozent", "grad", "mmhg", "mmol", "ie", "euro", "schläge",
  ]

  /// Time units: digits only above twelve.
  private static let timeUnits: Set<String> = [
    "uhr", "sekunde", "sekunden", "minute", "minuten", "stunde", "stunden", "tag", "tage", "tagen",
    "woche", "wochen", "monat", "monate", "monaten", "jahr", "jahre", "jahren", "jahres",
    "lebensjahr", "lebensjahre", "lebensjahren",
  ]

  private static func shouldConvert(at index: Int, value number: Int, in tokens: [Token]) -> Bool {
    func lower(_ i: Int) -> String { tokens[i].text.lowercased() }
    let next = neighbor(of: index, step: 1, in: tokens)
    let previous = neighbor(of: index, step: -1, in: tokens)

    // "drei Pünktchen" is the spoken ellipsis; only "Only when spoken" turns it into "…" first.
    if let next, ["pünktchen", "puenktchen", "punktchen"].contains(lower(next)) { return false }

    // A unit after it.
    if let next, tokens[next].kind == .word {
      if measureUnits.contains(lower(next)) { return true }
      if timeUnits.contains(lower(next)), number > 12 { return true }
    }
    if index + 1 < tokens.count, tokens[index + 1].kind == .other {
      let symbol = tokens[index + 1].text.drop(while: { $0 == " " || $0 == "\t" }).first
      if symbol == "%" || symbol == "°" { return true }
    }

    // A GdB value.
    if let previous {
      if lower(previous) == "gdb" { return true }
      if tokens[previous].kind == .word, value(of: tokens[previous].text) == nil,
        lower(previous) == "von" || tokens[previous].text.first?.isUppercase == true,
        let beforePrevious = neighbor(of: previous, step: -1, in: tokens),
        lower(beforePrevious) == "gdb"
      {
        return true
      }
    }

    // "140 zu neunzig", "hundertvierzig zu neunzig".
    for (link, step) in [(next, 1), (previous, -1)] {
      guard let link, lower(link) == "zu",
        let other = neighbor(of: link, step: step, in: tokens)
      else { continue }
      if tokens[other].kind == .digits { return true }
      if tokens[other].kind == .word, let otherValue = value(of: tokens[other].text),
        max(number, otherValue) >= 10
      {
        return true
      }
    }

    // Digits right next to it.
    for step in [1, -1] {
      if let other = neighbor(of: index, step: step, in: tokens, slash: true),
        tokens[other].kind == .digits
      {
        return true
      }
    }
    return false
  }

  /// The word or digit token next to `index` in direction `step`, when only spaces (or, with
  /// `slash`, one "/") stand between them. A mark in between ends the context.
  private static func neighbor(of index: Int, step: Int, in tokens: [Token], slash: Bool = false)
    -> Int?
  {
    let gap = index + step
    guard tokens.indices.contains(gap) else { return nil }
    if tokens[gap].kind != .other { return gap }
    let separator = tokens[gap].text.trimmingCharacters(in: .whitespaces)
    guard separator.isEmpty || (slash && separator == "/"),
      !tokens[gap].text.contains(where: \.isNewline)
    else { return nil }
    let target = gap + step
    guard tokens.indices.contains(target), tokens[target].kind != .other else { return nil }
    return target
  }

  // MARK: - Parsing

  private static let ones: [String: Int] = [
    "eins": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8,
    "neun": 9,
  ]
  /// The first part of a compound: "ein" counts here ("einundzwanzig", "einhundert").
  private static let compoundOnes: [String: Int] = [
    "ein": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8,
    "neun": 9,
  ]
  private static let teens: [String: Int] = [
    "zehn": 10, "elf": 11, "zwölf": 12, "dreizehn": 13, "vierzehn": 14, "fünfzehn": 15,
    "sechzehn": 16, "siebzehn": 17, "achtzehn": 18, "neunzehn": 19,
  ]
  private static let tens: [String: Int] = [
    "zwanzig": 20, "dreissig": 30, "vierzig": 40, "fünfzig": 50, "sechzig": 60, "siebzig": 70,
    "achtzig": 80, "neunzig": 90,
  ]

  private static func belowThousand(_ word: String) -> Int? {
    guard let hundred = word.range(of: "hundert") else { return belowHundred(word) }
    let head = String(word[..<hundred.lowerBound])
    var tail = String(word[hundred.upperBound...])
    let hundreds: Int
    if head.isEmpty {
      hundreds = 1
    } else if let value = compoundOnes[head] {
      hundreds = value
    } else {
      return nil
    }
    if tail.hasPrefix("und") {
      tail.removeFirst(3)
      guard !tail.isEmpty else { return nil }
    }
    if tail.isEmpty { return hundreds * 100 }
    guard let rest = belowHundred(tail) else { return nil }
    return hundreds * 100 + rest
  }

  private static func belowHundred(_ word: String) -> Int? {
    if let value = ones[word] ?? teens[word] ?? tens[word] { return value }
    guard let link = word.range(of: "und"),
      let one = compoundOnes[String(word[..<link.lowerBound])],
      let ten = tens[String(word[link.upperBound...])]
    else { return nil }
    return one + ten
  }

  // MARK: - Tokens

  private enum Kind { case word, digits, other }

  private struct Token {
    let text: String
    let kind: Kind
  }

  /// Letters, digit runs (with a "," or "." between digits, "2,5"), and everything else in between.
  /// Joining the tokens gives the text back unchanged.
  private static func tokenize(_ text: String) -> [Token] {
    var tokens: [Token] = []
    let characters = Array(text)
    var index = 0
    while index < characters.count {
      let start = index
      let character = characters[index]
      let kind: Kind
      if character.isLetter {
        kind = .word
        while index < characters.count, characters[index].isLetter { index += 1 }
      } else if character.isNumber {
        kind = .digits
        while index < characters.count {
          if characters[index].isNumber {
            index += 1
          } else if characters[index] == "," || characters[index] == ".",
            index + 1 < characters.count, characters[index + 1].isNumber
          {
            index += 1
          } else {
            break
          }
        }
      } else {
        kind = .other
        while index < characters.count, !characters[index].isLetter, !characters[index].isNumber {
          index += 1
        }
      }
      tokens.append(Token(text: String(characters[start..<index]), kind: kind))
    }
    return tokens
  }
}
