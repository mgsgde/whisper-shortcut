//
//  DictationOnlySteps.swift
//  WhisperShortcut
//
//  The screens of the Welcome Tour's first question and of its "Dictation only" path. Written for
//  someone who sets this up alone and has never used a menu-bar app: one task per screen, one
//  primary button, plain words, the next thing said out loud. Decisions live in
//  DictationOnlyOnboarding.swift; WelcomeView navigates.
//

import AppKit
import SwiftUI

/// Text sizes on these screens: one step up from the full tour, which uses captions throughout.
private enum DictationOnlyFont {
  static let body: Font = .body
  static let note: Font = .callout
}

// MARK: - First screen

/// "How do you want to use WhisperShortcut?" Two cards; Continue in the footer commits the choice.
struct WelcomeModeChoiceStep: View {
  @Binding var choice: OnboardingModeChoice?
  /// The last Continue was refused because a recording or meeting is running.
  var refused: Bool

  var body: some View {
    VStack(spacing: 22) {
      VStack(spacing: 8) {
        Text("Welcome to WhisperShortcut")
          .font(.largeTitle)
          .fontWeight(.semibold)
        Text("How do you want to use WhisperShortcut?")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center)

      HStack(alignment: .top, spacing: 14) {
        card(
          .dictationOnly,
          icon: "mic",
          title: "Dictation only",
          facts: [
            Self.deliveryFact,
            "Works without internet. Nothing leaves this Mac.",
            "No account needed.",
          ])
        card(
          .allFeatures,
          icon: "square.grid.2x2",
          title: "All features",
          facts: [
            "Dictation plus AI that rewrites your text.",
            "Chat with AI and notes from meetings.",
            "More to set up.",
          ])
      }
      .frame(maxWidth: 620)

      if refused {
        Label(
          "Not possible right now: a recording or meeting is running. Try again when it has finished.",
          systemImage: "exclamationmark.circle"
        )
        .font(DictationOnlyFont.note)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("You can change this later in Settings → General.")
          .font(DictationOnlyFont.note)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// The App Store build cannot paste at the cursor, so it never promises it.
  private static var deliveryFact: LocalizedStringKey {
    #if APP_STORE
    return "Press a key, speak, and the text is copied. Paste it with ⌘V."
    #else
    return "Press a key, speak, and the text appears where your cursor is."
    #endif
  }

  private func card(
    _ value: OnboardingModeChoice, icon: String, title: LocalizedStringKey, facts: [LocalizedStringKey]
  ) -> some View {
    let selected = choice == value
    return Button {
      choice = value
    } label: {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          Image(systemName: icon)
            .font(.system(size: 24))
            .foregroundStyle(.tint)
            .frame(width: 30)
          Text(title)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
          Spacer(minLength: 4)
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text("•").foregroundStyle(.secondary)
              Text(fact)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(DictationOnlyFont.note)
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
      .cardChrome(
        fill: selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
        stroke: selected ? Color.accentColor : Color(nsColor: .separatorColor),
        lineWidth: selected ? 2 : 1)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointerCursorOnHover()
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

// MARK: - 🌐 key

/// Shown only while macOS still uses the 🌐 key itself (direct build). One button frees it; the
/// numbered path below does the same by hand, and the screen re-checks when the person returns.
struct DictationOnlyGlobeKeyStep: View {
  @ObservedObject private var status = GlobeKeyStatus.shared
  @AppStorage(UserDefaultsKeys.fnKeyDictation) private var fnEnabled = SettingsDefaults.fnKeyDictation
  /// The one-click change did not stick; the numbered path is now the way.
  @State private var freeFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      WelcomeStepHeader(
        systemImage: "globe",
        title: "The 🌐 key",
        subtitle: "The easiest way to dictate is the 🌐 key at the bottom left of your keyboard. On this Mac it still does something else.")

      if let systemAction = status.usage.systemSettingsLabel {
        VStack(alignment: .leading, spacing: 14) {
          Text("Right now the 🌐 key opens “\(systemAction)”.")
            .font(DictationOnlyFont.body)
            .fixedSize(horizontal: false, vertical: true)

          #if !APP_STORE
          Button(action: freeKey) {
            Text("Use the 🌐 key for dictation")
              .padding(.horizontal, 6)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .pointerCursorOnHover()
          #endif

          if freeFailed {
            Label("macOS did not accept the change. Please change it yourself as shown below.", systemImage: "exclamationmark.circle")
              .font(DictationOnlyFont.note)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }

          manualPath
        }
      } else {
        Label("The 🌐 key is free. Press it once to start dictating and once more to stop.", systemImage: "checkmark.circle.fill")
          .font(DictationOnlyFont.body)
          .foregroundStyle(.green)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text("You can also skip this and start dictation with a key combination instead.")
        .font(DictationOnlyFont.note)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear { status.refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      status.refresh()
    }
    .onChange(of: status.usage) { _, usage in
      // Freed here or in System Settings: the key is now meant for dictation.
      if usage == .doNothing {
        fnEnabled = true
        freeFailed = false
        DebugLogger.log("ONBOARDING: dictation-only, 🌐 key free, Fn dictation on")
      }
    }
  }

  private var manualPath: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Or change it yourself:")
        .font(DictationOnlyFont.note)
        .fontWeight(.semibold)
      numbered(1) {
        HStack(spacing: 8) {
          Text("Open the keyboard settings:")
          Button("Open Keyboard Settings") { GlobeKeyUsage.openKeyboardSettings() }
            .buttonStyle(.bordered)
            .pointerCursorOnHover()
        }
      }
      numbered(2) { Text("Find “Press 🌐 key to”.") }
      numbered(3) { Text("Choose “Do Nothing”.") }
      numbered(4) { Text("Come back to this window. It checks again by itself.") }
    }
    .font(DictationOnlyFont.note)
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardChrome()
  }

  private func numbered<Content: View>(_ number: Int, @ViewBuilder _ content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: "\(number).")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 18, alignment: .trailing)
      content()
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  #if !APP_STORE
  private func freeKey() {
    if GlobeKeyUsage.freeForFnDictation() {
      freeFailed = false
    } else {
      DebugLogger.logWarning("ONBOARDING: dictation-only, 🌐 change did not stick; opening Keyboard settings")
      freeFailed = true
      GlobeKeyUsage.openKeyboardSettings()
    }
    status.refresh()
  }
  #endif
}

// MARK: - Language

/// The dictation language, shown with a way to change it. No Auto-detect: the offline model
/// needs to know, and spoken punctuation depends on it.
struct DictationOnlyLanguageStep: View {
  @AppStorage(UserDefaultsKeys.whisperLanguage) private var language: WhisperLanguage =
    SettingsDefaults.whisperLanguage

  static let model = OfflineModelType.parakeetUltra

  /// A language the offline model can recognise. Continue waits for it.
  static func isUsable(_ language: WhisperLanguage) -> Bool {
    language != .auto && model.supports(language)
  }

  private var options: [WhisperLanguage] {
    WhisperLanguage.allCases.filter { $0 != .auto && Self.model.supports($0) }
  }

  /// Nil while nothing usable is chosen, so the menu shows "Choose…".
  private var selection: Binding<WhisperLanguage?> {
    Binding(
      get: { Self.isUsable(language) ? language : nil },
      set: { picked in
        guard let picked else { return }
        language = picked
        UserDefaults.standard.set(
          DictationOnlyDefaults.punctuation(for: picked).rawValue, forKey: UserDefaultsKeys.punctuationMode)
        DebugLogger.log("ONBOARDING: dictation-only language \(picked.rawValue)")
      })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      WelcomeStepHeader(
        systemImage: "character.bubble",
        title: "Your language",
        subtitle: "The language you dictate in.")

      HStack(spacing: 10) {
        Text("I dictate in:")
          .font(DictationOnlyFont.body)
        Picker("I dictate in:", selection: selection) {
          if selection.wrappedValue == nil {
            Text("Choose…").tag(WhisperLanguage?.none)
          }
          ForEach(options, id: \.self) { option in
            Text(option.displayName).tag(WhisperLanguage?.some(option))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.large)
        .fixedSize()
        Spacer(minLength: 0)
      }

      if let picked = selection.wrappedValue {
        Text(DictationOnlyTestSentence.usesSpokenPunctuation(picked)
          ? ("Say punctuation out loud, for example “Komma”, “Punkt” or “neuer Absatz”." as LocalizedStringKey)
          : "Punctuation is added automatically.")
          .font(DictationOnlyFont.note)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Label("Please choose the language you dictate in.", systemImage: "exclamationmark.circle")
          .font(DictationOnlyFont.note)
          .foregroundStyle(.orange)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

// MARK: - Permissions

/// The microphone, then (direct build) Accessibility so the text can land at the cursor.
struct DictationOnlyPermissionsStep: View {
  @Binding var micStatus: PermissionStatus
  @Binding var axStatus: PermissionStatus
  /// Asked for Accessibility from here; on the way back without it, the drag fallback shows.
  @State private var requestedAccessibility = false
  @State private var returnedWithoutGrant = false

  private static var asksForAccessibility: Bool { !DictationOnlyDefaults.isAppStoreBuild }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      WelcomeStepHeader(
        systemImage: "checkmark.shield",
        title: "Allow access",
        subtitle: Self.asksForAccessibility
          ? "macOS asks you to allow two things. WhisperShortcut needs both."
          : "macOS asks you to allow the microphone.")

      permissionRow(
        number: 1,
        title: "Microphone",
        detail: "So WhisperShortcut can hear you. What you say stays on this Mac.",
        status: micStatus,
        isNext: micStatus != .granted,
        allow: requestMicrophone)

      if Self.asksForAccessibility {
        permissionRow(
          number: 2,
          title: "Accessibility",
          detail: "So the text can appear where your cursor is.",
          status: axStatus,
          isNext: micStatus == .granted && axStatus != .granted,
          allow: requestAccessibility)

        if axStatus != .granted {
          Text("macOS may then ask for your password or Touch ID. That request comes from macOS, not from WhisperShortcut.")
            .font(DictationOnlyFont.note)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if returnedWithoutGrant && axStatus != .granted {
          AccessibilityDragFallback()
        }
      }

      if micStatus == .denied {
        Label("The microphone is switched off. You can continue and allow it later in System Settings.", systemImage: "exclamationmark.circle")
          .font(DictationOnlyFont.note)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear(perform: refresh)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      if requestedAccessibility { returnedWithoutGrant = true }
      refresh()
    }
  }

  private func permissionRow(
    number: Int, title: LocalizedStringKey, detail: LocalizedStringKey, status: PermissionStatus,
    isNext: Bool, allow: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .center, spacing: 14) {
      // Numbered only when there are two, so the order reads at a glance.
      if Self.asksForAccessibility {
        Text(verbatim: "\(number)")
          .font(.headline)
          .foregroundStyle(.secondary)
          .frame(width: 22)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(DictationOnlyFont.note)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      if status == .granted {
        Label("Allowed", systemImage: "checkmark.circle.fill")
          .font(DictationOnlyFont.note)
          .foregroundStyle(.green)
      } else {
        let button = Button(action: allow) {
          Text(status == .denied ? "Open System Settings" : "Allow")
            .padding(.horizontal, 4)
        }
        .controlSize(.large)
        .pointerCursorOnHover()
        if isNext {
          button.buttonStyle(.borderedProminent)
        } else {
          button.buttonStyle(.bordered)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardChrome()
  }

  private func requestMicrophone() {
    if micStatus == .denied {
      PermissionStatusChecker.requestThenOpenSystemSettings(for: .microphone)
      refresh()
      return
    }
    PermissionStatusChecker.requestMicrophoneAccess { _ in refresh() }
  }

  private func requestAccessibility() {
    if requestedAccessibility { returnedWithoutGrant = true }
    requestedAccessibility = true
    AccessibilityPermissionManager.requestAccessibilityAtOptIn(for: .autoPaste)
    refresh()
  }

  private func refresh() {
    micStatus = PermissionStatusChecker.status(for: .microphone)
    axStatus = PermissionStatusChecker.status(for: .accessibility)
  }
}

// MARK: - Download

/// The one-time download. It started when "Dictation only" was chosen; this screen shows how far
/// it is. Only the test step waits for it, so Continue stays open.
struct DictationOnlyDownloadStep: View {
  static let model = OfflineModelType.parakeetUltra
  @ObservedObject private var modelManager = ModelManager.shared
  /// Set by the free-space check: (needed MB, free MB).
  @State private var shortOfSpace: (needed: Int, available: Int)?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      WelcomeStepHeader(
        systemImage: "arrow.down.circle",
        title: "One-time download",
        subtitle: "One-time download, about \(Self.model.estimatedSizeMB) MB. After that no internet is needed.")

      if let shortOfSpace {
        VStack(alignment: .leading, spacing: 10) {
          Label(
            "There is not enough free space on this Mac. About \(shortOfSpace.needed) MB is needed, but only \(shortOfSpace.available) MB is free. Delete files you no longer need, then click “Check again”.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(DictationOnlyFont.body)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          Button("Check again", action: checkSpace)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .pointerCursorOnHover()
        }
      } else {
        OfflineModelDownloadCard(modelType: Self.model, startsDownloadOnAppear: true, plainCopy: true)
        if !modelManager.isModelAvailable(Self.model) {
          Text("You can continue while it downloads.")
            .font(DictationOnlyFont.note)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear(perform: checkSpace)
  }

  /// Checked before the card can start a download. Skipped while one runs: the free space then
  /// shrinks because of the download itself.
  private func checkSpace() {
    guard !modelManager.isModelAvailable(Self.model),
      !modelManager.downloadingModels.contains(Self.model)
    else {
      shortOfSpace = nil
      return
    }
    do {
      try DiskSpace.require(estimatedSizeMB: Self.model.estimatedSizeMB, at: modelManager.rootDirectory)
      shortOfSpace = nil
    } catch DiskSpaceError.insufficient(let needed, let available) {
      shortOfSpace = (needed, available)
      DebugLogger.logWarning("ONBOARDING: dictation-only download blocked, \(available) MB free of \(needed) MB")
    } catch {
      shortOfSpace = nil
    }
  }
}

// MARK: - Test

/// Read one sentence aloud and see it typed. Waits for the download.
struct DictationOnlyTestStep: View {
  static let recordSeconds = 8
  var onSuccess: () -> Void

  @ObservedObject private var modelManager = ModelManager.shared
  @AppStorage(UserDefaultsKeys.whisperLanguage) private var language: WhisperLanguage =
    SettingsDefaults.whisperLanguage

  private var modelReady: Bool { modelManager.isModelAvailable(DictationOnlyDownloadStep.model) }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      WelcomeStepHeader(
        systemImage: "waveform",
        title: "Try it",
        subtitle: "Click “Try dictation” and read this sentence aloud:")

      Text(verbatim: DictationOnlyTestSentence.sentence(for: language))
        .font(.title3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardChrome(fill: Color.accentColor.opacity(0.08), stroke: Color.accentColor.opacity(0.35))

      if DictationOnlyTestSentence.usesSpokenPunctuation(language) {
        Text("“Komma” becomes a comma, “Punkt” a full stop.")
          .font(DictationOnlyFont.note)
          .foregroundStyle(.secondary)
      }

      if modelReady {
        OnboardingTryItPanel(
          recordSeconds: Self.recordSeconds,
          caption: "You have about \(Self.recordSeconds) seconds. Click “Stop” when you have finished.",
          onSuccess: onSuccess)
      } else {
        Text("The download is not finished yet. The test can start as soon as it is.")
          .font(DictationOnlyFont.note)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        OfflineModelDownloadCard(
          modelType: DictationOnlyDownloadStep.model, startsDownloadOnAppear: true, plainCopy: true)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

// MARK: - Glossary

/// Teach one word its spelling, then try again. Skippable.
struct DictationOnlyGlossaryStep: View {
  @State private var word = ""
  @State private var result: SystemPromptsStore.GlossaryAppendResult?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      WelcomeStepHeader(
        systemImage: "character.book.closed",
        title: "Did a word come out wrong?",
        subtitle: "Names and technical terms are sometimes misheard. Write the word the way it should be spelled, and WhisperShortcut will use that spelling.")

      HStack(spacing: 10) {
        TextField("For example a name or a technical term", text: $word)
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          .frame(maxWidth: 360)
          .onSubmit(save)
        Button("Save", action: save)
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .pointerCursorOnHover()
      }

      if let result {
        resultLine(result)
      }

      if case .added = result {
        Text("Try it again with that word:")
          .font(DictationOnlyFont.note)
          .foregroundStyle(.secondary)
        OnboardingTryItPanel(
          recordSeconds: DictationOnlyTestStep.recordSeconds,
          caption: "You have about \(DictationOnlyTestStep.recordSeconds) seconds. Click “Stop” when you have finished.")
      }

      Text("You can skip this. Later you find all your words in Settings → Dictate → Glossary.")
        .font(DictationOnlyFont.note)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func resultLine(_ result: SystemPromptsStore.GlossaryAppendResult) -> some View {
    switch result {
    case .added(let term):
      Label("Saved. From now on WhisperShortcut writes “\(term)”.", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(DictationOnlyFont.body)
    case .duplicate(let term):
      Label("“\(term)” is already saved.", systemImage: "checkmark.circle")
        .foregroundStyle(.secondary)
        .font(DictationOnlyFont.body)
    case .notATerm:
      Label("Please enter one word or name, not a sentence.", systemImage: "exclamationmark.circle")
        .foregroundStyle(.orange)
        .font(DictationOnlyFont.body)
    case .budgetExceeded:
      Label("The list of words is full. Remove a word in Settings → Dictate → Glossary first.", systemImage: "exclamationmark.circle")
        .foregroundStyle(.orange)
        .font(DictationOnlyFont.body)
    }
  }

  private func save() {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let outcome = SystemPromptsStore.shared.appendToWhisperGlossary(trimmed, source: .settings)
    result = outcome
    if case .added = outcome { word = "" }
    DebugLogger.log("ONBOARDING: dictation-only glossary save (\(outcome.logLabel))")
  }
}

private extension SystemPromptsStore.GlossaryAppendResult {
  /// For the log: the outcome without the word (dictations can be patient notes).
  var logLabel: String {
    switch self {
    case .added: return "added"
    case .duplicate: return "duplicate"
    case .notATerm: return "notATerm"
    case .budgetExceeded: return "budgetExceeded"
    }
  }
}

// MARK: - Done

/// Which key starts dictation, where the text goes, where the app lives, where the words are.
struct DictationOnlyDoneStep: View {
  @AppStorage(UserDefaultsKeys.fnKeyDictation) private var fnEnabled = SettingsDefaults.fnKeyDictation
  @AppStorage(UserDefaultsKeys.dictateMode) private var dictateModeRaw = DictateMode.dictate.rawValue
  @ObservedObject private var globeKey = GlobeKeyStatus.shared
  @ObservedObject private var modelManager = ModelManager.shared
  @State private var micStatus = PermissionStatusChecker.status(for: .microphone)
  @State private var axStatus = PermissionStatusChecker.status(for: .accessibility)

  private var startKey: DictationOnlyStartKey {
    let shortcut = ShortcutConfigManager.shared.loadConfiguration()[keyPath: ShortcutAction.dictate.keyPath]
    return DictationOnlyStartKey.resolve(
      isAppStore: DictationOnlyDefaults.isAppStoreBuild, fnEnabled: fnEnabled,
      globeConflict: globeKey.usage.conflictsWithFnDictation,
      accessibilityGranted: axStatus == .granted,
      dictateShortcut: shortcut.isEnabled ? shortcut.displayString : nil)
  }

  private var delivery: DictationOnlyDelivery {
    DictationOnlyDelivery.resolve(
      isAppStore: DictationOnlyDefaults.isAppStoreBuild,
      dictateMode: DictateMode(rawValue: dictateModeRaw) ?? .dictate,
      appleSilicon: LiveDictation.isAppleSilicon,
      accessibilityGranted: axStatus == .granted,
      autoPaste: AutoPasteDefault.currentValue)
  }

  private var modelReady: Bool { modelManager.isModelAvailable(DictationOnlyDownloadStep.model) }
  private var ready: Bool { modelReady && micStatus == .granted && startKey != .none }

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
        .font(.system(size: 44))
        .foregroundStyle(ready ? .green : .orange)
      Text(ready ? ("You're ready" as LocalizedStringKey) : "Almost ready")
        .font(.largeTitle)
        .fontWeight(.semibold)

      VStack(alignment: .leading, spacing: 14) {
        line(icon: "keyboard", startLine)
        line(icon: "text.cursor", deliveryLine)
        line(icon: "menubar.rectangle", "WhisperShortcut lives in the menu bar at the top of your screen, as a small microphone.")
        line(icon: "character.book.closed", "Words that come out wrong: click the microphone in the menu bar, then Settings → Dictate → Glossary.")
      }
      .padding(18)
      .frame(maxWidth: 580, alignment: .leading)
      .cardChrome()

      if micStatus != .granted {
        Label("The microphone is not allowed yet. Allow it in System Settings → Privacy & Security → Microphone.", systemImage: "exclamationmark.circle")
          .font(DictationOnlyFont.note)
          .foregroundStyle(.orange)
          .frame(maxWidth: 580, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !modelReady {
        VStack(alignment: .leading, spacing: 8) {
          Text("The download is not finished yet. Dictation works as soon as it is.")
            .font(DictationOnlyFont.note)
            .foregroundStyle(.secondary)
          OfflineModelDownloadCard(
            modelType: DictationOnlyDownloadStep.model, startsDownloadOnAppear: true, plainCopy: true)
        }
        .frame(maxWidth: 580, alignment: .leading)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear(perform: refresh)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refresh()
    }
  }

  private var startLine: LocalizedStringKey {
    switch startKey {
    case .fn: return "To dictate, press the 🌐 key. Press it again to stop."
    case .shortcut(let keys): return "To dictate, press \(keys). Press it again to stop."
    case .none: return "Choose a key for dictation in Settings → General → Keyboard Shortcuts."
    }
  }

  private var deliveryLine: LocalizedStringKey {
    switch delivery {
    case .live: return "The text appears where your cursor is, while you speak."
    case .atCursor: return "The text then appears where your cursor is."
    case .copied: return "The text is then copied. Paste it with ⌘V."
    }
  }

  private func line(icon: String, _ text: LocalizedStringKey) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(.tint)
        .frame(width: 22)
      Text(text)
        .font(DictationOnlyFont.body)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func refresh() {
    micStatus = PermissionStatusChecker.status(for: .microphone)
    axStatus = PermissionStatusChecker.status(for: .accessibility)
    globeKey.refresh()
  }
}
