//
//  LaunchAtLoginSection.swift
//  WhisperShortcut
//

import SwiftUI

struct LaunchAtLoginSection: View {
  @ObservedObject var viewModel: SettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🚀 Startup",
        subtitle: "Automatically start WhisperShortcut when you log in"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Launch at Login:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: Binding(
          get: { viewModel.data.launchAtLogin },
          set: { newValue in
            viewModel.setLaunchAtLogin(newValue)
          }
        ))
        .toggleStyle(SwitchToggleStyle())

        Spacer()
      }
    }
  }
}
