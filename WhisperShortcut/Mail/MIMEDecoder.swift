import Foundation

struct DecodedMail: Sendable, Equatable {
  var from: String
  var to: String
  var cc: String
  var subject: String
  var date: String
  var body: String
  var attachments: [(name: String, bytes: Int)]

  static func == (lhs: DecodedMail, rhs: DecodedMail) -> Bool {
    lhs.from == rhs.from && lhs.to == rhs.to && lhs.cc == rhs.cc && lhs.subject == rhs.subject
      && lhs.date == rhs.date && lhs.body == rhs.body
      && lhs.attachments.map(\.name) == rhs.attachments.map(\.name)
      && lhs.attachments.map(\.bytes) == rhs.attachments.map(\.bytes)
  }
}

enum MIMEDecoder {
  static let bodyCharacterCap = 20_000

  static func decode(_ data: Data) -> DecodedMail {
    let (headerData, bodyData) = splitHeaderBody(data)
    let headers = parseHeaders(headerData)
    let collected = collect(headers: headers, body: bodyData)
    let chosen: String
    if let plain = collected.plain, !plain.isEmpty {
      chosen = plain
    } else if let html = collected.html {
      chosen = stripHTML(html)
    } else {
      chosen = collected.plain ?? ""
    }
    return DecodedMail(
      from: decodeEncodedWords(headers.joined("from")),
      to: decodeEncodedWords(headers.joined("to")),
      cc: decodeEncodedWords(headers.joined("cc")),
      subject: decodeEncodedWords(headers.joined("subject")),
      date: decodeEncodedWords(headers.joined("date")),
      body: cap(chosen),
      attachments: collected.attachments)
  }

  // MARK: - Walk

  private struct Collected {
    var plain: String?
    var html: String?
    var attachments: [(name: String, bytes: Int)] = []
  }

  private static func collect(headers: HeaderMap, body: Data) -> Collected {
    let type = headers.mimeType
    if type.hasPrefix("multipart/") {
      guard let boundary = headers.parameter("content-type", "boundary"), !boundary.isEmpty else {
        return Collected()
      }
      var merged = Collected()
      for part in splitMultipart(body, boundary: boundary) {
        let (partHeaders, partBody) = splitHeaderBody(part)
        let child = collect(headers: parseHeaders(partHeaders), body: partBody)
        if merged.plain == nil { merged.plain = child.plain }
        if merged.html == nil { merged.html = child.html }
        merged.attachments += child.attachments
      }
      return merged
    }

    let decoded = decodeTransfer(body, encoding: headers.transferEncoding)
    let name = attachmentName(headers)
    let disposition = headers.parameter("content-disposition", nil)?.lowercased()
      ?? headers.value("content-disposition").split(separator: ";").first
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      ?? ""
    if disposition == "attachment" || (name != nil && !type.hasPrefix("text/plain") && !type.hasPrefix("text/html")) {
      return Collected(attachments: [(name ?? "attachment", decoded.count)])
    }
    let charset = headers.parameter("content-type", "charset") ?? "utf-8"
    let text = decodeCharset(decoded, charset: charset)
    if type.hasPrefix("text/html") {
      return Collected(html: text)
    }
    if type.hasPrefix("text/plain") || type.isEmpty {
      return Collected(plain: text)
    }
    if let name {
      return Collected(attachments: [(name, decoded.count)])
    }
    return Collected()
  }

  private static func cap(_ body: String) -> String {
    guard body.count > bodyCharacterCap else { return body }
    return String(body.prefix(bodyCharacterCap)) + "…[truncated]"
  }

  // MARK: - Headers

  private struct HeaderMap {
    var fields: [String: [String]] = [:]
    var raw: [String: String] = [:]

    func joined(_ name: String) -> String {
      (fields[name] ?? []).joined(separator: ", ")
    }

    func value(_ name: String) -> String {
      raw[name] ?? ""
    }

    var mimeType: String {
      let rawType = value("content-type")
      let token = rawType.split(separator: ";").first
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
      return token.isEmpty ? "text/plain" : token
    }

    var transferEncoding: String {
      value("content-transfer-encoding").split(separator: ";").first
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    func parameter(_ header: String, _ name: String?) -> String? {
      let pieces = splitSemicolons(value(header))
      if name == nil { return pieces.first?.trimmingCharacters(in: .whitespaces) }
      guard let name else { return nil }
      for piece in pieces.dropFirst() {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        guard key == name.lowercased() else { continue }
        return unquote(String(trimmed[trimmed.index(after: eq)...]))
      }
      return nil
    }
  }

