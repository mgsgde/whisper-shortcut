//
//  PopupNotificationsSection.swift
//  WhisperShortcut
//

import SwiftUI

struct PopupNotificationsSection: View {
  @ObservedObject var viewModel: SettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔔 Popup Notifications",
        subtitle: "Show popup windows with transcription and AI response text"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Show Notifications:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: $viewModel.data.showPopupNotifications)
          .toggleStyle(SwitchToggleStyle())
          .onChange(of: viewModel.data.showPopupNotifications) { _, _ in
            Task {
              await viewModel.saveSettings()
            }
          }

        Spacer()
      }

      HStack(alignment: .center, spacing: 16) {
        Text("Position:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.notificationPosition) {
          ForEach(NotificationPosition.allCases, id: \.rawValue) { position in
            Text(position.displayName)
              .tag(position)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.notificationPosition) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Spacer()
      }

      HStack(alignment: .center, spacing: 16) {
        Text("Duration:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.notificationDuration) {
          ForEach(NotificationDuration.allCases, id: \.rawValue) { duration in
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
        .onChange(of: viewModel.data.notificationDuration) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Spacer()
      }

      Text(
        "When enabled, popup windows will appear showing the transcribed text, AI responses, and voice response text."
      )
      .font(.callout)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
