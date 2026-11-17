import SwiftUI

extension Notification.Name {
  /// Posted on the main thread after a plain dictation's text was copied (and pasted, when
  /// auto-paste ran). `userInfo["text"]` holds the result. The onboarding test field listens for
  /// it, so the test also succeeds where nothing is pasted (App Store build, auto-paste off).
  static let dictationResultDelivered = Notification.Name("dictationResultDelivered")
}

/// The onboarding test, done the way the app is used afterwards: press the real start key, see the
/// real pill, and watch the text land in a text field (UX review 2026-11-17). The button test it
/// replaced proved the microphone and the model but never the key or the paste, which are what
/// the first real dictation in another app needs.
///
/// The old `OnboardingTryItPanel` stays one click away ("Use a button instead") and is shown
/// directly when no start key works yet.
struct RealKeyTryIt: View {
  let startKey: DictationOnlyStartKey
  /// Seconds and caption for the button fallback.
  var fallbackRecordSeconds: Int = OnboardingTryItController.defaultRecordSeconds
  var fallbackCaption: LocalizedStringKey?
  var onSuccess: () -> Void

  @State private var text = ""
  @State private var showsButtonTest = false
  @FocusState private var fieldFocused: Bool

  /// How long a pasted result has to arrive before the delivered text is written in directly.
  /// The paste lands about 0.3 s after copy (`AppConstants.autoPastePreDelay` plus the chord).
  private static let pasteGrace: Duration = .milliseconds(900)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if startKey == .none || showsButtonTest {
        OnboardingTryItPanel(
          recordSeconds: fallbackRecordSeconds,
          caption: fallbackCaption,
          onSuccess: onSuccess)
      } else {
        field
        HStack(spacing: 6) {
          Text("Key not working?")
            .foregroundStyle(.secondary)
          Button("Test with a button instead") { showsButtonTest = true }
            .buttonStyle(.link)
            .pointerCursorOnHover()
        }
        .font(.caption)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .dictationResultDelivered)) { note in
      guard !showsButtonTest, startKey != .none,
        let delivered = (note.userInfo?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !delivered.isEmpty
      else { return }
      Task { @MainActor in
        try? await Task.sleep(for: Self.pasteGrace)
        // Pasted already (the field had focus): nothing to do. Otherwise write it in, so the
        // test shows its result where nothing is pasted.
        if !text.contains(delivered) {
          text = text.isEmpty ? delivered : text + " " + delivered
        }
      }
    }
    .onChange(of: text) { _, newValue in
      if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        onSuccess()
      }
    }
  }

  private var field: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $text)
        .font(.title3)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .focused($fieldFocused)
        .padding(8)
      if text.isEmpty {
        Text("Your text appears here.")
          .font(.title3)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 13)
          .padding(.vertical, 8)
          .allowsHitTesting(false)
      }
    }
    // Full width, so its edges line up with the sentence card above it.
    .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96)
    .cardChrome()
    .onAppear {
      // Focus after the step transition, or the field loses it to the window's first responder.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { fieldFocused = true }
    }
  }
}

/// The instruction above the test field, by start key. Key names as printed on the keys.
enum RealKeyTryItCopy {
  static func instruction(for startKey: DictationOnlyStartKey) -> LocalizedStringKey {
    switch startKey {
    case .fn:
      return "Press 🌐, read the sentence aloud, then press 🌐 again."
    case .shortcut(let keys):
      return "Press \(DictationOnlyKeyNames.spell(keys)) together, read the sentence aloud, then press them again."
    case .none:
      return "Click “Try dictation” and read this sentence aloud:"
    }
  }

  /// For the full tour, which has no sentence to read.
  static func freeInstruction(for startKey: DictationOnlyStartKey) -> LocalizedStringKey {
    switch startKey {
    case .fn:
      return "Press 🌐, say a sentence, then press 🌐 again. It works the same in every app."
    case .shortcut(let keys):
      return "Press \(DictationOnlyKeyNames.spell(keys)) together, say a sentence, then press them again. It works the same in every app."
    case .none:
      return "Say a sentence."
    }
  }

  /// The start key as the app sees it right now. Same rule as the last screen of the tour.
  static func currentStartKey(fnEnabled: Bool, globeConflict: Bool, accessibilityGranted: Bool) -> DictationOnlyStartKey {
    let shortcut = ShortcutConfigManager.shared.loadConfiguration()[keyPath: ShortcutAction.dictate.keyPath]
    return DictationOnlyStartKey.resolve(
      isAppStore: DictationOnlyDefaults.isAppStoreBuild, fnEnabled: fnEnabled,
      globeConflict: globeConflict, accessibilityGranted: accessibilityGranted,
      dictateShortcut: shortcut.isEnabled ? shortcut.displayString : nil)
  }
}
