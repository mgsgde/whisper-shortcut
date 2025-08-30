import SwiftUI

/// Wiederverwendbare Komponente für Playback Speed Control
struct PlaybackSpeedControl: View {
  @Binding var playbackSpeed: Double
  
  private let speedOptions: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
  
  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.sectionSpacing) {
      SectionHeader(
        title: "Playback Speed",
        subtitle: "Controls how fast the AI voice response is played"
      )
      
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Speed:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          
          Slider(value: $playbackSpeed, in: 0.25...2.0, step: 0.25) {
            Text("Playback Speed")
          } minimumValueLabel: {
            Text("0.25x")
              .font(.caption)
              .foregroundColor(.secondary)
          } maximumValueLabel: {
            Text("2.0x")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .frame(maxWidth: 300)
          
          Text("\(playbackSpeed, specifier: "%.2f")x")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: 50, alignment: .leading)
        }
        
        // Quick preset buttons
        HStack(spacing: 8) {
          Text("Presets:")
            .font(.callout)
            .foregroundColor(.secondary)
            .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          
          ForEach(speedOptions, id: \.self) { speed in
            Button("\(speed, specifier: speed == 1.0 ? "%.0f" : "%.2f")x") {
              playbackSpeed = speed
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(playbackSpeed == speed)
          }
          
          Spacer()
        }
        
        Text("💡 1.0x is normal speed. Higher values play faster, lower values play slower.")
          .font(.callout)
          .foregroundColor(.secondary)
          .padding(.top, 4)
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
