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
  /// Two everywhere except the curated top row, which fits its three tiles on one line.
  var columns: Int = 2
  @ViewBuilder let cell: (Model) -> Cell

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
          if row.count < columns {
            ForEach(0..<(columns - row.count), id: \.self) { _ in
              Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var rows: [[Model]] {
    stride(from: 0, to: models.count, by: columns).map { start in
      Array(models[start..<min(start + columns, models.count)])
    }
  }
}

/// The box every model picker draws: the curated top row (Recommended · Fastest · Offline, plus
/// the current selection when it is none of those), then a "More models" disclosure holding the
/// rest. Which models go where is `ModelPickerCuration`'s call, made from data on the model enums;
/// the picker supplies the tile and how it groups the remainder (by provider, by direct vs routed).
struct CuratedModelPicker<Model: PickerCuratedModel, Cell: View, More: View>: View {
  let curation: ModelPickerCuration<Model>
  @ViewBuilder let cell: (Model, [ModelPickerBadge]) -> Cell
  @ViewBuilder let more: ([Model]) -> More

  @State private var showsMore = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ModelGrid(models: curation.featured.map(\.model), columns: featuredColumns) { model in
        cell(model, curation.featured.first { $0.model == model }?.badges ?? [])
      }

      if !curation.more.isEmpty {
        Divider()
        Button {
          withAnimation(.easeInOut(duration: 0.15)) { showsMore.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundColor(.secondary)
              .rotationEffect(.degrees(showsMore ? 90 : 0))
            Text("More models")
              .font(.callout)
              .fontWeight(.medium)
            Text("\(curation.more.count)")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
        .accessibilityLabel("More models, \(curation.more.count)")
        .accessibilityValue(showsMore ? "Expanded" : "Collapsed")

        if showsMore {
          Divider()
          more(curation.more)
            .padding(10)
        }
      }
    }
    .background(Color(.controlBackgroundColor))
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(.separatorColor), lineWidth: 1)
    )
  }

  /// Three on one line; two or four as a 2-wide grid so no tile is stretched across the box.
  private var featuredColumns: Int { curation.featured.count == 3 ? 3 : 2 }
}

/// Caption above a group of model tiles ("Cloud · needs an API key", "Offline · on-device").
/// Distinct from `SectionHeader`, which titles a whole settings section.
struct ModelGroupHeader: View {
  let symbol: String
  let title: LocalizedStringResource
  /// Omitted by the prompt picker for groups whose name already says everything.
  var subtitle: LocalizedStringResource?

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.caption)
        .foregroundColor(.secondary)
      Text(title)
        .font(.callout)
        .fontWeight(.semibold)
      if let subtitle {
        HStack(spacing: 4) {
          Text(verbatim: "·")
          Text(subtitle)
        }
        .font(.caption)
        .foregroundColor(.secondary)
      }
    }
    .padding(.horizontal, 4)
    .padding(.bottom, 6)
  }
}

/// What every model picker shows under its tiles: the selected model's description, then cost and
/// the comparison link on one line. It used to be three stacked rows ("Cost:", then "Tip: Compare
/// models (speed, intelligence, pricing): gemini-models"), repeated under each picker.
struct ModelDetailsFooter: View {
  let description: String
  let costLevel: CostLevel
  /// The link goes to Google's Gemini comparison page, so only pickers that list Gemini show it.
  var showsCompareLink = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: description)
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        Text("Cost")
          .foregroundColor(.secondary)
        Text(costLevel.title)
          .fontWeight(.semibold)
          .foregroundColor(SettingsConstants.costLevelColor(for: costLevel))
        if showsCompareLink, let url = URL(string: AppConstants.geminiModelsComparisonURL) {
          Text(verbatim: "·")
            .foregroundColor(.secondary)
          Link("Compare Gemini models", destination: url)
            .pointerCursorOnHover()
        }
      }
      .font(.caption)
    }
  }
}
