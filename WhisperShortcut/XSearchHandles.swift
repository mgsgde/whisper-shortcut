import Foundation

/// The set of X accounts Grok's `x_search` tool is restricted to.
///
/// xAI's `allowed_x_handles` is a **hard filter, not a ranking hint**: once it is set, Grok sees
/// posts from those accounts and nothing else. That is why the list is opt-in per chat (`/x`)
/// layered over a default in Settings → Chat, instead of a global always-on filter — a permanently
/// restricted `x_search` would silently answer "nobody on X said that" for every topic the listed
/// accounts happen not to cover.
enum XSearchHandles {
  /// xAI's documented ceiling for `allowed_x_handles`. Over-long lists fail the whole request, so
  /// the parser caps instead and reports what it dropped.
  static let maxHandles = 20

  /// Longest legal X handle (X itself allows 1–15 word characters).
  private static let maxHandleLength = 15

  /// The list new chats inherit, configured in Settings → Chat. Empty = search all of X.
  static var defaultHandles: [String] {
    get { normalize(UserDefaults.standard.string(forKey: UserDefaultsKeys.grokXSearchHandles) ?? "") }
    set {
      UserDefaults.standard.set(newValue.joined(separator: " "), forKey: UserDefaultsKeys.grokXSearchHandles)
    }
  }

  /// Parses free-form input — `@Karpathy, simonw`, `https://x.com/levelsio`, one per line — into
  /// wire-ready handles, and reports how many were dropped for exceeding `maxHandles`.
  ///
  /// Accepts anything a user might paste: splits on whitespace, commas and semicolons, unwraps
  /// x.com/twitter.com URLs, strips a leading `@`, lowercases (X handles are case-insensitive, and
  /// folding case is what makes de-duplication work), and drops tokens that can't be handles.
  static func parse(_ raw: String) -> (handles: [String], droppedOverCap: Int) {
    let tokens = raw.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
    var seen: Set<String> = []
    var handles: [String] = []
    for token in tokens {
      guard let handle = canonicalize(String(token)), seen.insert(handle).inserted else { continue }
      handles.append(handle)
    }
    let dropped = max(0, handles.count - maxHandles)
    return (Array(handles.prefix(maxHandles)), dropped)
  }

  /// `parse` without the drop count, for callers that only need the wire value.
  static func normalize(_ raw: String) -> [String] { parse(raw).handles }

  /// A single token → bare lowercase handle, or nil if it can't be one.
  private static func canonicalize(_ token: String) -> String? {
    // URL forms: keep the last path component. Trailing slashes go first — `x.com/levelsio/`
    // would otherwise split into an empty tail and drop the handle entirely.
    var candidate = token
    while candidate.hasSuffix("/") { candidate.removeLast() }
    if let slash = candidate.lastIndex(of: "/") {
      candidate = String(candidate[candidate.index(after: slash)...])
    }
    candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "@ \t\"'.<>()[]"))
    guard !candidate.isEmpty, candidate.count <= maxHandleLength,
          candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    else { return nil }
    return candidate.lowercased()
  }

  /// Display form for confirmations and Settings help text: `@a, @b`.
  static func describe(_ handles: [String]) -> String {
    handles.map { "@\($0)" }.joined(separator: ", ")
  }
}
