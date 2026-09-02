import Foundation
import SwiftUI

/// "Try it" panel on the Done step: record a few seconds, transcribe, show the text.
/// Continue is never gated on this — a hung transcription must not trap the user.
struct OnboardingTryItPanel: View {
  @StateObject private var controller = OnboardingTryItController()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Try it")
        .font(.callout)
        .fontWeight(.semibold)
      Text("Record a few seconds and see the transcript here before you finish. You can skip this.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      switch controller.phase {
      case .idle:
        Button("Try dictation") { controller.start() }
          .buttonStyle(.borderedProminent)
          .pointerCursorOnHover()
      case .recording(let remaining):
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Recording… \(remaining)s")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
          Button("Stop") { controller.stopEarly() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursorOnHover()
        }
      case .transcribing:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Transcribing…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      case .success(let text):
        VStack(alignment: .leading, spacing: 6) {
          Label("It works", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
          Text(text.isEmpty ? "(no speech detected)" : text)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Button("Try again") { controller.reset() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursorOnHover()
        }
      case .failure(let message, let tab):
        VStack(alignment: .leading, spacing: 6) {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Button("Open Settings → \(tab.rawValue)") {
              SettingsManager.shared.showSettings(tab: tab)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursorOnHover()
            Button("Try again") { controller.reset() }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .pointerCursorOnHover()
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
    .onDisappear { controller.cancel() }
  }
}

final class OnboardingTryItController: ObservableObject, AudioRecorderDelegate {
  enum Phase: Equatable {
    case idle
    case recording(remaining: Int)
    case transcribing
    case success(String)
    case failure(String, SettingsTab)
  }

  @Published var phase: Phase = .idle

  private var recorder: AudioRecorder?
  private var countdownTask: Task<Void, Never>?
  private let speechService = SpeechService()
  private static let recordSeconds = 3

  func start() {
    guard phase == .idle || isRetryable else { return }
    phase = .recording(remaining: Self.recordSeconds)
    let recorder = AudioRecorder()
    recorder.delegate = self
    self.recorder = recorder
    recorder.startRecording()
    DebugLogger.log("ONBOARDING: try-it recording started")
  }

  func stopEarly() {
    countdownTask?.cancel()
    countdownTask = nil
    _ = recorder?.stopRecording()
  }

  func reset() {
    cancel()
    phase = .idle
  }

  func cancel() {
    countdownTask?.cancel()
    countdownTask = nil
    recorder?.cleanup()
    recorder = nil
  }

  private var isRetryable: Bool {
    switch phase {
    case .success, .failure: return true
    default: return false
    }
  }

  func audioRecorderDidBeginRecording() {
    DispatchQueue.main.async { [weak self] in
      self?.beginCountdown()
    }
  }

  private func beginCountdown() {
    countdownTask?.cancel()
    countdownTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for remaining in stride(from: Self.recordSeconds, through: 1, by: -1) {
        guard !Task.isCancelled else { return }
        self.phase = .recording(remaining: remaining)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      guard !Task.isCancelled else { return }
      _ = self.recorder?.stopRecording()
    }
  }

  func audioRecorderDidFinishRecording(audioURL: URL) {
    DispatchQueue.main.async { [weak self] in
      self?.transcribe(audioURL: audioURL)
    }
  }

  private func transcribe(audioURL: URL) {
    countdownTask?.cancel()
    countdownTask = nil
    phase = .transcribing
    DebugLogger.log("ONBOARDING: try-it transcribing")
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let text = try await self.speechService.transcribe(
          audioURL: audioURL,
          cancellable: false,
          reportsProgress: false
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phase = .success(trimmed)
        DebugLogger.log("ONBOARDING: try-it succeeded (\(trimmed.count) chars)")
      } catch {
        let message = SpeechErrorFormatter.formatForUser(error)
        let tab = Self.settingsTab(for: error, message: message)
        self.phase = .failure(message, tab)
        DebugLogger.logError("ONBOARDING: try-it failed: \(error.localizedDescription)")
      }
      try? FileManager.default.removeItem(at: audioURL)
      self.recorder = nil
    }
  }

  func audioRecorderDidFailWithError(_ error: Error) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.countdownTask?.cancel()
      self.countdownTask = nil
      let message = SpeechErrorFormatter.formatForUser(error)
      self.phase = .failure(message, .permissions)
      DebugLogger.logError("ONBOARDING: try-it record failed: \(error.localizedDescription)")
      self.recorder = nil
    }
  }

  private static func settingsTab(for error: Error, message: String) -> SettingsTab {
    let combined = (error.localizedDescription + " " + message).lowercased()
    if combined.contains("microphone") || combined.contains("permission") {
      return .permissions
    }
    if combined.contains("offline") || combined.contains("whisper") || combined.contains("model")
      || combined.contains("download")
    {
      return .speechToText
    }
    if combined.contains("api key") || combined.contains("credential") || combined.contains("keychain")
    {
      return .general
    }
    return .speechToText
  }
}
