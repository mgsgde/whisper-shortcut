import SwiftUI

/// Voice selection component for Read Aloud (Prompt Mode + Read Aloud)
struct ReadAloudVoiceSelectionView: View {
  @Binding var selectedVoice: String
  let onVoiceChanged: (() -> Void)?

  init(
    selectedVoice: Binding<String>,
    onVoiceChanged: (() -> Void)? = nil
  ) {
    self._selectedVoice = selectedVoice
    self.onVoiceChanged = onVoiceChanged
  }

  // Available Gemini TTS voices grouped by gender
  private struct Voice {
    let name: String
    let description: String
    let gender: Gender
    
    enum Gender {
      case male
      case female
    }
  }
  
  private let voices: [Voice] = [
    // Male voices
    Voice(name: "Charon", description: "Informative and clear", gender: .male),
    Voice(name: "Puck", description: "Lively and energetic", gender: .male),
    Voice(name: "Rasalgethi", description: "Informative and professional", gender: .male),
    Voice(name: "Orus", description: "Firm and decisive", gender: .male),
    Voice(name: "Iapetus", description: "Clear and articulate", gender: .male),
    // Female voices
    Voice(name: "Kore", description: "Warm and expressive", gender: .female),
    Voice(name: "Fenrir", description: "Confident and strong", gender: .female),
    Voice(name: "Pallas", description: "Professional and clear", gender: .female),
    Voice(name: "Aoede", description: "Melodic and pleasant", gender: .female),
    Voice(name: "Metis", description: "Calm and soothing", gender: .female),
  ]
  
  private var maleVoices: [Voice] {
    voices.filter { $0.gender == .male }
  }
  
  private var femaleVoices: [Voice] {
    voices.filter { $0.gender == .female }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔊 Read Aloud Voice",
        subtitle: "Select the voice for reading text aloud after prompt processing"
      )

      // Voice Selection Picker
      Picker("Voice", selection: $selectedVoice) {
        ForEach(voices, id: \.name) { voice in
          Text("\(voice.name) - \(voice.description)")
            .tag(voice.name)
        }
      }
      .pickerStyle(.menu)
      .onChange(of: selectedVoice) { _, _ in
        onVoiceChanged?()
      }
      
      // Voice categories info
      HStack(spacing: 16) {
        HStack(spacing: 4) {
          Text("Male:")
            .font(.caption)
            .foregroundColor(.secondary)
          Text(maleVoices.map { $0.name }.joined(separator: ", "))
            .font(.caption)
            .foregroundColor(.secondary)
        }
        HStack(spacing: 4) {
          Text("Female:")
            .font(.caption)
            .foregroundColor(.secondary)
          Text(femaleVoices.map { $0.name }.joined(separator: ", "))
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      
      // Selected voice description
      if let selectedVoiceInfo = voices.first(where: { $0.name == selectedVoice }) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Selected: \(selectedVoiceInfo.name)")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
          Text(selectedVoiceInfo.description)
            .font(.callout)
            .foregroundColor(.secondary)
        }
      }
    }
  }
}


