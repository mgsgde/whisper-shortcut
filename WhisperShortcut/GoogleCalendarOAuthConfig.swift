import Foundation

enum GoogleCalendarOAuthConfig {
  static var clientID: String {
    (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String) ?? ""
  }

  static var redirectURI: String {
    guard let schemes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
          let first = schemes.first,
          let urlSchemes = first["CFBundleURLSchemes"] as? [String],
          let scheme = urlSchemes.first
    else { return "" }
    return "\(scheme):/oauthredirect"
  }

  static var redirectScheme: String {
    guard let schemes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
          let first = schemes.first,
          let urlSchemes = first["CFBundleURLSchemes"] as? [String],
          let scheme = urlSchemes.first
    else { return "" }
    return scheme
  }

  static let scope = "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/tasks https://www.googleapis.com/auth/gmail.readonly"
  static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
  static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
}
