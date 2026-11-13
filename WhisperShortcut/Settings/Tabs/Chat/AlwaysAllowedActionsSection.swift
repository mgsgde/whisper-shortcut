import SwiftUI

/// Lists the chat actions the user allowed for good ("Always allow" on the approval card) and
/// lets them take one back. Hidden while the list is empty, so the default user never sees it.
struct AlwaysAllowedActionsSection: View {
  @ObservedObject private var store = ChatToolAlwaysAllow.shared

  var body: some View {
    if !store.toolNames.isEmpty {
      VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
        SectionHeader(
          title: "Always allowed",
          systemImage: "checkmark.shield",
          subtitle: "The chat does these without asking first. Remove one to get the approval card back."
        )

        VStack(alignment: .leading, spacing: 8) {
          ForEach(store.toolNames.sorted(by: Self.byLabel), id: \.self) { name in
            HStack(spacing: 12) {
              Text(ChatToolAlwaysAllow.displayName(for: name))
                .font(.callout)
              Spacer()
              Button("Remove") { store.revoke(name) }
                .controlSize(.small)
            }
          }
        }

        if store.toolNames.count > 1 {
          Button("Ask again for all") { store.revokeAll() }
            .controlSize(.small)
        }
      }
    }
  }

  private static func byLabel(_ a: String, _ b: String) -> Bool {
    ChatToolAlwaysAllow.displayName(for: a)
      .localizedStandardCompare(ChatToolAlwaysAllow.displayName(for: b)) == .orderedAscending
  }
}
