import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The configuration report is pasted into chats and mail, so what it may contain is the contract:
/// no free text in the base report, glossary and prompt texts only on request, never a key.
@Suite("Configuration report")
struct ConfigurationReportTests {

  private static let glossarySentinel = "SENTINEL-GLOSSARY-7C1D"
  private static let promptSentinel = "SENTINEL-DICTATION-4B8E"

  private static let environment = UsageReport.Environment(
    appVersion: "9.99", osVersion: "26.1", isAppStoreBuild: false)

  private static func fakeSettings() -> [MCPSetting] {
    func make(_ id: String, _ title: String, _ category: String, _ kind: MCPSetting.Kind, _ value: Any,
      unavailable: String? = nil) -> MCPSetting
    {
      MCPSetting(
        id: id, title: title, category: category, kind: kind, unavailableReason: { unavailable },
        read: { value }, validate: { _ in nil }, apply: { _ in })
    }
    return [
      // Never written to UserDefaults: the effective default must still be reported.
      make("dictation.model", "Dictation model", "models",
        .enumeration(options: { [MCPSetting.Option("gemini-default", "Gemini Default")] }), "gemini-default"),
      make("dictation.smart", "Smart thing", "dictation", .bool, true),
      make("hidden", "Hidden thing", "dictation", .bool, true, unavailable: "no"),
    ]
  }

  private func render(_ options: ConfigurationReport.Options) throws -> String {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("config-report-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SystemPromptsStore(contextDirectoryURL: dir)
    #expect(store.updateSection(.dictation, content: "Please keep it short. \(Self.promptSentinel)", source: .settings))
    #expect(store.updateSection(.whisperGlossary, content: "Foo\n\(Self.glossarySentinel)", source: .settings))

    let suite = "config-report-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("sk-should-never-appear", forKey: "someApiKey")

    return ConfigurationReport.build(
      options, store: store, defaults: defaults, environment: Self.environment,
      settings: Self.fakeSettings())
  }

  @Test("Base report has models, shortcuts and customized flags but no user text")
  func baseReport() throws {
    let report = try render(.init())
    #expect(report.hasPrefix("WhisperShortcut configuration\nApp 9.99 (direct build) · macOS 26.1"))
    #expect(report.contains("### models\nDictation model: Gemini Default"))
    #expect(report.contains("### dictation\nSmart thing: On"))
    #expect(!report.contains("Hidden thing"))
    #expect(report.contains("whisper_glossary: customized,"))
    #expect(report.contains("dictation: customized,"))
    #expect(report.contains("chat: default,"))
    #expect(!report.contains(Self.promptSentinel))
    #expect(!report.contains(Self.glossarySentinel))
    #expect(!report.contains("## Glossary"))
    #expect(!report.contains("## System prompt texts"))
  }

  @Test("includeGlossary shows the glossary only")
  func glossaryOnly() throws {
    let report = try render(.init(includeGlossary: true))
    #expect(report.contains("## Glossary"))
    #expect(report.contains(Self.glossarySentinel))
    #expect(!report.contains(Self.promptSentinel))
  }

  @Test("includePrompts shows the prompt texts but not the glossary")
  func promptsOnly() throws {
    let report = try render(.init(includePrompts: true))
    #expect(report.contains("## System prompt texts"))
    #expect(report.contains(Self.promptSentinel))
    #expect(!report.contains(Self.glossarySentinel))
  }

  @Test("No variant leaks keys")
  func noKeys() throws {
    for options in [
      ConfigurationReport.Options(),
      .init(includeGlossary: true),
      .init(includePrompts: true),
      .init(includeGlossary: true, includePrompts: true),
    ] {
      let report = try render(options)
      #expect(!report.contains("apiKey"))
      #expect(!report.contains("sk-should-never-appear"))
    }
  }
}

@Suite("Configuration report, real catalog entries")
struct ConfigurationReportCatalogTests {
  @Test("Real catalog entries on empty defaults still report models and never keys")
  func liveCatalog() {
    let suite = "config-report-catalog-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // Real entries, fake system probes: the live ones (SMAppService, TCC, main-queue posts) hung the test host for 6729 s on 2026-11-08.
    let catalog = MCPSettingsCatalog.build(.init(
      defaults: defaults,
      hasAccessibilityPermission: { false },
      hasScreenRecordingPermission: { false },
      hasScreenshotFolder: { false },
      isLaunchAtLoginEnabled: { false },
      setLaunchAtLogin: { _ in },
      loadShortcutConfig: { .default },
      saveShortcutConfig: { _ in },
      postNotification: { _, _ in },
      postSelectionsChanged: {},
      writingStyleToggled: { _ in }))
    let report = ConfigurationReport.build(
      .init(), store: SystemPromptsStore(contextDirectoryURL: dir), defaults: defaults,
      environment: .init(appVersion: "1", osVersion: "2", isAppStoreBuild: true),
      settings: catalog)
    #expect(report.contains("### models"))
    #expect(report.contains("App 1 (App Store build)"))
    #expect(!report.lowercased().contains("apikey"))
  }
}
