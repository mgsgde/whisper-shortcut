import Foundation

/// Configurable interval for automatic system prompt improvement.
enum AutoImprovementInterval: Int, CaseIterable, Codable {
  case never = 0
  case always = 1
  case days3 = 3
  case days7 = 7
  case days14 = 14
  case days30 = 30

  var displayName: String {
    switch self {
    case .never:
      return "Never"
    case .always:
      return "Always"
    case .days3:
      return "Every 3 days"
    case .days7:
      return "Every 7 days"
    case .days14:
      return "Every 14 days"
    case .days30:
      return "Every 30 days"
    }
  }

  var days: Int {
    rawValue
  }

  static var `default`: AutoImprovementInterval {
    .days7
  }
}