  private static func parseHeaders(_ data: Data) -> HeaderMap {
    let text = unfold(String(data: data, encoding: .isoLatin1) ?? "")
    var map = HeaderMap()
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let row = String(line)
      guard let colon = row.firstIndex(of: ":") else { continue }
      let name = row[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = row[row.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { continue }
      map.fields[name, default: []].append(String(value))
      if map.raw[name] == nil { map.raw[name] = String(value) }
    }
    return map
  }

  private static func unfold(_ text: String) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var lines: [String] = []
    for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
      if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
        lines[lines.count - 1] += " " + line.drop(while: { $0 == " " || $0 == "\t" })
      } else {
        lines.append(String(line))
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func splitHeaderBody(_ data: Data) -> (Data, Data) {
    let crlf = Data([13, 10, 13, 10])
    if let range = data.range(of: crlf) {
      return (Data(data[..<range.lowerBound]), Data(data[range.upperBound...]))
    }
    let lf = Data([10, 10])
    if let range = data.range(of: lf) {
      return (Data(data[..<range.lowerBound]), Data(data[range.upperBound...]))
    }
    return (data, Data())
  }

  private static func splitSemicolons(_ value: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inQuotes = false
    for character in value {
      if character == "\"" {
        inQuotes.toggle()
        current.append(character)
        continue
      }
      if character == ";", !inQuotes {
        parts.append(current)
        current = ""
        continue
      }
      current.append(character)
    }
    if !current.isEmpty { parts.append(current) }
    return parts
  }

  private static func unquote(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
    return String(trimmed.dropFirst().dropLast())
  }

  private static func attachmentName(_ headers: HeaderMap) -> String? {
    if let star = headers.parameter("content-disposition", "filename*")
      ?? headers.parameter("content-type", "name*") {
      let decoded = decodeRFC2231(star)
      if !decoded.isEmpty { return decoded }
    }
    if let plain = headers.parameter("content-disposition", "filename")
      ?? headers.parameter("content-type", "name") {
      let decoded = decodeEncodedWords(plain)
      if !decoded.isEmpty { return decoded }
    }
    return nil
  }

  // MARK: - Multipart

  private static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
    let bytes = [UInt8](body)
    let delim = [UInt8]("--\(boundary)".utf8)
    guard !delim.isEmpty, let first = findDelim(bytes, delim, from: 0) else { return [] }
    var cursor = skipBoundaryEnding(bytes, from: first + delim.count)
    var parts: [Data] = []
    while cursor < bytes.count {
      if isCloser(bytes, at: cursor) { break }
      guard let next = findDelim(bytes, delim, from: cursor) else { break }
      var end = next
      if end >= 2, bytes[end - 2] == 13, bytes[end - 1] == 10 { end -= 2 }
      else if end >= 1, bytes[end - 1] == 10 { end -= 1 }
      if end >= cursor { parts.append(Data(bytes[cursor..<end])) }
      let after = next + delim.count
      if isCloser(bytes, at: after) { break }
      cursor = skipBoundaryEnding(bytes, from: after)
    }
    return parts
  }

  private static func findDelim(_ bytes: [UInt8], _ delim: [UInt8], from start: Int) -> Int? {
    guard !delim.isEmpty else { return nil }
    var index = max(0, start)
    while index + delim.count <= bytes.count {
      let atLine = index == 0 || bytes[index - 1] == 10
      if atLine, bytes[index..<(index + delim.count)].elementsEqual(delim),
         boundaryTailOK(bytes, after: index + delim.count) {
        return index
      }
      index += 1
    }
    return nil
  }

  private static func boundaryTailOK(_ bytes: [UInt8], after index: Int) -> Bool {
    guard index < bytes.count else { return true }
    switch bytes[index] {
    case UInt8(ascii: "-"), 13, 10, 32, 9: return true
    default: return false
    }
  }

  private static func isCloser(_ bytes: [UInt8], at index: Int) -> Bool {
    index + 1 < bytes.count && bytes[index] == UInt8(ascii: "-") && bytes[index + 1] == UInt8(ascii: "-")
  }

  private static func skipBoundaryEnding(_ bytes: [UInt8], from start: Int) -> Int {
    var index = start
    while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 { index += 1 }
    if index + 1 < bytes.count, bytes[index] == 13, bytes[index + 1] == 10 { return index + 2 }
    if index < bytes.count, bytes[index] == 10 { return index + 1 }
    return index
  }

  // MARK: - Transfer and charset

  private static func decodeTransfer(_ body: Data, encoding: String) -> Data {
    switch encoding.lowercased() {
    case "base64":
      let cleaned = body.filter { byte in
        byte != 0x20 && byte != 0x09 && byte != 0x0D && byte != 0x0A
      }
      return Data(base64Encoded: cleaned) ?? Data()
    case "quoted-printable":
      return decodeQuotedPrintable(body)
    default:
      return body
    }
  }

