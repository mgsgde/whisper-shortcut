import SwiftUI

/// Wiederverwendbare Komponente für Playback Speed Control
struct PlaybackSpeedControl: View {
  @Binding var playbackSpeed: Double
  let onSpeedChanged: (() -> Void)?

  init(
    playbackSpeed: Binding<Double>,
    onSpeedChanged: (() -> Void)? = nil
  ) {
    self._playbackSpeed = playbackSpeed
    self.onSpeedChanged = onSpeedChanged
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔊 Playback Speed",
        subtitle: "Controls how fast the AI voice response is played"
      )

      HStack {
        Slider(value: $playbackSpeed, in: 0.25...2.0, step: 0.25) {
          Text("")
        }
        .frame(maxWidth: 300)
        .onChange(of: playbackSpeed) { _, _ in
          onSpeedChanged?()
        }

        Text("\(playbackSpeed, specifier: "%.2f")x")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: 50, alignment: .leading)
      }
    }
  }
}

#if DEBUG
  struct PlaybackSpeedControl_Previews: PreviewProvider {
    static var previews: some View {
      @State var playbackSpeed: Double = 1.0

      PlaybackSpeedControl(playbackSpeed: $playbackSpeed)
        .padding()
        .frame(width: 600)
    }
  }
#endif
