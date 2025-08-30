import SwiftUI

/// Wiederverwendbare Komponente für Playback Speed Control
struct PlaybackSpeedControl: View {
  @Binding var playbackSpeed: Double

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.sectionSpacing) {
      SectionHeader(
        title: "Playback Speed",
        subtitle: "Controls how fast the AI voice response is played"
      )

      HStack {
        Text("Speed:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Slider(value: $playbackSpeed, in: 0.25...2.0, step: 0.25) {
          Text("Playback Speed")
        }
        .frame(maxWidth: 300)

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
