import AppKit
import SwiftUI

/// One "Available Models" row — name, badge, status, size, then Download / progress + Cancel /
/// Delete — for any `ModelStore` family. The Whisper and MLX lists render the same row; only the
/// badge text and the post-download hint differ.
struct ModelDownloadRow<M: DownloadableModel, Badge: View>: View {
  @ObservedObject var store: ModelStore<M>
  let model: M
  /// Shown in the "Model Downloaded" popup after a successful download.
  let downloadedMessage: String
  /// Receives a ready-to-show message when a download or delete fails.
  let onError: (String) -> Void
  @ViewBuilder let badge: () -> Badge

  /// Import-in-flight state, mirroring the download states above it.
  /// `activeImport` is detached so Cancel stops the copy directly.
  @State private var isImporting = false
  @State private var importProgress: Double = 0
  @State private var activeImport: Task<Void, Never>?

  var body: some View {
    let isDownloading = !isImporting && store.downloadingModels.contains(model)
    // Only check availability when not downloading (prevents a "Downloaded / 0 MB" glitch).
    let isAvailable = !isDownloading && store.isModelAvailable(model)
    // Only when it is going to be shown: `getModelSize` enumerates the whole model directory —
    // gigabytes of shards — and this body re-runs on every download-progress tick.
    let modelSize = isAvailable ? store.getModelSize(model) : nil

    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(model.displayName)
              .font(.body)
              .fontWeight(.semibold)
            badge()
          }

