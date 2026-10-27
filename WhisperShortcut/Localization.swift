import Foundation

extension LocalizedStringResource {
  /// Wraps text that is already final (user content, a model or provider name, a message that was
  /// localized where it was produced) so it can travel through a `LocalizedStringResource` API.
  /// It is looked up as a catalog key, finds nothing, and comes back unchanged.
  static func verbatim(_ text: String) -> LocalizedStringResource {
    LocalizedStringResource(stringLiteral: text)
  }
}

extension LocalizedStringResource {
  /// The English text of this resource, whatever the app language is. For text a model reads
  /// (system prompt command lists): model-facing text stays English (spec 2.2).
  var english: String {
    var resource = self
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
  }
}
