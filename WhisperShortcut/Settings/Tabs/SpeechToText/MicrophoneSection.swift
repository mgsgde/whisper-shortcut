import AVFoundation
import SwiftUI

/// Settings ▸ Dictate ▸ Microphone: which input Dictate, Dictate Prompt and Live Meeting record
/// from. "System default" follows macOS (Sound settings, Control Center) and is the default.
///
/// Hidden on a Mac with a single microphone and no stored choice: the default user on a MacBook
/// has nothing to pick, and CONTRIBUTING keeps rows out of the main view that they never need.
/// It appears as soon as a headset or dictation mic is plugged in, and stays while a choice is
/// stored, so an unplugged favourite can still be seen and reset. Includes its own trailing
/// divider so the parent does not leave an empty gap while the section is hidden.
struct MicrophoneSection: View {
  @AppStorage(UserDefaultsKeys.selectedMicrophoneUID) private var selectedUID = ""
  /// Name of the chosen device when it was chosen, so a disconnected choice is still named
  /// ("SpeechMike III, not connected") instead of a raw CoreAudio UID.
  @AppStorage(UserDefaultsKeys.selectedMicrophoneName) private var selectedName = ""
  @State private var devices: [AudioInputDeviceCatalog.InputDevice] = []
  @State private var defaultDeviceName: String?

  var body: some View {
    Group {
      if isVisible {
        VStack(alignment: .leading, spacing: 0) {
          content
          SpacedSectionDivider()
        }
      } else {
        Color.clear.frame(height: 0)
      }
    }
    .onAppear { refresh(after: 0) }
    .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
      refresh(after: 0.3)
    }
    .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
      refresh(after: 0.3)
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Microphone",
        systemImage: "mic",
        subtitle: "Which microphone Dictate and Live Meeting record from. System default follows the input chosen in macOS."
      )

      Picker("Microphone", selection: selection) {
        Text(systemDefaultLabel).tag("")
        Divider()
        ForEach(devices) { device in
          Text(verbatim: device.name).tag(device.uid)
        }
        if isChoiceMissing {
          Text("\(missingName) (not connected)").tag(selectedUID)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()

      if isChoiceMissing {
        SettingsCallout(
          symbol: "mic.slash",
          title: "\(missingName) is not connected",
          detail: "Recordings use the system default until it is plugged in again."
        ) {
          Button("Use System Default") { selection.wrappedValue = "" }
            .controlSize(.small)
        }
      }
    }
  }

  private var isVisible: Bool {
    devices.count >= 2 || !selectedUID.isEmpty
  }

  private var isChoiceMissing: Bool {
    !selectedUID.isEmpty && !devices.contains { $0.uid == selectedUID }
  }

  private var missingName: String {
    selectedName.isEmpty ? String(localized: "Selected microphone") : selectedName
  }

  /// "System default (MacBook Pro Microphone)": says what default means right now.
  private var systemDefaultLabel: String {
    guard let defaultDeviceName else { return String(localized: "System default") }
    return String(localized: "System default (\(defaultDeviceName))")
  }

  private var selection: Binding<String> {
    Binding(
      get: { selectedUID },
      set: { newValue in
        guard newValue != selectedUID else { return }
        let name = devices.first { $0.uid == newValue }?.name
        DebugLogger.log(
          "SETTINGS: Microphone set to \(newValue.isEmpty ? "system default" : "'\(name ?? "?")' (\(newValue))")")
        selectedUID = newValue
        selectedName = name ?? ""
        if newValue.isEmpty {
          // Remove the keys rather than storing "", so "not chosen" stays the absent default.
          MicrophoneSelection.selectedUID = nil
          UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedMicrophoneName)
        }
      })
  }

  /// CoreAudio publishes the new device list a moment after AVCaptureDevice announces a
  /// plug-in, so notification-driven refreshes wait briefly before reading it.
  private func refresh(after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      devices = AudioInputDeviceCatalog.availableDevices()
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      defaultDeviceName = AudioInputDeviceCatalog.defaultInputDeviceName()
    }
  }
}
