import CoreGraphics
import Foundation

/// Gemeinsame Konstanten für alle Settings-Views
enum SettingsConstants {
  // MARK: - Layout
  static let labelWidth: CGFloat = 160
  static let apiKeyMaxWidth: CGFloat = 350
  static let shortcutMaxWidth: CGFloat = 300
  static let minWindowWidth: CGFloat = 600
  static let minWindowHeight: CGFloat = 550
  static let modelSelectionHeight: CGFloat = 48
  static let textFieldHeight: CGFloat = 40

  // MARK: - Spacing
  static let topPadding: CGFloat = 30
  static let spacing: CGFloat = 24
  static let sectionSpacing: CGFloat = 28  // Increased from 16 to 28 for better visual separation
  static let internalSectionSpacing: CGFloat = 24  // Spacing within sections
  static let modelSpacing: CGFloat = 0
  static let dividerHeight: CGFloat = 20
  static let buttonSpacing: CGFloat = 20
  static let bottomPadding: CGFloat = 30
  static let horizontalPadding: CGFloat = 40
  static let verticalPadding: CGFloat = 24

  // MARK: - Visual
  static let cornerRadius: CGFloat = 8
  static let textEditorHeight: CGFloat = 120
  static let sectionDividerHeight: CGFloat = 1  // Height for section divider lines
}
