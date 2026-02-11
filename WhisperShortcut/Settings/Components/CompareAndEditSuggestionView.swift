import SwiftUI

/// Reusable sheet view to compare current text with AI-suggested text and optionally apply or restore.
struct CompareAndEditSuggestionView: View {
  let title: String
  let currentText: String
  @Binding var suggestedText: String
  let onUseCurrent: () -> Void
  let onUseSuggested: (String) -> Void
  let hasPrevious: Bool
  var onRestorePrevious: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss

  private let editorHeight: CGFloat = 180

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      Text(title)
        .font(.headline)

      // Current (read-only)
      VStack(alignment: .leading, spacing: 6) {
        Text("Current")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
        ScrollView {
          Text(currentText.isEmpty ? " " : currentText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(8)
        }
        .scrollIndicators(.visible)
        .frame(height: editorHeight)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(SettingsConstants.cornerRadius)
        .overlay(
          RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
            .stroke(Color(.separatorColor), lineWidth: 1)
        )
      }

      // Suggested (editable)
      VStack(alignment: .leading, spacing: 6) {
        Text("Suggested (editable)")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
        TextEditor(text: $suggestedText)
          .font(.system(.callout, design: .monospaced))
          .frame(height: editorHeight)
          .padding(8)
          .background(Color(.controlBackgroundColor))
          .cornerRadius(SettingsConstants.cornerRadius)
          .overlay(
            RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
              .stroke(Color(.separatorColor), lineWidth: 1)
          )
      }

      HStack(spacing: 12) {
        Button("Use current") {
          onUseCurrent()
          dismiss()
        }
        .buttonStyle(.bordered)

        Button("Use suggested") {
          onUseSuggested(suggestedText)
          dismiss()
        }
        .buttonStyle(.borderedProminent)

        if hasPrevious, let onRestorePrevious {
          Button("Restore previous") {
            onRestorePrevious()
            dismiss()
          }
          .buttonStyle(.bordered)
        }

        Spacer()
      }
    }
    .padding(SettingsConstants.internalSectionSpacing)
    .frame(minWidth: 420, minHeight: 420)
  }
}
