import Foundation

/// Word error rate on normalised text: lower-cased, punctuation stripped, whitespace collapsed.
/// Umlauts and ß are kept — "Grösse" for "Größe" is an error a German reader sees.
enum Metrics {
  static func normalize(_ text: String) -> [String] {
    let lowered = text.lowercased(with: Locale(identifier: "de_DE"))
    let cleaned = lowered.unicodeScalars.map { scalar -> Character in
      if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
        return Character(scalar)
      }
      // Everything else, hyphens included, separates words: "Ilio-Sakralgelenk" against
      // "Iliosakralgelenk" counts as errors — the stricter reading, on purpose.
      return " "
    }
    return String(cleaned).split(separator: " ").map(String.init)
  }

  /// Word-level edit distance (substitutions + insertions + deletions).
  static func editDistance(_ ref: [String], _ hyp: [String]) -> Int {
    if ref.isEmpty { return hyp.count }
    if hyp.isEmpty { return ref.count }
    var previous = Array(0...hyp.count)
    var current = [Int](repeating: 0, count: hyp.count + 1)
    for i in 1...ref.count {
      current[0] = i
      for j in 1...hyp.count {
        let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }
    return previous[hyp.count]
  }

  static func folded(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
  }

  /// Terms that occur in the reference, and how many of those the hypothesis also contains.
  /// Only terms the speaker actually said count — a glossary term absent from the reference says
  /// nothing about recall.
  static func termRecall(terms: [String], reference: String, hypothesis: String) -> (present: Int, hit: Int) {
    let ref = folded(reference)
    let hyp = folded(hypothesis)
    var present = 0
    var hit = 0
    for term in terms {
      let needle = folded(term)
      guard needle.count >= 3, ref.contains(needle) else { continue }
      present += 1
      if hyp.contains(needle) { hit += 1 }
    }
    return (present, hit)
  }

  static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
  }

  static func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
    return sorted[index]
  }
}
