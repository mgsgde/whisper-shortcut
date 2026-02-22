//
//  RecordingSafeguardsSection.swift
//  WhisperShortcut
//

import SwiftUI

struct RecordingSafeguardsSection: View {
  @ObservedObject var viewModel: SettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🛡️ Recording Safeguards",
        subtitle: "Ask before processing long recordings to avoid accidental API usage"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Ask when recording longer than:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.confirmAboveDuration) {
          ForEach(ConfirmAboveDuration.allCases, id: \.rawValue) { duration in
            HStack {
              Text(duration.displayName)
              if duration.isRecommended {
                Text("(Recommended)")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
            .tag(duration)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.confirmAboveDuration) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Spacer()
      }
    }
  }
}
