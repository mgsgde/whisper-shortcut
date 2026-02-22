//
//  UserContextSection.swift
//  WhisperShortcut
//

import SwiftUI

struct UserContextSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var userContextText: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      PromptTextEditor(
        title: "🧠 User Context",
        subtitle: "Optional. Describe your language, topics, and style. Included in Dictate Prompt and Dictate Prompt & Read system prompts.",
        helpText: "This text is appended to the system prompt in prompt modes when non-empty. Leave empty to use no extra context.",
        defaultValue: "",
        text: $userContextText,
        focusedField: .userContext,
        currentFocus: $focusedField,
        onTextChanged: {
          saveUserContextToFile()
        }
      )
    }
    .onAppear {
      loadUserContextFromFile()
    }
    .onReceive(NotificationCenter.default.publisher(for: .userContextFileDidUpdate)) { _ in
      loadUserContextFromFile()
    }
  }

  private func loadUserContextFromFile() {
    let contextDir = UserContextLogger.shared.directoryURL
    let fileURL = contextDir.appendingPathComponent("user-context.md")
    userContextText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
  }

  private func saveUserContextToFile() {
    let contextDir = UserContextLogger.shared.directoryURL
    if !FileManager.default.fileExists(atPath: contextDir.path) {
      try? FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
    }
    let fileURL = contextDir.appendingPathComponent("user-context.md")
    if userContextText.isEmpty {
      try? FileManager.default.removeItem(at: fileURL)
    } else {
      try? userContextText.write(to: fileURL, atomically: true, encoding: .utf8)
    }
  }
}
