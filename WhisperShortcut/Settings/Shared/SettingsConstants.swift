import CoreGraphics
import Foundation
import SwiftUI

/// Shared constants for all Settings views.
enum SettingsConstants {
  // MARK: - Layout
  static let labelWidth: CGFloat = 160
  static let apiKeyMaxWidth: CGFloat = 350
  static let shortcutMaxWidth: CGFloat = 300
  static let modelSelectionHeight: CGFloat = 48
  static let textFieldHeight: CGFloat = 40

  // MARK: - Spacing
  static let spacing: CGFloat = 20
  static let sectionSpacing: CGFloat = 24
  static let internalSectionSpacing: CGFloat = 20
  static let modelSpacing: CGFloat = 0

  /// Padding around the scrolling tab content in `SettingsView`.
  static let horizontalPadding: CGFloat = 24
  static let topPadding: CGFloat = 20
  /// Larger than `topPadding` so the last section clears the window edge when scrolled to the bottom.
  static let bottomPadding: CGFloat = 40

  // MARK: - Visual
  static let cornerRadius: CGFloat = 8
  /// Radius of the standalone cards (`cardChrome()`): onboarding steps and the offline-model card.
  static let cardCornerRadius: CGFloat = 10
  /// Inset for boxed cards (General/Privacy tabs).
  static let cardPadding: CGFloat = 16
  /// Inset for compact list rows inside a card (e.g. the offline model rows).
  static let rowPadding: CGFloat = 12
  static let textEditorHeight: CGFloat = 240
  static let sectionDividerHeight: CGFloat = 1  // Height for section divider lines

  // Badge color for a model's cost-level string. Shared by every model picker so the
  // Minimal/Low/Medium/High palette stays consistent in one place.
  static func costLevelColor(for costLevel: CostLevel) -> Color { costLevel.color }
}

/// How expensive a model is to run, shown as the "Cost:" badge in every model picker.
/// An enum (not a string) so the colour never depends on the displayed, localized text.
enum CostLevel {
  case minimal, low, medium, high, free, freeOffline, custom, varies

  var title: LocalizedStringResource {
    switch self {
    case .minimal: return "Minimal"
    case .low: return "Low"
    case .medium: return "Medium"
    case .high: return "High"
    case .free: return "Free"
    case .freeOffline: return "Free (Offline)"
    case .custom: return "Custom"
    case .varies: return "Varies"
    }
  }

  var color: Color {
    switch self {
    case .minimal, .low: return .green
    case .medium: return .orange
    case .high: return .red
    case .free, .freeOffline, .custom, .varies: return .secondary
    }
  }
}
