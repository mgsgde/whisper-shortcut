import SwiftUI

/// The user's own Dictate Prompt quick actions, plus the switch for the ones learned from usage.
/// Shown in Settings → Dictate Prompt. Read by `QuickActionStore.current()` on every ⌘2, so an
/// edit here shows up on the next recording without a refresh.
struct QuickPromptsSection: View {
  @AppStorage(UserDefaultsKeys.dictatePromptLearnedQuickActionsEnabled) private var learnedEnabled = true
  @State private var rows: [Row] = []

  private struct Row: Identifiable, Equatable {
    let id = UUID()
    var text: String
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Quick Prompts",
        systemImage: "bolt",
        subtitle: "Listed above the recording pill while you dictate a prompt. Click one or press ⌃1–9 instead of speaking."
      )

      VStack(alignment: .leading, spacing: 8) {
        if rows.isEmpty {
          emptyState
        } else {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            rowView(index: index, row: row)
          }
        }

        HStack(spacing: 12) {
          Button(action: addRow) {
            Label("Add Prompt", systemImage: "plus")
              .font(.callout)
          }
          .buttonStyle(.bordered)
          .disabled(rows.count >= QuickActionStore.maxCustomEntries)
          .help(
            rows.count >= QuickActionStore.maxCustomEntries
              ? "Up to \(QuickActionStore.maxCustomEntries) prompts, one per ⌃ shortcut"
              : "Add a prompt of your own")
          .pointerCursorOnHover()

          if rows.isEmpty, learnedEnabled {
            Button(action: copySuggestions) {
              Label("Start from Current List", systemImage: "square.on.square")
                .font(.callout)
            }
            .buttonStyle(.bordered)
            .help("Copy the prompts shown today into your own list, then edit them")
            .pointerCursorOnHover()
          }
        }
      }

      Toggle(isOn: $learnedEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Also show prompts you use often")
            .font(.callout)
          Text(learnedCaption)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
    }
    .onAppear(perform: load)
    .onChange(of: rows) { _, newRows in
      UserDefaults.standard.set(
        newRows.map(\.text), forKey: UserDefaultsKeys.dictatePromptCustomQuickActions)
    }
  }

  // MARK: - Rows

  private func rowView(index: Int, row: Row) -> some View {
    let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let kind = QuickActionKind.classify(QuickActionStore.normalizeKey(trimmed))
    return HStack(spacing: 8) {
      Image(systemName: kind.symbolName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.secondary)
        .frame(width: 18, alignment: .center)
        .accessibilityHidden(true)

      TextField("e.g. Translate to English", text: binding(for: row.id))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Quick prompt \(index + 1)")

      Text("\u{2303}\(index + 1)")
        .font(.callout.monospacedDigit())
        .foregroundColor(.secondary)
        .frame(width: 28, alignment: .trailing)
        .accessibilityHidden(true)

      Button {
        move(from: index, by: -1)
      } label: {
        Image(systemName: "arrow.up")
      }
      .buttonStyle(.borderless)
      .disabled(index == 0)
      .help("Move up — a lower number")
      .accessibilityLabel("Move prompt \(index + 1) up")
      .pointerCursorOnHover()

      Button {
        rows.removeAll { $0.id == row.id }
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Remove this prompt")
      .accessibilityLabel("Remove prompt \(index + 1)")
      .pointerCursorOnHover()
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    Text(
      learnedEnabled
        ? "No prompts of your own yet. Until you add one, the list shows the instructions you repeat most, filled up with a few defaults."
        : "No prompts of your own, and suggestions are off: the list stays hidden while you record."
    )
    .font(.callout)
    .foregroundColor(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var learnedCaption: String {
    rows.isEmpty
      ? "Learned from your Dictate Prompt instructions of the last 30 days."
      : "Learned from your Dictate Prompt instructions of the last 30 days, listed below your own prompts."
  }

  // MARK: - Editing

  private func binding(for id: UUID) -> Binding<String> {
    Binding(
      get: { rows.first { $0.id == id }?.text ?? "" },
      set: { newValue in
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].text = newValue
      })
  }

  private func load() {
    rows = QuickActionStore.storedCustomTexts().map { Row(text: $0) }
  }

  private func addRow() {
    guard rows.count < QuickActionStore.maxCustomEntries else { return }
    rows.append(Row(text: ""))
  }

  private func move(from index: Int, by offset: Int) {
    let target = index + offset
    guard rows.indices.contains(index), rows.indices.contains(target) else { return }
    rows.swapAt(index, target)
  }

  /// Seeds the list with what the recording card shows right now, learned entries included.
  private func copySuggestions() {
    rows = QuickActionStore.shared.current()
      .prefix(QuickActionStore.maxCustomEntries)
      .map { Row(text: $0.text) }
  }
}