          HStack(spacing: 12) {
            HStack(spacing: 4) {
              if isImporting {
                Image(systemName: "square.and.arrow.down.circle.fill")
                  .foregroundColor(.blue)
                  .font(.caption)
                Text("Importing…")
                  .font(.caption)
                  .foregroundColor(.secondary)
              } else if isDownloading {
                Image(systemName: "arrow.down.circle.fill")
                  .foregroundColor(.blue)
                  .font(.caption)
                // The percentage sits next to the progress bar on the right; once is enough.
                Text("Downloading…")
                  .font(.caption)
                  .foregroundColor(.secondary)
              } else {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle")
                  .foregroundColor(isAvailable ? .green : .secondary)
                  .font(.caption)
                Text(isAvailable ? ("Downloaded" as LocalizedStringKey) : "Not downloaded")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }

            if !isDownloading, let size = modelSize {
              Text("• \(store.formatSize(size))")
                .font(.caption)
                .foregroundColor(.secondary)
            } else if !isDownloading {
              Text("• \(model.estimatedSizeLabel)")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }

        Spacer()

        if isImporting {
          HStack(spacing: 8) {
            if importProgress > 0 {
              ProgressView(value: importProgress)
                .progressViewStyle(.linear)
                .frame(width: 90)
              Text("\(Int(importProgress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
            } else {
              ProgressView()
                .scaleEffect(0.8)
            }
            Button("Cancel Import") {
              activeImport?.cancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursorOnHover()
          }
        } else if isDownloading {
          HStack(spacing: 8) {
            if let fraction = store.downloadProgress[model], fraction > 0 {
              ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 90)
              Text("\(Int(fraction * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
            } else {
              ProgressView()
                .scaleEffect(0.8)
              Text("Starting…")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Button("Cancel") {
              store.cancelDownload(model)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursorOnHover()
          }
        } else if isAvailable {
          Button("Delete", action: delete)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundColor(.red)
            .pointerCursorOnHover()
        } else {
          Button("Download", action: download)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .pointerCursorOnHover()
        }
      }
    }
    .padding(SettingsConstants.rowPadding)
    .background(Color(.controlBackgroundColor))
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(.separatorColor), lineWidth: 1)
    )
  }

  private func download() {
    Task {
      // Before a multi-gigabyte download, look for weights the user already has. Off the main
      // thread: the scan stats snapshot folders inside bookmarked directories.
      let existing = await Task.detached(priority: .userInitiated) {
        ModelImporter.existingWeightsPlan(for: model)
      }.value

      if let existing {
        switch importAlert(for: existing) {
        case .import:
          importExisting(existing)
          return
        case .cancel:
          return
        case .downloadAnyway:
          break
        }
      } else if shouldOfferImportFolder {
        switch folderOfferAlert() {
        case .chooseFolder:
          guard let url = pickImportFolder() else { return }
          guard ModelImporter.saveFolderBookmark(url) else {
            onError(
              String(
                localized:
                  "WhisperShortcut could not remember that folder. Choose it again, or download the model."
              ))
            return
          }
          let found = await Task.detached(priority: .userInitiated) {
            ModelImporter.existingWeightsPlan(for: model)
          }.value
          if let found {
            importExisting(found)
            return
          }
          switch notFoundAlert() {
          case .download:
            break
          case .cancel:
            return
          }
        case .download:
          break
        case .cancel:
          return
        }
      }

      do {
        try await store.downloadModel(model)
        DebugLogger.logSuccess("\(store.logPrefix): UI download finished for \(model.displayName)")
        // The status-bar-level popup the rest of the app uses for dictation/prompt feedback: it
        // sits above the Settings window regardless of focus. 10 s — longer than the 1 s info
        // default — because this is a rare event with first-run information worth reading.
        PopupNotificationWindow.showInfo(
          verbatim: downloadedMessage,
          title: "Model Downloaded",
          customDisplayDuration: 10
        )
      } catch is CancellationError {
        // Cancelled from the Cancel button.
      } catch {
        DebugLogger.logError("\(store.logPrefix): UI download failed for \(model.displayName): \(error.logDescription)")
        onError(String(localized: "Failed to download \(model.displayName): \(SpeechErrorFormatter.formatForUser(error))"))
      }
    }
  }

  /// What the user picked in the "already on this Mac" alert.
  private enum ExistingWeightsChoice {
    case `import`
    case downloadAnyway
    case cancel
  }

  /// Asks whether to import weights that are already on this Mac instead of downloading them
  /// again. Import is the default: it is faster and uses no network.
  private func importAlert(for plan: ModelImportPlan) -> ExistingWeightsChoice {
    let alert = NSAlert()
    alert.messageText = String(localized: "Already on this Mac")
    alert.informativeText = String(
      localized:
        "\(plan.displayName) was found in your Hugging Face cache or LM Studio folder (\(plan.sizeLabel)). Import it instead of downloading it again?"
    )
    alert.alertStyle = .informational
    alert.addButton(withTitle: String(localized: "Import"))
    alert.addButton(withTitle: String(localized: "Download Anyway"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .import
    case .alertSecondButtonReturn: return .downloadAnyway
    default: return .cancel
    }
  }

  /// No bookmarks yet, and the user has not checked "Don't ask again".
  private var shouldOfferImportFolder: Bool {
    !ModelImporter.hasFolderBookmarks
      && !UserDefaults.standard.bool(forKey: ModelImporter.offerDismissedDefaultsKey)
  }

  private enum FolderOfferChoice {
    case chooseFolder
    case download
    case cancel
  }

  /// Offers to point at an existing Hugging Face cache or LM Studio folder instead of
  /// downloading. Choose Folder is the default. Escape dismisses without downloading.
  /// The suppression checkbox is the only thing that sets `modelImportOfferDismissed`.
  private func folderOfferAlert() -> FolderOfferChoice {
    let alert = EscapeDismissAlert()
    alert.messageText = String(localized: "Already have this model?")
    alert.informativeText = String(
      localized:
        "If you downloaded it before with Hugging Face or LM Studio, WhisperShortcut can import it from that folder instead of downloading it again."
    )
    alert.alertStyle = .informational
    alert.addButton(withTitle: String(localized: "Choose Folder…"))
    alert.addButton(withTitle: String(localized: "Download"))
    // Escape only cancels when some button has that key equivalent. The button stays in the
    // hierarchy so the key reaches it; `EscapeDismissAlert` takes it out of the layout so the
    // visible buttons are Choose Folder and Download.
    let escape = alert.addButton(withTitle: String(localized: "Cancel"))
    escape.keyEquivalent = "\u{1b}"
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = String(localized: "Don't ask again")
    let response = alert.runModal()
    if alert.suppressionButton?.state == .on {
      UserDefaults.standard.set(true, forKey: ModelImporter.offerDismissedDefaultsKey)
    }
    switch response {
    case .alertFirstButtonReturn: return .chooseFolder
    case .alertSecondButtonReturn: return .download
    default: return .cancel
    }
  }

  /// Same panel as `ModelImportSection.pickFolder`: directories only, hidden files visible,
  /// opening at the real-home cache when that folder exists.
  private func pickImportFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = ModelImportSection.defaultImportDirectory
    panel.message = String(
      localized: "Choose your Hugging Face cache or LM Studio models folder.")
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url
  }

  private enum NotFoundChoice {
    case download
    case cancel
  }

  /// Shown after the user picked a folder that does not contain this model.
  private func notFoundAlert() -> NotFoundChoice {
    let alert = NSAlert()
    alert.messageText = String(localized: "Not found in that folder")
    alert.informativeText = String(localized: "\(model.displayName) isn't in the folder you chose.")
    alert.alertStyle = .informational
    alert.addButton(withTitle: String(localized: "Download"))
    let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
    cancel.keyEquivalent = "\u{1b}"
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .download
    default: return .cancel
    }
  }

