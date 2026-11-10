import Foundation

extension URLComponents {
  /// Sets `queryItems`, then percent-encodes any literal `+`.
  ///
  /// `URLComponents.queryItems` leaves `+` unescaped. Servers that decode the query as
  /// application/x-www-form-urlencoded turn that into a space, which corrupts Trello due
  /// offsets (`+01:00`), names like "C++", and Gmail `q` values.
  mutating func setQueryItemsStrictly(_ items: [URLQueryItem]) {
    queryItems = items
    percentEncodedQuery = percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
  }
}

extension String {
  /// Percent-encodes a value used as one URL path segment. A raw `/` or `?` would change which resource the request hits.
  var encodedPathSegment: String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
    return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
  }
}
