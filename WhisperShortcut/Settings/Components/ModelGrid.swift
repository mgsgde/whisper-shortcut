import SwiftUI

/// Two-column grid of model tiles, shared by the transcription, prompt, and TTS model pickers.
///
/// Only the *geometry* is shared. Each picker keeps its own cell builder because what makes a
/// tile selected, disabled, or recommended genuinely differs per model type — transcription
/// disables by provider key, prompt disables in subscription mode, TTS asks the model itself.
/// Pulling the cell in too would mean a parameter per rule, which is how the three copies got
/// out of step in the first place.
struct ModelGrid<Model: Hashable, Cell: View>: View {
  let models: [Model]
  @ViewBuilder let cell: (Model) -> Cell

  var body: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible()), count: 2),
      spacing: SettingsConstants.modelSpacing
    ) {
      ForEach(models, id: \.self) { model in
        cell(model)
      }
    }
  }
}

/// Caption above a group of model tiles ("Cloud · needs an API key", "Offline · on-device").
/// Distinct from `SectionHeader`, which titles a whole settings section.
struct ModelGroupHeader: View {
  let symbol: String
  let title: String
  /// Omitted by the prompt picker for groups whose name already says everything.
  var subtitle: String?

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.caption)
        .foregroundColor(.secondary)
      Text(title)
        .font(.callout)
        .fontWeight(.semibold)
      if let subtitle {
        Text("· \(subtitle)")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(.horizontal, 4)
    .padding(.bottom, 6)
  }
}
