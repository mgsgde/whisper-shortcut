//
//  ModelImportSection.swift
//  WhisperShortcut
//
//  "Import from folder…" for the offline model lists.
//
//  The user picks the folder where they already keep models (LM Studio, a Hugging Face cache, a
//  shared drive). The app finds what it can use there, shows what it found and what the import
//  will cost, and copies it once into its own container. After that it is a normal model.
//

import SwiftUI

struct ModelImportSection: View {
  /// Which family this call site may import — Speech to Text offers Whisper and Qwen3-ASR, the
  /// chat sections offer MLX chat models, Read Aloud offers Qwen3 TTS.
  let group: ModelImportGroup
  /// Receives a ready-to-show message when an import fails.
  let onError: (String) -> Void

  @State private var plans: [ModelImportPlan] = []
  @State private var isScanning = false
  @State private var isImporting = false
  @State private var progress: Double = 0
  @State private var currentName = ""
  @State private var showSheet = false
  @State private var activeImport: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Import a Model",
        systemImage: "square.and.arrow.down",
        subtitle:
          "Already have these models in LM Studio or a Hugging Face cache? Import one instead of downloading it again. The files are copied once into the app's own folder."
      )

      HStack(spacing: 12) {
        Button(buttonTitle) {
          pickFolder()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isScanning || isImporting)
        .pointerCursorOnHover()

        if isScanning {
          ProgressView().controlSize(.small)
        }
      }
    }
    .sheet(isPresented: $showSheet) {
      importSheet
    }
  }

  private var buttonTitle: LocalizedStringKey {
    if isScanning { return "Scanning…" }
    if isImporting { return "Importing…" }
    return "Import from folder…"
  }

  // MARK: - Picker

  private func pickFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = Self.defaultImportDirectory
    panel.message = String(
      localized:
        "Choose the folder that holds your models — your LM Studio models folder or your Hugging Face cache."
    )
    guard panel.runModal() == .OK, let url = panel.url else { return }
    // The sandbox can only rescan this folder later if a bookmark remembers the grant.
    ModelImporter.saveFolderBookmark(url)

    isScanning = true
    Task {
      let group = self.group
      let found = await Task.detached(priority: .userInitiated) {
        ModelImporter.plans(in: url).filter { $0.family.group == group }
      }.value

      isScanning = false
      guard !found.isEmpty else {
        onError(ModelImportError.nothingFound.localizedDescription)
        return
      }
      plans = found
      showSheet = true
    }
  }

  /// Where the folder panel opens: the real home's Hugging Face cache root (not `hub`, so a
  /// grant covers a huggingface_hub 1.32 shared blob store beside `hub`), else LM Studio's
  /// models folder, else nowhere. `homeDirectoryForCurrentUser` is the app container in a
  /// sandboxed build, so the panel would otherwise open inside the container.
  static var defaultImportDirectory: URL? {
    let home = URL(fileURLWithPath: AppConstants.realHomeDirectory, isDirectory: true)
    let fm = FileManager.default
    for candidate in [".cache/huggingface", ".lmstudio/models"] {
      let url = home.appendingPathComponent(candidate)
      if fm.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  // MARK: - Confirmation sheet

  private var importSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Models found")
        .font(.headline)
      Text("Pick the ones to import. They are copied into the app's own folder and work like a normal download afterwards.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(plans) { plan in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              VStack(alignment: .leading, spacing: 2) {
                Text(plan.displayName)
                  .font(.body)
                Text("\(plan.sizeLabel) — copied into the app")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              Spacer()
              if isImporting && currentName == plan.displayName {
                ProgressView(value: progress)
                  .progressViewStyle(.linear)
                  .frame(width: 120)
              } else {
                Button("Import") {
                  importOne(plan)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isImporting)
                .pointerCursorOnHover()
              }
            }
            .padding(10)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
          }
        }
      }
      .frame(maxHeight: 320)

      HStack {
        Spacer()
        if isImporting {
          Button("Cancel Import") { activeImport?.cancel() }
            .keyboardShortcut(.cancelAction)
        } else {
          Button("Done") { showSheet = false }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .frame(width: 520)
  }

  // MARK: - Import

  /// Runs one import off the main actor and reports progress back to it.
  ///
  /// The copy itself is `Task.detached` because a multi-gigabyte copy on the main actor would
  /// freeze Settings for its whole duration, and so that Cancel can stop it directly — a
  /// detached task is not cancelled by cancelling an enclosing `Task`.
  private func importOne(_ plan: ModelImportPlan) {
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

    Self.setImporting(plan.family, true)
    isImporting = true
    progress = 0
    currentName = plan.displayName

    activeImport = Task.detached(priority: .userInitiated) {
      do {
        try ModelImporter.perform(plan, preconditions: .unchecked) { fraction in
          Task { @MainActor in progress = fraction }
        }

        // Whisper's tokenizer lives in a different repo than the CoreML weights; this copies one
        // in if found next to the weights, else tries the network — never throws.
        var needsInternet = false
        if case .whisper(let type) = plan.family {
          await ModelImporter.finishWhisperImport(plan)
          needsInternet = !ModelManager.shared.isModelAvailable(type)
        }

        await MainActor.run {
          Self.setImporting(plan.family, false)
          isImporting = false
          plans.removeAll { $0.id == plan.id }
          if plans.isEmpty { showSheet = false }
          if needsInternet {
            PopupNotificationWindow.showInfo(
              verbatim: String(
                localized:
                  "\(plan.displayName) was imported. WhisperShortcut needs internet once to finish setting up this model."),
              title: "Model Imported", customDisplayDuration: 10)
          } else {
            PopupNotificationWindow.showInfo(
              verbatim: String(
                localized:
                  "\(plan.displayName) was imported. The first use may take a moment to load the model into memory."),
              title: "Model Imported", customDisplayDuration: 10)
          }
        }
      } catch is CancellationError {
        await MainActor.run {
          Self.setImporting(plan.family, false)
          isImporting = false
        }
      } catch {
        await MainActor.run {
          Self.setImporting(plan.family, false)
          isImporting = false
          onError(error.localizedDescription)
        }
      }
    }
  }

  /// Puts `family`'s model in its store's `downloadingModels` set for the duration of the copy,
  /// which is what hides Download. Clearing it refreshes the row from disk.
  /// The Download row's own import uses the same flag so both paths agree on "in progress".
  @MainActor
  static func setImporting(_ family: ModelImportPlan.Family, _ importing: Bool) {
    switch family {
    case .whisper(let type): ModelManager.shared.setImporting(type, importing)
    case .mlx(let type): LocalLLMModelManager.shared.setImporting(type, importing)
    case .qwen3(let type): Qwen3ModelManager.shared.setImporting(type, importing)
    }
  }
}
