import XCTest

/// Report-mode coverage check for the String Catalogs (see plans/active/german-localization.md 2.4).
/// Flip `strict` to true (slice A4) to make missing/stale/format-mismatched keys fail.
final class LocalizationCoverageTests: XCTestCase {
  static let strict = false

  private func catalogURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("WhisperShortcut/\(name)")
  }

  private func load(_ name: String) throws -> [String: [String: Any]] {
    let data = try Data(contentsOf: catalogURL(name))
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
  }

  private func specifiers(_ s: String) -> [String] {
    let pattern = "%(?:\\d+\\$)?(?:l{0,2}|h{0,2})[@dfsuxXcCgGeEiopaA]"
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(s.startIndex..., in: s)
    return re.matches(in: s, range: range).map {
      String(s[Range($0.range, in: s)!]).replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression)
    }.sorted()
  }

  private func report(_ name: String) throws {
    let strings = try load(name)
    XCTAssertGreaterThanOrEqual(strings.count, 1, "\(name) has no keys")
    var missing: [String] = []
    var mismatched: [String] = []
    var stale: [String] = []
    for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
      if (entry["extractionState"] as? String) == "stale" { stale.append(key) }
      if (entry["shouldTranslate"] as? Bool) == false { continue }
      let locs = entry["localizations"] as? [String: Any]
      let de = locs?["de"] as? [String: Any]
      let unit = de?["stringUnit"] as? [String: Any]
      if de == nil || (unit != nil && (unit?["state"] as? String) != "translated") {
        missing.append(key)
        continue
      }
      if let value = unit?["value"] as? String, specifiers(value) != specifiers(key) {
        mismatched.append(key)
      }
    }
    print("[LocalizationCoverage] \(name): keys=\(strings.count) missingDE=\(missing.count) formatMismatch=\(mismatched.count) stale=\(stale.count)")
    for (label, list) in [("missingDE", missing), ("formatMismatch", mismatched), ("stale", stale)] {
      for k in list.prefix(50) { print("[LocalizationCoverage]   \(label): \(k)") }
    }
    if Self.strict {
      XCTAssertTrue(missing.isEmpty, "Missing de: \(missing)")
      XCTAssertTrue(mismatched.isEmpty, "Format specifier mismatch: \(mismatched)")
      XCTAssertTrue(stale.isEmpty, "Stale keys: \(stale)")
    }
  }

  func testLocalizableCatalogCoverage() throws { try report("Localizable.xcstrings") }
  func testInfoPlistCatalogCoverage() throws { try report("InfoPlist.xcstrings") }
}
