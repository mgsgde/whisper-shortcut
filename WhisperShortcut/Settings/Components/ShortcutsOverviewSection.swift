import SwiftUI

/// Read-only overview of every global keyboard shortcut, so users can see them all in one
/// place. The shortcuts are edited per feature in their own tabs; this is just a reference.
struct ShortcutsOverviewSection: View {
  @ObservedObject var viewModel: SettingsViewModel

  private var rows: [(String, ShortcutDefinition?)] {
    var items: [(String, ShortcutDefinition?)] = [
      ("Dictate", viewModel.data.toggleDictation),
      ("Dictate Prompt", viewModel.data.togglePrompting),
    ]
    // Selection-based Read Aloud uses ⌘C (Accessibility) — omitted from the App Store build.
    #if !APP_STORE
    items.append(("Read Aloud", viewModel.data.readAloud))
    #endif
    items.append(contentsOf: [
      ("Screenshot", viewModel.data.screenshotCapture),
      ("Chat", viewModel.data.openChat),
      ("Settings", viewModel.data.openSettings),
    ])
    return items
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Keyboard Shortcuts",
        systemImage: "keyboard",
        subtitle: "All global shortcuts at a glance. Change them in each feature's tab."
      )

      VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          if index > 0 { Divider() }
          HStack {
            Text(row.0)
              .font(.callout)
            Spacer()
            if let shortcut = row.1 {
              Text(shortcut.displayString)
                .font(.system(.callout, design: .rounded))
                .fontWeight(.medium)
                .foregroundColor(.primary)
            } else {
              Text("Not set")
                .font(.callout)
                .foregroundColor(.secondary)
            }
          }
          .padding(.vertical, 8)
          .padding(.horizontal, 12)
        }
      }
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(.separatorColor), lineWidth: 1)
      )
    }
  }
}
