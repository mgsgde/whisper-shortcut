//
//  TestProfile.swift
//  WhisperShortcut
//
//  An isolated "test profile" instance of a Debug build, so an agent can run the onboarding from a
//  fresh state, flip any setting and take screenshots without touching the developer's daily
//  instance. Launched by `scripts/rebuild-and-restart.sh --sidecar --profile <name> [--fresh]`.
//
//  Isolation comes from the operating system, not from this file: the script copies the built
//  bundle, gives the copy its own bundle identifier (`com.magnusgoedde.whispershortcut.dev.profile.<name>`)
//  and re-signs it without the keychain access group. A sandboxed app's `UserDefaults.standard`,
//  Application Support, Documents, Caches and Logs all live in the container macOS creates per
//  bundle identifier, so every one of the ~330 `UserDefaults.standard` / `@AppStorage` call sites
//  and every data-root lookup is isolated without being edited (none can be missed).
//
//  What this file adds on top:
//  - `enforceIsolationOrExit()`: fail closed. A process that is asked to be a profile (Info.plist
//    key or `--profile` argument) but is not provably running in its own container, under its own
//    bundle identifier, without the keychain group, exits before anything reads or writes data.
//  - The keychain swap (`KeychainManager.shared` uses `InMemoryKeychainItemStore`): no profile
//    process ever calls `SecItem*`, so it can neither read nor change the daily instance's keys,
//    and no keychain password dialog can appear.
//  - Shared offline models: the already downloaded model folders of the source container are
//    symlinked in, read-only (the re-signed profile's sandbox has read-only exceptions for exactly
//    those folders), so nothing is downloaded again. `--no-models` links none.
//  - A model download guard (`checkModelDownloadAllowed`), the seam for a later "pretend download".
//

import Foundation
import Security

enum TestProfile {

  // MARK: - Contract with scripts/lib/test-profile.sh

  /// Info.plist key holding the profile name. Written only by the profile bundle script.
  static let infoKey = "WSTestProfile"
  /// Info.plist key: absolute path of the source container's `Data` folder whose model folders are
  /// linked in read-only. Absent or empty means `--no-models`.
  static let modelSourceInfoKey = "WSTestProfileModelSource"
  /// Info.plist key: true only with `--allow-model-downloads`.
  static let allowDownloadsInfoKey = "WSTestProfileAllowModelDownloads"
  /// Launch argument the script passes (`--profile <name>`). Must match the Info.plist name.
  static let argument = "--profile"
  /// Launch argument of `scripts/test-profile-selfcheck.sh`: write a few settings and a glossary
  /// word through the real code paths, then report where they landed.
  static let selfcheckArgument = "--profile-selfcheck"
  static let bundleIDPrefix = "com.magnusgoedde.whispershortcut.dev.profile."
  /// The release and the Dev build. A profile never runs under either identifier.
  static let protectedBundleIDs: Set<String> = [
    "com.magnusgoedde.whispershortcut", "com.magnusgoedde.whispershortcut.dev",
  ]
  /// Model folders shared from the source container, relative to a container's `Data` folder.
  /// Keep in sync with `PROFILE_MODEL_PATHS` in scripts/lib/test-profile.sh (the sandbox
  /// exceptions are signed from that list).
  static let sharedModelPaths = [
    "Library/Application Support/WhisperShortcut/WhisperKit",
    "Library/Application Support/WhisperShortcut/MLXModels",
    "Library/Application Support/WhisperShortcut/Qwen3Models",
    "Library/Application Support/FluidAudio",
    "Documents/huggingface",
  ]

  // MARK: - Resolution

  struct Config: Equatable {
    let name: String
    let bundleID: String
    /// Source container `Data` folder for the read-only model links; nil = no models.
    let modelSource: String?
    let allowsModelDownloads: Bool
  }

  enum Decision: Equatable {
    case notProfile
    case profile(Config)
    /// Profile mode was requested but isolation cannot be established. The app must exit.
    case refuse(String)
  }

  static func isValidName(_ name: String) -> Bool {
    guard (1...32).contains(name.count), let first = name.unicodeScalars.first else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    return name.unicodeScalars.allSatisfy { allowed.contains($0) } && first != "-"
  }

  static func bundleID(for name: String) -> String { bundleIDPrefix + name }

