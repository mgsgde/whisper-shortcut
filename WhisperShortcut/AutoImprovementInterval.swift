import Foundation

/// Configurable interval for automatic system prompt improvement.
enum AutoImprovementInterval: Int, CaseIterable, Codable {
  case never = 0
  case days7 = 7
  case days14 = 14
  case days30 = 30

  var displayName: String {
    switch self {
    case .never:
      return "Nie"
    case .days7:
      return "Alle 7 Tage"
    case .days14:
      return "Alle 14 Tage"
    case .days30:
      return "Alle 30 Tage"
    }
  }

  var days: Int {
    rawValue
  }

  static var `default`: AutoImprovementInterval {
    .days7
  }
}
