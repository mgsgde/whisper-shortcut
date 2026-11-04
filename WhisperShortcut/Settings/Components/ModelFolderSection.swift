import AppKit
import SwiftUI

/// "Model folder" — points the app at a folder that already holds model weights (an LM Studio
/// models folder, a Hugging Face cache, a shared drive) so they need not be downloaded again.
///
/// One block for both model families: `ModelManager` and `MLXModelPaths` read the same
/// `ExtraModelFolder`, so a second copy of this UI in the MLX list would only repeat the same
/// setting in another place.
struct ModelFolderSection: View {
  /// Re-renders the model rows after the folder changes. The rows read `isModelAvailable` in
  /// their body and are driven by the stores' `objectWillChange`, so that is the path to poke —
  /// no new notification, no reload timer.
  var onChange: () -> Void

  @State private var hasFolder = ExtraModelFolder.hasFolder
  @State private var displayPath = ExtraModelFolder.displayPath
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Model folder",
        systemImage: "folder",
        subtitle: "The app downloads offline models itself. If you already have the weights on disk — an LM Studio models folder, a Hugging Face cache, a shared drive — point the app at that folder and it uses them instead of downloading again. Nothing in your folder is moved, changed or deleted."
      )

      if let errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundColor(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      if hasFolder {
        HStack(alignment: .center, spacing: 12) {
          Text(displayPath)
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(displayPath)

          Spacer(minLength: 8)

          Button("Change…") { chooseFolder() }
            .pointerCursorOnHover()

          Button("Remove") { removeFolder() }
            .pointerCursorOnHover()
        }
      } else {
        HStack(spacing: 12) {
          Text("No folder selected")
            .font(.callout)
            .foregroundColor(.secondary)

          Spacer(minLength: 8)

          Button("Choose folder…") { chooseFolder() }
            .pointerCursorOnHover()
        }
      }
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Choose")
    panel.message = String(
      localized: "Choose a folder that already contains offline model weights")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if let reason = ExtraModelFolder.setFolder(url) {
      errorMessage = reason
      return
    }
    errorMessage = nil
    hasFolder = true
    displayPath = ExtraModelFolder.displayPath
    onChange()
  }

  private func removeFolder() {
    ExtraModelFolder.clear()
    hasFolder = false
    displayPath = ""
    onChange()
  }
}
