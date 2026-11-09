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
  /// Receives a ready-to-show message when an import fails.
  let onError: (String) -> Void
  /// Called after a successful import so the caller can refresh anything it caches.
  var onImported: () -> Void = {}

  @State private var plans: [ModelImportPlan] = []
  @State private var isPicking = false
  @State private var isImporting = false
  @State private var progress: Double = 0
  @State private var currentName = ""
  @State private var showSheet = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Import a Model",
        systemImage: "square.and.arrow.down",
        subtitle:
          "Already have these models in LM Studio or a Hugging Face cache? Import one instead of downloading it again. The files are copied once into the app's own folder; on the same disk that copy takes no extra space."
      )

      HStack(spacing: 12) {
        Button(isImporting ? "Importing…" : "Import from folder…") {
          pickFolder()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isImporting)
        .pointerCursorOnHover()

        if isImporting {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .frame(width: 120)
          Text(currentName)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }
    }
    .sheet(isPresented: $showSheet) {
      importSheet
    }
  }

  // MARK: - Picker

  private func pickFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = String(
      localized:
        "Choose the folder that holds your models — your LM Studio models folder or your Hugging Face cache."
    )
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let found = ModelImporter.plans(in: url)
    guard !found.isEmpty else {
      onError(ModelImportError.nothingFound.localizedDescription)
      return
    }
    plans = found
    showSheet = true
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
                Text(plan.willClone
                  ? "\(plan.sizeLabel) — no extra space on this disk"
                  : "\(plan.sizeLabel) — copied from another disk")
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
  /// freeze Settings for its whole duration. The Whisper tokenizer fetch afterwards is a network
  /// round-trip and stays on the same task so the row only disappears once the model can load.
  private func importOne(_ plan: ModelImportPlan) {
    isImporting = true
    progress = 0
    currentName = plan.displayName

    Task {
      do {
        try await Task.detached(priority: .userInitiated) {
          try ModelImporter.perform(plan) { fraction in
            Task { @MainActor in progress = fraction }
          }
        }.value

        // Whisper's tokenizer lives in a different repo than the CoreML weights; an imported
        // model needs one network round-trip before it can load offline.
        if case .whisper(let type) = plan.family {
          try await ModelImporter.finishWhisperImport(type)
        }

        await MainActor.run {
          isImporting = false
          plans.removeAll { $0.id == plan.id }
          if plans.isEmpty { showSheet = false }
          onImported()
          PopupNotificationWindow.showInfo(
            verbatim: String(
              localized:
                "\(plan.displayName) was imported. The first use may take a moment to load the model into memory."),
            title: "Model Imported",
            customDisplayDuration: 10)
        }
      } catch {
        await MainActor.run {
          isImporting = false
          onError(error.localizedDescription)
        }
      }
    }
  }
}