  /// Copies `plan` with the same refusal rules and completion as `ModelImportSection.importOne`:
  /// a running download or a model already on disk is refused, Whisper gets its tokenizer pass,
  /// and the store's importing flag hides Download until the copy finishes.
  private func importExisting(_ plan: ModelImportPlan) {
    let preconditions = ModelImportPreconditions.live(for: plan.family)
    // Refuse before marking the model busy. The copy below passes `.unchecked` so the busy
    // flag this import is about to set is not read back as "a download is in progress".
    if preconditions.isDownloading || preconditions.isModelAvailable {
      do {
        try ModelImporter.perform(plan, preconditions: preconditions) { _ in }
      } catch {
        onError(error.localizedDescription)
      }
      return
    }

    ModelImportSection.setImporting(plan.family, true)
    isImporting = true
    importProgress = 0

    activeImport = Task.detached(priority: .userInitiated) {
      // The scan released its security scope before the alert. The copy reads the same
      // bookmarked folders, so the scope has to be open again until the files are in the container.
      let accessed = ModelImporter.startAccessingSearchFolders()
      defer { ModelImporter.stopAccessingSearchFolders(accessed) }
      do {
        try ModelImporter.perform(plan, preconditions: .unchecked) { fraction in
          Task { @MainActor in importProgress = fraction }
        }

        var needsInternet = false
        if case .whisper(let type) = plan.family {
          await ModelImporter.finishWhisperImport(plan)
          needsInternet = !ModelManager.shared.isModelAvailable(type)
        }

        await MainActor.run {
          ModelImportSection.setImporting(plan.family, false)
          isImporting = false
          if needsInternet {
            PopupNotificationWindow.showInfo(
              verbatim: String(
                localized:
                  "\(plan.displayName) was imported. WhisperShortcut needs internet once to finish setting up this model."
              ),
              title: "Model Imported",
              customDisplayDuration: 10
            )
          } else {
            PopupNotificationWindow.showInfo(
              verbatim: String(
                localized:
                  "\(plan.displayName) was imported. The first use may take a moment to load the model into memory."
              ),
              title: "Model Imported",
              customDisplayDuration: 10
            )
          }
        }
      } catch is CancellationError {
        await MainActor.run {
          ModelImportSection.setImporting(plan.family, false)
          isImporting = false
        }
      } catch {
        await MainActor.run {
          ModelImportSection.setImporting(plan.family, false)
          isImporting = false
          onError(error.localizedDescription)
        }
      }
    }
  }

  private func delete() {
    do {
      try store.deleteModel(model)
    } catch {
      DebugLogger.logError("\(store.logPrefix): UI delete failed for \(model.displayName): \(error.logDescription)")
      onError(String(localized: "Failed to delete \(model.displayName): \(SpeechErrorFormatter.formatForUser(error))"))
    }
  }
}

/// An alert whose last button dismisses on Escape and takes no space.
///
/// `NSAlert` only treats Escape as cancel when a button has that key equivalent, and a hidden
/// button never receives key equivalents. After the alert's own layout, the button stays in the
/// view hierarchy (so Escape still reaches it) but is removed from the stack view (so Choose
/// Folder and Download are the only buttons the user sees).
private final class EscapeDismissAlert: NSAlert {
  private var collapsingEscape = false

  override func layout() {
    guard !collapsingEscape else { return }
    collapsingEscape = true
    defer { collapsingEscape = false }
    super.layout()
    guard buttons.count >= 3, let escape = buttons.last else { return }
    escape.keyEquivalent = "\u{1b}"
    var view: NSView? = escape.superview
    while let current = view {
      if let stack = current as? NSStackView, stack.arrangedSubviews.contains(escape) {
        stack.removeArrangedSubview(escape)
        escape.alphaValue = 0
        escape.frame = .zero
        return
      }
      view = current.superview
    }
  }
}

extension DownloadableModel {
  /// "~1600 MB" — what a row shows before the model is on disk. Families with a nicer unit
  /// (MLX's "≈2.5 GB") provide their own.
  var estimatedSizeLabel: String { "~\(estimatedSizeMB) MB" }
}
