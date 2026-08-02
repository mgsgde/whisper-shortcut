import SwiftUI

/// Two-column grid of model tiles, shared by the transcription, prompt, and TTS model pickers.
///
/// Only the *geometry* is shared. Each picker keeps its own cell builder because what makes a
/// tile selected, disabled, or recommended genuinely differs per model type — transcription
/// disables by provider key, prompt disables in subscription mode, TTS asks the model itself.
/// Pulling the cell in too would mean a parameter per rule, which is how the three copies got
/// out of step in the first place.
/// Deliberately **not** a `LazyVGrid`: several of these grids are stacked inside one settings
/// ScrollView, and the lazy container mis-measured its rows there — a group would reserve the
/// full height while leaving all but one tile undrawn, and the surviving tile stretched to fill
/// the empty rows. These lists are a handful of models each, so eager rows cost nothing.
struct ModelGrid<Model: Hashable, Cell: View>: View {
  let models: [Model]
  @ViewBuilder let cell: (Model) -> Cell

  private static var columns: Int { 2 }

  var body: some View {
    VStack(spacing: SettingsConstants.modelSpacing) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: SettingsConstants.modelSpacing) {
          ForEach(row, id: \.self) { model in
            // maxHeight lets a tile match a taller neighbour (routed tiles carry a subtitle);
            // fixedSize on the row keeps that height intrinsic instead of greedy.
            cell(model)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          // Keeps a lone trailing tile at column width instead of spanning the whole row.
          if row.count < Self.columns {
            ForEach(0..<(Self.columns - row.count), id: \.self) { _ in
              Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var rows: [[Model]] {
    stride(from: 0, to: models.count, by: Self.columns).map { start in
      Array(models[start..<min(start + Self.columns, models.count)])
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
