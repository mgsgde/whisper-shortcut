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

        if isImporting {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .frame(width: 120)
          Text(currentName)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
          Button("Cancel Import") {
            activeImport?.cancel()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .pointerCursorOnHover()
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

  /// The user's Hugging Face cache, or LM Studio's models folder if that is the one that exists.
  private static var defaultImportDirectory: URL? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    for candidate in [".cache/huggingface/hub", ".lmstudio/models"] {
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
              Button("Import") {
                importOne(plan)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              .disabled(isImporting)
              .pointerCursorOnHover()
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
        Button("Done") { showSheet = false }
          .keyboardShortcut(.defaultAction)
          .disabled(isImporting)
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
    isImporting = true
    progress = 0
    currentName = plan.displayName

    activeImport = Task.detached(priority: .userInitiated) {
      do {
        try ModelImporter.perform(plan) { fraction in
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
          isImporting = false
          plans.removeAll { $0.id == plan.id }
          if plans.isEmpty { showSheet = false }
          notifyStore(for: plan.family)
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
        await MainActor.run { isImporting = false }
      } catch {
        await MainActor.run {
          isImporting = false
          onError(error.localizedDescription)
        }
      }
    }
  }

  /// The imported model's store does not touch its own `@Published` state during an import, so
  /// its rows (bound via `@ObservedObject`) would not otherwise notice the model is now on disk.
  @MainActor
  private func notifyStore(for family: ModelImportPlan.Family) {
    switch family {
    case .whisper: ModelManager.shared.objectWillChange.send()
    case .mlx: LocalLLMModelManager.shared.objectWillChange.send()
    case .qwen3: Qwen3ModelManager.shared.objectWillChange.send()
    }
  }
}
