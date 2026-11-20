import SwiftUI

/// "Save usage data" is on for a new install that finishes the Welcome Tour with All features
/// (owner decision 2026-11-19, „Ja, so bauen“, replacing the opt-in of 2026-10-19). It is turned on
/// where the user sees it — the tour's last step, with the switch in front of them — never silently:
/// a user who closes the tour earlier, picks Dictation only, or runs Offline Mode keeps it off.
enum UsageDataTourDefault {
  /// Pure rule. `alreadyApplied` stops a second tour visit (or Back/Continue on the last step)
  /// from turning the switch back on after the user turned it off; `onboardingCompleted` keeps
  /// installs that finished the tour before this change on whatever they chose.
  static func shouldTurnOn(
    alreadyApplied: Bool, onboardingCompleted: Bool, dictationOnly: Bool, offlineMode: Bool
  ) -> Bool {
    !alreadyApplied && !onboardingCompleted && !dictationOnly && !offlineMode
  }

  /// Called when the tour's last step appears. Writes the switch and the one-shot marker together.
  static func applyIfNeeded(_ defaults: UserDefaults = .standard) {
    guard shouldTurnOn(
      alreadyApplied: defaults.bool(forKey: UserDefaultsKeys.contextLoggingTourDefaultApplied),
      onboardingCompleted: defaults.bool(forKey: UserDefaultsKeys.hasCompletedOnboarding),
      dictationOnly: defaults.bool(forKey: UserDefaultsKeys.dictationOnlyMode),
      offlineMode: defaults.bool(forKey: UserDefaultsKeys.offlineModeEnabled))
    else { return }
    defaults.set(true, forKey: UserDefaultsKeys.contextLoggingEnabled)
    defaults.set(true, forKey: UserDefaultsKeys.contextLoggingTourDefaultApplied)
  }
}

/// The "Save usage data" card on the Welcome Tour's last step. Same switch as Settings →
/// Permissions & Privacy (`UsageDataSection`); this copy says what it keeps, where, for how long,
/// what depends on it, and who should turn it off.
struct UsageDataTourToggle: View {
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var saveUsageData = false
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle("Save usage data", isOn: offlineMode ? .constant(false) : $saveUsageData)
        .toggleStyle(.switch)
        .font(.callout)
        .fontWeight(.semibold)
        .disabled(offlineMode)
      if offlineMode {
        Text("Paused while Offline Mode is on. Nothing is stored.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Keeps your dictations, prompts and chats on this Mac for 90 days. Recent Transcriptions, learned quick prompts and new glossary names need it, and the Chat can look up why a dictation went wrong. Nothing leaves this Mac unless you ask the Chat about it.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text("Dictating patient or client data? Turn it off here or later in Settings → Permissions & Privacy.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear { UsageDataTourDefault.applyIfNeeded() }
  }
}
