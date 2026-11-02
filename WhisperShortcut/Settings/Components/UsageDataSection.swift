import SwiftUI

/// Settings → Privacy & Permissions → Usage Data: the "Save usage data" switch and the context-data
/// folder (open / delete).
///
/// Lived in the Smart Improvement tab until that feature was removed (owner decision 2026-11-02).
/// The log itself stays: the in-app Chat (`read_recent_interactions`) and AI apps over MCP
/// (`get_recent_interactions`) read it when the user asks them to tune the app, and nothing reads
/// it on its own any more.
struct UsageDataSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var saveUsageData = false
  // Offline Mode keeps no usage log; the switch keeps its value and applies again afterwards.
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false
  @State private var showDeleteConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Usage Data",
        systemImage: "tray.full",
        subtitle: "Keeps your dictations, prompts and chats on this Mac so you can ask the Chat or a connected AI app why something went wrong and let it fix a term or a rule. Nothing reads it on its own."
      )

      VStack(alignment: .leading, spacing: 10) {
        Toggle("Save usage data", isOn: $saveUsageData)
          .toggleStyle(.switch)
          .disabled(offlineMode)

        if offlineMode {
          Text("Paused while Offline Mode is on. Nothing is stored.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack(alignment: .center, spacing: 12) {
          Button(action: { viewModel.openContextFolder() }) {
            Label("Open context data", systemImage: "folder")
              .font(.callout)
          }
          .buttonStyle(.bordered)
          .help("Open context data in Finder")
          .pointerCursorOnHover()

          Button("Delete context data", role: .destructive) {
            showDeleteConfirmation = true
          }
          .buttonStyle(.bordered)
          .tint(.red)
          .help("Only delete interaction history and context; settings are preserved")
          .pointerCursorOnHover()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .confirmationDialog("Delete context data?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        viewModel.deleteInteractionData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("All interaction data and everything in context files will be deleted. System prompts will be recreated with defaults. Settings are preserved. Continue?")
    }
  }
}
