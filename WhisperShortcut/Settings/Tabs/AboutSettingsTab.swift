import SwiftUI

/// About Settings Tab — information only, the macOS convention: what's new, support, and the
/// credits the licences require. Settings live where people look for them: Updates and
/// Data & Reset in General, the privacy promise in Privacy & Permissions, and the Welcome Tour in
/// the menu bar menu (plus the What's New card right after an update).
struct AboutSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      WhatsNewSection()

      SupportFeedbackSection(viewModel: viewModel)

      SpacedSectionDivider()

      acknowledgementsSection
    }
  }

  /// Credits the licences require. The Parakeet weights are CC BY 4.0, which asks for attribution
  /// wherever they are used — this is where a user of the app can see it.
  private var acknowledgementsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Acknowledgements")
        .font(.callout)
        .fontWeight(.medium)
      Text("Offline dictation: Parakeet Ultra by Moondream, a retraining of NVIDIA Parakeet TDT 0.6B v3, and NVIDIA Parakeet CTC 110M for Glossary terms — all licensed CC BY 4.0 — downloaded as FluidInference's Core ML conversions and run through FluidAudio (Apache 2.0). Whisper models by OpenAI (MIT), run through WhisperKit (MIT) by Argmax.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      HStack(spacing: 12) {
        Link("Parakeet Ultra", destination: URL(string: "https://huggingface.co/moondream/parakeet-ultra")!)
        Link("NVIDIA Parakeet", destination: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!)
        Link("FluidAudio", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
        Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
      }
      .font(.caption)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