  private static func decodeQuotedPrintable(_ body: Data) -> Data {
    let bytes = [UInt8](body)
    var out = Data()
    var index = 0
    while index < bytes.count {
      if bytes[index] == 0x3D {
        if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
          index += 2
          continue
        }
        if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
          index += 3
          continue
        }
        if index + 2 < bytes.count, let hi = hex(bytes[index + 1]), let lo = hex(bytes[index + 2]) {
          out.append((hi << 4) | lo)
          index += 3
          continue
        }
      }
      out.append(bytes[index])
      index += 1
    }
    return out
  }

  private static func decodeCharset(_ data: Data, charset: String) -> String {
    let encoding = stringEncoding(charset) ?? .utf8
    if let text = String(data: data, encoding: encoding) { return text }
    return String(decoding: data, as: UTF8.self)
  }

  private static func stringEncoding(_ charset: String) -> String.Encoding? {
    let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
    if cf != kCFStringEncodingInvalidId {
      let ns = CFStringConvertEncodingToNSStringEncoding(cf)
      return String.Encoding(rawValue: ns)
    }
    switch charset.lowercased() {
    case "utf-8", "utf8": return .utf8
    case "us-ascii", "ascii": return .ascii
    case "iso-8859-1", "latin1": return .isoLatin1
    default: return nil
    }
  }

  // MARK: - RFC 2047 / 2231

  private static func decodeEncodedWords(_ value: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#) else {
      return value
    }
    let ns = value as NSString
    let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
    if matches.isEmpty { return value }
    var out = ""
    var cursor = 0
    var lastWasWord = false
    for match in matches {
      let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      let gapIsSpace = gap.unicodeScalars.allSatisfy {
        $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
      }
      if !(lastWasWord && gapIsSpace) { out += gap }
      let charset = ns.substring(with: match.range(at: 1))
      let encoding = ns.substring(with: match.range(at: 2))
      let text = ns.substring(with: match.range(at: 3))
      out += decodeOneWord(charset: charset, encoding: encoding, text: text)
      cursor = match.range.location + match.range.length
      lastWasWord = true
    }
    out += ns.substring(from: cursor)
    return out
  }

  private static func decodeOneWord(charset: String, encoding: String, text: String) -> String {
    let data: Data
    if encoding.uppercased() == "B" {
      let filtered = text.unicodeScalars.filter { !$0.properties.isWhitespace }.map { Character($0) }
      data = Data(base64Encoded: String(filtered)) ?? Data()
    } else {
      data = decodeQ(text)
    }
    if data.isEmpty, !text.isEmpty { return "=? \(text) ?=" }
    return decodeCharset(data, charset: charset)
  }

  private static func decodeQ(_ text: String) -> Data {
    let bytes = Array(text.utf8)
    var out = Data()
    var index = 0
    while index < bytes.count {
      if bytes[index] == UInt8(ascii: "_") {
        out.append(0x20)
        index += 1
      } else if bytes[index] == UInt8(ascii: "="), index + 2 < bytes.count,
                let hi = hex(bytes[index + 1]), let lo = hex(bytes[index + 2]) {
        out.append((hi << 4) | lo)
        index += 3
      } else {
        out.append(bytes[index])
        index += 1
      }
    }
    return out
  }

  private static func decodeRFC2231(_ raw: String) -> String {
    let parts = raw.split(separator: "'", omittingEmptySubsequences: false)
    let charset: String
    let encoded: String
    if parts.count >= 3 {
      charset = String(parts[0])
      encoded = parts.dropFirst(2).joined(separator: "'")
    } else {
      charset = "utf-8"
      encoded = raw
    }
    return decodeCharset(percentDecode(encoded), charset: charset.isEmpty ? "utf-8" : charset)
  }

  private static func percentDecode(_ string: String) -> Data {
    let bytes = Array(string.utf8)
    var out = Data()
    var index = 0
    while index < bytes.count {
      if bytes[index] == 0x25, index + 2 < bytes.count,
         let hi = hex(bytes[index + 1]), let lo = hex(bytes[index + 2]) {
        out.append((hi << 4) | lo)
        index += 3
      } else {
        out.append(bytes[index])
        index += 1
      }
    }
    return out
  }

  private static func hex(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
  }

  // MARK: - HTML

  private static func stripHTML(_ html: String) -> String {
    var text = replacing(html, pattern: #"(?is)<script\b[^>]*>.*?</script>|<script\b[^>]*>.*"#, with: "")
    text = replacing(text, pattern: #"(?is)<style\b[^>]*>.*?</style>|<style\b[^>]*>.*"#, with: "")
    text = replacing(text, pattern: #"(?i)<\s*br\s*/?\s*>|<\s*/?\s*p\b[^>]*>"#, with: "\n")
    text = replacing(text, pattern: #"<[^>]+>"#, with: "")
    text = decodeEntities(text)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replacing(_ text: String, pattern: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
      return text
    }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
  }

  private static func decodeEntities(_ text: String) -> String {
    var result = text
    result = replacingNumeric(result, pattern: #"&#x([0-9A-Fa-f]+);"#, radix: 16)
    result = replacingNumeric(result, pattern: #"&#(\d+);"#, radix: 10)
    let named: [(String, String)] = [
      ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
    ]
    for (entity, value) in named {
      result = result.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
    }
    result = result.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    return result
  }

  private static func replacingNumeric(_ text: String, pattern: String, radix: Int) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var out = text
    for match in matches.reversed() {
      guard let range = Range(match.range(at: 1), in: out),
            let scalarValue = UInt32(out[range], radix: radix),
            let scalar = UnicodeScalar(scalarValue),
            let whole = Range(match.range, in: out) else { continue }
      out.replaceSubrange(whole, with: String(Character(scalar)))
    }
    return out
  }
}
