import Foundation
import SwiftUI

/// "Try it" panel on its own onboarding step, right after the microphone permission: record a few
/// seconds, transcribe, show the text.
/// Continue is never gated on this — a hung transcription must not trap the user.
struct OnboardingTryItPanel: View {
  @StateObject private var controller: OnboardingTryItController
  /// Replaces the default caption. "Dictation only" puts its own instruction above the panel.
  private let caption: LocalizedStringKey?
  private let onSuccess: (() -> Void)?
  /// False where the screen's Continue is already the primary button (the Glossary retry).
  private let prominentStart: Bool

  /// `recordSeconds`: 3 in the full tour (a quick check), about 8 on the "Dictation only" test
  /// step, where a whole sentence with spoken punctuation is read aloud.
  init(
    recordSeconds: Int = OnboardingTryItController.defaultRecordSeconds,
    caption: LocalizedStringKey? = nil,
    prominentStart: Bool = true,
    onSuccess: (() -> Void)? = nil
  ) {
    _controller = StateObject(wrappedValue: OnboardingTryItController(recordSeconds: recordSeconds))
    self.caption = caption
    self.prominentStart = prominentStart
    self.onSuccess = onSuccess
  }

  /// The instruction is for before and during the recording; once it has stopped ("click Stop
  /// when you're done" over the model preparation, or next to a result) it is stale.
  private var showsCaption: Bool {
    switch controller.phase {
    case .idle, .recording: return true
    case .preparing, .transcribing, .success, .failure: return false
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsCaption {
        Text(caption ?? "Record a few seconds and see the transcript here. You can skip this.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      switch controller.phase {
      case .idle:
        let start = Button("Try dictation") { controller.start() }
          .pointerCursorOnHover()
        if prominentStart {
          start.buttonStyle(.borderedProminent)
        } else {
          start.buttonStyle(.bordered).controlSize(.large)
        }
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
      case .preparing:
        // The first load of an offline model compiles it for this Mac (~30 s for Parakeet). A
        // bare "Transcribing…" for that long reads as a hang on the one screen meant to build trust.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          ProgressView().controlSize(.small)
          VStack(alignment: .leading, spacing: 2) {
            Text("Preparing speech recognition…")
              .font(.caption)
            Text("Only the first time. This can take up to a minute.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
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
          Text(text.isEmpty ? String(localized: "(no speech detected)") : text)
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
            Button("Open Settings → \(String(localized: tab.displayName))") {
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
    .cardChrome()
    .onDisappear { controller.cancel() }
    .onChange(of: controller.phase) { _, phase in
      if case .success(let text) = phase, !text.isEmpty { onSuccess?() }
    }
  }
}

final class OnboardingTryItController: ObservableObject, AudioRecorderDelegate {
  enum Phase: Equatable {
    case idle
    case recording(remaining: Int)
    /// The offline model is not in memory yet; its first load (a one-time compile) runs first.
    case preparing
    case transcribing
    case success(String)
    case failure(String, SettingsTab)
  }

  @Published var phase: Phase = .idle

  private var recorder: AudioRecorder?
  private var countdownTask: Task<Void, Never>?
  private let speechService = SpeechService()
  static let defaultRecordSeconds = 3
  let recordSeconds: Int

  init(recordSeconds: Int = OnboardingTryItController.defaultRecordSeconds) {
    self.recordSeconds = max(1, recordSeconds)
  }

  func start() {
    guard phase == .idle || isRetryable else { return }
    phase = .recording(remaining: recordSeconds)
    // Test profile only (`--audio-file`): transcribe a recording instead of the microphone.
    if let path = TestProfileOverrides.current.audioFile {
      startFromFile(path)
      return
    }
    let recorder = AudioRecorder()
    recorder.delegate = self
    self.recorder = recorder
    recorder.startRecording()
    DebugLogger.log("ONBOARDING: try-it recording started")
  }

  /// Copies the file (`transcribe` deletes what it is given), shows a short countdown, transcribes.
  private func startFromFile(_ path: String) {
    let copy = FileManager.default.temporaryDirectory
      .appendingPathComponent("try-it-\(UUID().uuidString).\((path as NSString).pathExtension)")
    do {
      try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
    } catch {
      phase = .failure(error.localizedDescription, .speechToText)
      return
    }
    DebugLogger.log("ONBOARDING: try-it from a test-profile audio file")
    countdownTask?.cancel()
    countdownTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for remaining in stride(from: self.recordSeconds, through: max(1, self.recordSeconds - 1), by: -1) {
        guard !Task.isCancelled else { return }
        self.phase = .recording(remaining: remaining)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
      guard !Task.isCancelled else { return }
      self.transcribe(audioURL: copy)
    }
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
      for remaining in stride(from: self.recordSeconds, through: 1, by: -1) {
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
        let model = TranscriptionModel.loadSelected()
        try await self.waitForOfflineModel(model)
        let punctuation = PunctuationMode.effective(
          stored: .current, isOffline: model.isOffline, duringMeeting: false)
        let raw = try await self.speechService.transcribe(
          audioURL: audioURL,
          cancellable: false,
          reportsProgress: false,
          punctuationMode: punctuation
        )
        let text = Self.applySpokenPunctuation(raw, model: model, mode: punctuation)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phase = .success(trimmed)
        DebugLogger.log("ONBOARDING: try-it succeeded (\(trimmed.count) chars)")
      } catch {
        let message = SpeechErrorFormatter.formatForUser(error)
        // "Dictation only" hides Accounts; the button then names the tab it really opens.
        let tab = DictationOnlyMode.reachableTab(
          Self.settingsTab(for: error, message: message), enabled: DictationOnlyMode.isEnabled)
        self.phase = .failure(message, tab)
        DebugLogger.logError("ONBOARDING: try-it failed: \(error.logDescription)")
      }
      try? FileManager.default.removeItem(at: audioURL)
      self.recorder = nil
    }
  }

  /// Loads a downloaded offline model that is not in memory yet under its own phase, so the wait
  /// is explained instead of hidden in "Transcribing…". Joins the onboarding's warm-up if that is
  /// still running (`initializeModel` is single-flight).
  private func waitForOfflineModel(_ model: TranscriptionModel) async throws {
    guard let offline = model.offlineModelType,
      ModelManager.shared.isModelAvailable(offline),
      !(await LocalSpeechService.shared.isLoaded(modelType: offline))
    else { return }
    phase = .preparing
    let start = Date()
    try await LocalSpeechService.shared.initializeModel(offline)
    DebugLogger.log(
      "ONBOARDING: try-it waited \(Int(Date().timeIntervalSince(start) * 1000)) ms for \(offline.displayName)")
    phase = .transcribing
  }

  func audioRecorderDidFailWithError(_ error: Error) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.countdownTask?.cancel()
      self.countdownTask = nil
      let message = SpeechErrorFormatter.formatForUser(error)
      self.phase = .failure(message, .permissions)
      DebugLogger.logError("ONBOARDING: try-it record failed: \(error.logDescription)")
      self.recorder = nil
    }
  }

  /// The same post-processing real dictation does (`MenuBarController`): offline engines write a
  /// spoken "Komma" out as a word. Without it the test showed "Komma" where dictation later puts
  /// ",", so the one screen meant to build trust showed a result the app never produces.
  static func applySpokenPunctuation(
    _ transcript: String, model: TranscriptionModel, mode: PunctuationMode
  ) -> String {
    guard model.isOffline else { return transcript }
    let timedMarks = model.offlineModelType?.engine == .parakeet
    let source =
      mode == .spokenOnly
      ? SpokenPunctuation.stripModelPunctuation(from: transcript, timedMarks: timedMarks)
      : transcript
    return SpokenPunctuation.apply(to: source, mode: mode, timedMarks: timedMarks)
  }

  /// Where a failed try-it recording should send the user in Settings.
  ///
  /// Credential messages from `ProviderCredentials.missingKeyMessage` all contain "model"
  /// ("to use OpenAI models"), and this used to test "model" before "api key", so a missing
  /// key opened Dictate instead of Accounts.
  static func settingsTab(for error: Error, message: String) -> SettingsTab {
    let combined = (error.localizedDescription + " " + message).lowercased()
    if combined.contains("microphone") || combined.contains("permission") {
      return .permissions
    }
    if combined.contains("settings → accounts") || combined.contains("api key")
      || combined.contains("credential") || combined.contains("keychain")
      || combined.contains("sign in")
    {
      return .accounts
    }
    if combined.contains("offline") || combined.contains("whisper") || combined.contains("model")
      || combined.contains("download")
    {
      return .speechToText
    }
    return .speechToText
  }
}
