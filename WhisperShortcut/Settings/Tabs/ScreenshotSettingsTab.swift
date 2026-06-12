import AppKit
import SwiftUI

/// Screenshot Settings Tab — capture shortcut plus optional save-to-folder behavior.
struct ScreenshotSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      keyboardShortcutSection

      SpacedSectionDivider()

      saveSection

      SpacedSectionDivider()

      usageSection
    }
  }

  // MARK: - Keyboard Shortcut Section
  @ViewBuilder
  private var keyboardShortcutSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Keyboard Shortcut",
        systemImage: "keyboard",
        subtitle: "Press the shortcut to capture a region of the screen to the clipboard (e.g. to paste into chat)"
      )

      ShortcutRecorderRow(
        label: "Screenshot to Clipboard:",
        shortcut: $viewModel.data.screenshotCapture,
        focusedField: .screenshotCapture,
        currentFocus: $focusedField,
        onChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        findConflict: viewModel.findShortcutConflict,
        clearShortcut: viewModel.clearShortcut
      )
    }
  }

  // MARK: - Save Section
  @ViewBuilder
  private var saveSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Save Screenshots",
        systemImage: "square.and.arrow.down",
        subtitle: "Also write each screenshot as a PNG into a folder, so the chat Attach picker finds them right away"
      )

      Toggle(isOn: $viewModel.data.screenshotSaveEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Save screenshots to a folder")
            .font(.callout)
          Text("Applies to both the ⌘3 shortcut and the in-chat Screenshot button. The clipboard still receives the image as before.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.screenshotSaveEnabled) { _ in
        Task { await viewModel.saveSettings() }
      }

      if viewModel.data.screenshotSaveEnabled {
        HStack(alignment: .center, spacing: 12) {
          Text("Folder:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: SettingsConstants.labelWidth, alignment: .leading)

          Text(folderDisplay)
            .font(.callout)
            .foregroundColor(viewModel.data.screenshotSaveFolderDisplayPath.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)

          Spacer()

          Button("Choose Folder…") {
            chooseFolder()
          }
          .pointerCursorOnHover()
        }
      }
    }
  }

  private var folderDisplay: String {
    let path = viewModel.data.screenshotSaveFolderDisplayPath
    return path.isEmpty ? "No folder selected" : (path as NSString).abbreviatingWithTildeInPath
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Choose a folder to save screenshots into"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if ScreenshotSaveLocation.setFolder(url) {
      viewModel.data.screenshotSaveFolderDisplayPath = url.path
    }
  }

  // MARK: - Usage Section
  @ViewBuilder
  private var usageSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "How to Use",
        systemImage: "questionmark.circle",
        subtitle: "Capture a screenshot anywhere on your Mac"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("Press the shortcut, then drag to select a region. The image is copied to the clipboard.")
          .textSelection(.enabled)
        Text("With saving enabled, each capture is also stored as a PNG in your chosen folder.")
          .textSelection(.enabled)
        Text("In the chat window, Attach opens that folder first so recent screenshots are one click away.")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }
}
