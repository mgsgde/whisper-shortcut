import SwiftUI

/// Capsule showing a permission's status. Settings → Privacy & Permissions and the onboarding
/// Done step each had a verbatim copy, so a new status or a reworded label had two homes.
struct PermissionStatusBadge: View {
  let status: PermissionStatus

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "circle.fill")
        .font(.system(size: 8))
        .foregroundStyle(color)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(color.opacity(0.12)))
  }

  private var color: Color {
    switch status {
    case .granted: return .green
    case .denied: return .red
    case .notDetermined: return .yellow
    case .notApplicable: return .gray
    }
  }

  private var label: String {
    switch status {
    case .granted: return "Granted"
    case .denied: return "Denied"
    case .notDetermined: return "Not requested"
    case .notApplicable: return "Not applicable"
    }
  }
}

extension PermissionKind {
  /// The name macOS uses for the permission in System Settings → Privacy & Security.
  var displayName: String {
    switch self {
    case .microphone: return "Microphone"
    case .accessibility: return "Accessibility"
    case .screenRecording: return "Screen Recording"
    }
  }
}