  /// Pure decision from everything the process can observe about itself. `homeDirectory` is
  /// `NSHomeDirectory()`, which in a sandboxed app is its container's `Data` folder.
  static func evaluate(
    info: [String: Any],
    arguments: [String],
    bundleID: String?,
    environment: [String: String],
    homeDirectory: String,
    hasKeychainAccessGroups: Bool
  ) -> Decision {
    let plistName = (info[infoKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
    var argumentName: String?
    var argumentGiven = false
    if let index = arguments.firstIndex(of: argument) {
      argumentGiven = true
      if arguments.indices.contains(index + 1) { argumentName = arguments[index + 1] }
    }
    let profileBundleID = bundleID?.hasPrefix(bundleIDPrefix) ?? false
    guard plistName != nil || argumentGiven || profileBundleID else { return .notProfile }

    guard let name = plistName else {
      return .refuse("profile requested (argument or bundle identifier \(bundleID ?? "nil")), but the bundle has no \(infoKey) in Info.plist")
    }
    guard isValidName(name) else { return .refuse("invalid profile name \"\(name)\"") }
    if argumentGiven, argumentName != name {
      return .refuse("\(argument) \(argumentName ?? "<missing>") does not match the bundle's profile \"\(name)\"")
    }
    let expectedID = Self.bundleID(for: name)
    guard let bundleID, bundleID == expectedID, !protectedBundleIDs.contains(bundleID) else {
      return .refuse("bundle identifier \(bundleID ?? "nil") is not the profile's own \(expectedID)")
    }
    guard environment["APP_SANDBOX_CONTAINER_ID"] == bundleID else {
      return .refuse(
        "not sandboxed into the profile's own container (APP_SANDBOX_CONTAINER_ID=\(environment["APP_SANDBOX_CONTAINER_ID"] ?? "nil"))")
    }
    let home = (homeDirectory as NSString).standardizingPath
    guard home.hasSuffix("/Library/Containers/\(bundleID)/Data") else {
      return .refuse("home directory \(home) is not the profile's container")
    }
    guard !hasKeychainAccessGroups else {
      return .refuse("the bundle still carries keychain-access-groups (it could reach the Dev build's keys)")
    }
    if arguments.contains(AppConstants.takeoverArgument) {
      return .refuse("\(AppConstants.takeoverArgument) is not allowed for a profile")
    }

    var modelSource = (info[modelSourceInfoKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
    if let source = modelSource {
      let standardized = (source as NSString).standardizingPath
      guard standardized.hasPrefix("/"), standardized != home, !standardized.hasPrefix(home + "/") else {
        return .refuse("model source \(source) is not an absolute path outside the profile")
      }
      modelSource = standardized
    }
    let allowDownloads = (info[allowDownloadsInfoKey] as? Bool) ?? false
    return .profile(
      Config(name: name, bundleID: bundleID, modelSource: modelSource, allowsModelDownloads: allowDownloads))
  }

  /// Evaluated once, from the running process.
  static let decision: Decision = evaluate(
    info: Bundle.main.infoDictionary ?? [:],
    arguments: ProcessInfo.processInfo.arguments,
    bundleID: Bundle.main.bundleIdentifier,
    environment: ProcessInfo.processInfo.environment,
    homeDirectory: NSHomeDirectory(),
    hasKeychainAccessGroups: processHasKeychainAccessGroups())

  static var config: Config? {
    if case .profile(let config) = decision { return config }
    return nil
  }

  static var isActive: Bool { config != nil }
  static var name: String? { config?.name }

  private static func processHasKeychainAccessGroups() -> Bool {
    let groups = SecTaskCreateFromSelf(nil).flatMap {
      SecTaskCopyValueForEntitlement($0, "keychain-access-groups" as CFString, nil) as? [String]
    }
    return !(groups ?? []).isEmpty
  }

  // MARK: - Launch

  /// First thing `main()` does. A refused profile exits with status 78 (EX_CONFIG) before any
  /// setting, file or keychain item is touched; the line goes to stderr and the app log.
  static func enforceIsolationOrExit() {
    switch decision {
    case .notProfile:
      return
    case .refuse(let reason):
      let line = "TEST-PROFILE: refusing to run, isolation not established: \(reason)"
      FileHandle.standardError.write(Data((line + "\n").utf8))
      DebugLogger.logError(line)
      exit(78)
    case .profile(let config):
      DebugLogger.log(
        "TEST-PROFILE: \"\(config.name)\" bundle=\(config.bundleID) home=\(NSHomeDirectory()) "
          + "models=\(config.modelSource ?? "none") downloads=\(config.allowsModelDownloads ? "allowed" : "blocked") keychain=memory")
      linkSharedModels(config)
    }
  }

  /// Points the profile's model folders at the source container (read-only by sandbox exception),
  /// or removes those links for `--no-models`. Only ever creates or removes symlinks inside the
  /// profile's own container; a real folder (a download made with `--allow-model-downloads`) is kept.
  static func linkSharedModels(_ config: Config) {
    let fm = FileManager.default
    let home = NSHomeDirectory()
    for relative in sharedModelPaths {
      let link = (home as NSString).appendingPathComponent(relative)
      let existingDestination = try? fm.destinationOfSymbolicLink(atPath: link)
      let isLink = existingDestination != nil
      guard let source = config.modelSource else {
        if isLink { try? fm.removeItem(atPath: link) }
        continue
      }
      let target = (source as NSString).appendingPathComponent(relative)
      guard fm.fileExists(atPath: target) else { continue }
      if isLink {
        if existingDestination == target { continue }
        try? fm.removeItem(atPath: link)
      } else if fm.fileExists(atPath: link) {
        DebugLogger.log("TEST-PROFILE: keeping the profile's own \(relative) (not linking the shared one)")
        continue
      }
      do {
        try fm.createDirectory(
          atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
      } catch {
        DebugLogger.logWarning("TEST-PROFILE: could not link \(relative): \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Model download guard

  struct ModelDownloadBlocked: LocalizedError {
    let model: String
    var errorDescription: String? {
      "Model downloads are off in this test profile (\(model)). Relaunch the profile with --allow-model-downloads."
    }
  }

  /// Every model download passes here (`ModelStore.performDownload`, the Silero VAD prepare). In a
  /// profile it throws unless the profile was launched with `--allow-model-downloads`. This is the
  /// seam for a stubbed "pretend download" later.
  static func checkModelDownloadAllowed(_ model: String) throws {
    guard let config, !config.allowsModelDownloads else { return }
    DebugLogger.log("TEST-PROFILE: blocked model download \(model)")
    throw ModelDownloadBlocked(model: model)
  }

  // MARK: - Self-check hook

  /// With `--profile-selfcheck`: flips a few settings through `UserDefaults.standard`, adds a
  /// glossary word through `SystemPromptsStore`, stores a dummy secret through `KeychainManager`,
  /// and writes `profile-selfcheck.json` into the profile's Application Support for the script.
  @MainActor
  static func runSelfcheckIfRequested() {
    guard let config, ProcessInfo.processInfo.arguments.contains(selfcheckArgument) else { return }
    let defaults = UserDefaults.standard
    let probe = "selfcheck-\(Int(Date().timeIntervalSince1970))"
    defaults.set(probe, forKey: "testProfileSelfcheckProbe")
    defaults.set(!defaults.bool(forKey: UserDefaultsKeys.showDockIcon), forKey: UserDefaultsKeys.showDockIcon)
    defaults.set(true, forKey: UserDefaultsKeys.offlineModeEnabled)
    defaults.set(true, forKey: UserDefaultsKeys.enableDebugTestMenu)
    defaults.synchronize()

    let word = "Zyxqvselfcheck"
    _ = SystemPromptsStore.shared.appendToWhisperGlossary(word, source: .settings)
    let glossary = SystemPromptsStore.shared.loadSection(.whisperGlossary) ?? ""

    let account = "test-profile-selfcheck"
    let saved = KeychainManager.shared.saveSecret(probe, account: account)
    let readBack = KeychainManager.shared.secret(account: account) == probe

    let appSupport = AppSupportPaths.whisperShortcutApplicationSupportURL()
    let report: [String: Any] = [
      "profile": config.name,
      "bundleID": Bundle.main.bundleIdentifier ?? "",
      "home": NSHomeDirectory(),
      "appSupport": appSupport.path,
      "probe": probe,
      "defaultsProbeReadBack": defaults.string(forKey: "testProfileSelfcheckProbe") == probe,
      "glossaryContainsWord": glossary.contains(word),
      "keychainSaved": saved,
      "keychainReadBack": readBack,
      "keychainBackend": KeychainManager.shared.backendDescription,
      "pid": Int(getpid()),
    ]
    AppSupportPaths.ensureDirectoryExists(appSupport)
    let url = appSupport.appendingPathComponent("profile-selfcheck.json")
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: url, options: .atomic)
    }
    DebugLogger.log("TEST-PROFILE: selfcheck written to \(url.path)")
  }
}

// MARK: - In-memory keychain

/// The keychain a test profile uses: a dictionary for the life of the process. It never calls
/// `SecItem*`, so a profile cannot read, change or delete a real keychain item and can never put up
/// a keychain password dialog. Keys entered in a profile are gone when it quits.
final class InMemoryKeychainItemStore: KeychainItemStore {
  private let lock = NSLock()
  private var items: [String: Data] = [:]

  private func account(_ query: [String: Any]) -> String? { query[kSecAttrAccount as String] as? String }

  func copyMatching(_ query: [String: Any], _ result: inout AnyObject?) -> OSStatus {
    lock.lock(); defer { lock.unlock() }
    if let account = account(query) {
      guard let data = items[account] else { return errSecItemNotFound }
      if (query[kSecReturnData as String] as? Bool) == true {
        result = data as NSData
      } else {
        result = [kSecAttrAccount as String: account] as NSDictionary
      }
      return errSecSuccess
    }
    guard !items.isEmpty else { return errSecItemNotFound }
    result = items.keys.sorted().map { [kSecAttrAccount as String: $0] as NSDictionary } as NSArray
    return errSecSuccess
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    lock.lock(); defer { lock.unlock() }
    guard let account = account(attributes), let data = attributes[kSecValueData as String] as? Data else {
      return errSecParam
    }
    guard items[account] == nil else { return errSecDuplicateItem }
    items[account] = data
    return errSecSuccess
  }

  func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
    lock.lock(); defer { lock.unlock() }
    guard let account = account(query), items[account] != nil else { return errSecItemNotFound }
    if let data = attributes[kSecValueData as String] as? Data { items[account] = data }
    return errSecSuccess
  }

  @discardableResult func delete(_ query: [String: Any]) -> OSStatus {
    lock.lock(); defer { lock.unlock() }
    guard let account = account(query), items.removeValue(forKey: account) != nil else {
      return errSecItemNotFound
    }
    return errSecSuccess
  }
}
