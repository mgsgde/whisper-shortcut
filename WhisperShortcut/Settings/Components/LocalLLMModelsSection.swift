import SwiftUI

/// Whisper-style "Available Models" list for in-process MLX: Download, percent, Delete.
struct LocalLLMModelsSection: View {
  @ObservedObject private var manager = LocalLLMModelManager.shared
  @State private var errorMessage: String?
  /// Which quantisation of each family the list is showing. A family with one entry never reads
  /// this; a family with three defaults to its 4-bit entry, the smallest and fastest.
  @State private var selectedVariant: [LocalLLMModelType: LocalLLMModelType] = [:]
  /// Catalogue entries to list; callers narrow it to the models their picker can actually select.
  var models: [LocalLLMModelType] = LocalLLMModelType.offerable

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Offline Models",
        systemImage: "arrow.down.circle",
        subtitle: "Runs on this Mac, nothing to install. Each model downloads once and stays on disk."
      )

      // Nineteen catalogue entries in one flat column is a wall of rows with no way in. Two splits
      // do the work: by RAM floor, the axis the user actually decides on ("does this run on my
      // Mac, and is it the small one or the big one"), and inside a group by model family, so the
      // 4/6/8-bit variants of one model share a row and a Quality control instead of appearing as
      // three unrelated models. A short list — Dictate Prompt passes only the three entries it can
      // use — stays flat, because headers over three rows are noise.
      let groups = models.count > 4 ? Self.groups(for: models) : []
      VStack(alignment: .leading, spacing: 12) {
        if groups.count > 1 {
          ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider().padding(.vertical, 2) }
            ModelGroupHeader(symbol: group.symbol, title: group.title)
            VStack(spacing: 12) {
              ForEach(LocalLLMModelType.families(in: group.models), id: \.base) { family in
                familyRow(family.base, variants: family.models)
              }
            }
          }
        } else {
          VStack(spacing: 12) {
            ForEach(LocalLLMModelType.families(in: models), id: \.base) { family in
              familyRow(family.base, variants: family.models)
            }
          }
        }
      }

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundColor(.red)
          .textSelection(.enabled)
      }
    }
  }

  private struct Group {
    let symbol: String
    let title: LocalizedStringResource
    let models: [LocalLLMModelType]
  }

  /// Recommended first, then the entries that fit a small Mac, then the ones that need a lot of RAM.
  /// Order inside a group is `allCases` order, i.e. ascending download size.
  ///
  /// Buckets whole families, not single entries: a family's quantisations can carry different RAM
  /// floors (Qwen3.5 9B is 16 GB at 4-bit, 24 GB at 6/8-bit), and splitting them across two headers
  /// would leave each header with a Quality control that offers only part of the family. The
  /// family's 4-bit entry decides the bucket, because that is the one the user compares against.
  private static func groups(for models: [LocalLLMModelType]) -> [Group] {
    let families = LocalLLMModelType.families(in: models)
    let recommended = families.filter { $0.base.isRecommended }.flatMap(\.models)
    let smaller = families
      .filter { !$0.base.isRecommended && $0.base.minimumPhysicalMemoryGB <= 8 }
      .flatMap(\.models)
    let larger = families
      .filter { !$0.base.isRecommended && $0.base.minimumPhysicalMemoryGB > 8 }
      .flatMap(\.models)
    return [
      Group(symbol: "star.fill", title: "Recommended", models: recommended),
      Group(symbol: "hare.fill", title: "Smaller and faster", models: smaller),
      Group(symbol: "memorychip", title: "Larger, needs more RAM", models: larger),
    ].filter { !$0.models.isEmpty }
  }

  /// One model family: the download row of the currently chosen quantisation, plus a Quality
  /// control when the family ships more than one. The control is a segmented picker rather than
  /// three rows because the choice is exclusive — the user runs one precision of a model, and
  /// three rows would invite downloading all three.
  ///
  /// The default is the family's 4-bit entry (smallest, fastest, the one the benchmark notes
  /// describe) unless another quantisation is already on disk: a user who downloaded the 8-bit
  /// copy should see that copy's Delete button, not a Download button for weights they never
  /// asked for.
  @ViewBuilder
  private func familyRow(_ base: LocalLLMModelType, variants: [LocalLLMModelType]) -> some View {
    let chosen = selectedVariant[base]
      ?? variants.first(where: { manager.isModelAvailable($0) })
      ?? variants.first ?? base
    VStack(alignment: .leading, spacing: 6) {
      if variants.count > 1 {
        HStack(spacing: 8) {
          Text("Quality")
            .font(.caption)
            .foregroundColor(.secondary)
          Picker("Quality", selection: Binding(
            get: { chosen },
            set: { selectedVariant[base] = $0 }
          )) {
            ForEach(variants, id: \.self) { variant in
              Text(variant.quantisationLabel).tag(variant)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 220)
          Spacer()
        }
        .padding(.horizontal, 4)
      }
      row(for: chosen)
    }
  }

  private func row(for modelType: LocalLLMModelType) -> some View {
    ModelDownloadRow(
      store: manager,
      model: modelType,
      downloadedMessage: String(
        localized: "\(modelType.displayName) was successfully downloaded. The first reply may take a moment to load the model into memory."),
      onError: { errorMessage = $0 }
    ) {
      if modelType.isRecommended {
        HStack(spacing: 4) {
          Image(systemName: "star.fill")
            .foregroundColor(.yellow)
            .font(.caption)
          // "Best of these", not "recommended": the star picks between the MLX models.
          // A quiet machine can match a local server; under memory pressure it does not.
          Text("Best of these")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }
  }
}
