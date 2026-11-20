import SwiftUI

/// The way back into the Welcome Tour from Settings. The menu bar menu has the same entry
/// ("Welcome Tour…"), but people looking for setup help open Settings first and found nothing.
struct WelcomeTourSection: View {
  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Welcome Tour",
        systemImage: "sparkles",
        subtitle: "Walk through setup again: how dictation runs, permissions, and a first try. Your settings stay as they are."
      )

      Button("Open Welcome Tour…") {
        WelcomeWindowController.shared.show()
      }
      .accessibilityLabel("Open Welcome Tour")
    }
  }
}
