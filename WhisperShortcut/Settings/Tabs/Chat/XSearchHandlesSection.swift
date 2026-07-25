import SwiftUI

/// Default X accounts Grok's `x_search` is restricted to. Shown in Settings → Chat.
/// New chats inherit this list; `/x` overrides it per chat and `/x off` searches all of X again.
struct XSearchHandlesSection: View {
  @State private var handleText: String = ""

  /// Parsed preview of whatever is currently typed, so the user sees what will actually be sent
  /// (`@Karpathy,` and `https://x.com/karpathy` both become `karpathy`) before hitting the API.
  private var parsed: (handles: [String], droppedOverCap: Int) { XSearchHandles.parse(handleText) }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "X Accounts for Grok",
        systemImage: "at",
        subtitle: "Grok models search X.com posts alongside the web. Listing accounts here limits that search to them — useful when you follow a specific crowd's opinions. Leave empty to search all of X."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Accounts:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
          TextField("@karpathy @simonw", text: $handleText)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: SettingsConstants.textFieldHeight)
            .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
            .onAppear {
              handleText = UserDefaults.standard.string(forKey: UserDefaultsKeys.grokXSearchHandles) ?? ""
            }
            .onChange(of: handleText) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.grokXSearchHandles)
            }

          Text("Separate with spaces or commas. Pasted profile URLs work too. Applies to new chats; type `/x` in a chat to change it there, `/x off` to search all of X.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          // xAI's filter is exclusive, so a stale list quietly starves every future answer.
          // Saying so here is cheaper than the user concluding the model has gone blind.
          if !parsed.handles.isEmpty {
            Text("Grok will read only these \(parsed.handles.count) account(s) on X: \(XSearchHandles.describe(parsed.handles)) — posts from anyone else stay invisible to it.")
              .font(.caption)
              .foregroundColor(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }

          if parsed.droppedOverCap > 0 {
            Text("xAI accepts at most \(XSearchHandles.maxHandles) accounts — the last \(parsed.droppedOverCap) will be ignored.")
              .font(.caption)
              .foregroundColor(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        Spacer()
      }
    }
  }
}
