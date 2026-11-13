import Foundation
import Security
import Testing
@testable import WhisperShortcut_AppStore

/// The resolution behind `TestProfile`: when a process is a test profile, and that it refuses to
/// run (fails closed) whenever isolation from the daily instance is not established.
@Suite("Test profile resolution")
struct TestProfileTests {

  private let name = "demo"
  private var id: String { TestProfile.bundleID(for: name) }
  private var home: String { "/Users/u/Library/Containers/\(id)/Data" }

  private func evaluate(
    info: [String: Any]? = nil,
    arguments: [String]? = nil,
    bundleID: String?? = nil,
    environment: [String: String]? = nil,
    homeDirectory: String? = nil,
    keychainGroups: Bool = false
  ) -> TestProfile.Decision {
    TestProfile.evaluate(
      info: info ?? [TestProfile.infoKey: name],
      arguments: arguments ?? ["/x/WhisperShortcut Dev", "--sidecar", "--profile", name],
      bundleID: bundleID ?? id,
      environment: environment ?? ["APP_SANDBOX_CONTAINER_ID": id],
      homeDirectory: homeDirectory ?? home,
      hasKeychainAccessGroups: keychainGroups)
  }

  private func isRefused(_ decision: TestProfile.Decision) -> Bool {
    if case .refuse = decision { return true }
    return false
  }

  @Test func bundleIdentifierIsDerivedFromTheName() {
    #expect(TestProfile.bundleID(for: "demo") == "com.magnusgoedde.whispershortcut.dev.profile.demo")
    #expect(!TestProfile.protectedBundleIDs.contains(TestProfile.bundleID(for: "demo")))
  }

  @Test(arguments: ["demo", "a", "selfcheck", "ui-2", String(repeating: "x", count: 32)])
  func validNames(_ name: String) { #expect(TestProfile.isValidName(name)) }

  @Test(arguments: ["", "-x", "Demo", "a b", "a.b", "../x", "ä", String(repeating: "x", count: 33)])
  func invalidNames(_ name: String) { #expect(!TestProfile.isValidName(name)) }

  @Test func ordinaryDevBuildIsNotAProfile() {
    let decision = TestProfile.evaluate(
      info: [:], arguments: ["/x/WhisperShortcut Dev", "--sidecar"],
      bundleID: "com.magnusgoedde.whispershortcut.dev",
      environment: ["APP_SANDBOX_CONTAINER_ID": "com.magnusgoedde.whispershortcut.dev"],
      homeDirectory: "/Users/u/Library/Containers/com.magnusgoedde.whispershortcut.dev/Data",
      hasKeychainAccessGroups: true)
    #expect(decision == .notProfile)
  }

  @Test func isolatedProfileResolves() {
    let source = "/Users/u/Library/Containers/com.magnusgoedde.whispershortcut.dev/Data"
    let decision = evaluate(info: [
      TestProfile.infoKey: name, TestProfile.modelSourceInfoKey: source,
      TestProfile.allowDownloadsInfoKey: false,
    ])
    #expect(decision == .profile(.init(name: name, bundleID: id, modelSource: source, allowsModelDownloads: false)))
  }

  @Test func noModelsAndAllowedDownloads() {
    let decision = evaluate(info: [
      TestProfile.infoKey: name, TestProfile.modelSourceInfoKey: "", TestProfile.allowDownloadsInfoKey: true,
    ])
    #expect(decision == .profile(.init(name: name, bundleID: id, modelSource: nil, allowsModelDownloads: true)))
  }

  @Test func profileArgumentOnThePlainDevBundleIsRefused() {
    #expect(isRefused(evaluate(info: [:], bundleID: "com.magnusgoedde.whispershortcut.dev")))
  }

  @Test func profileBundleIdentifierWithoutInfoKeyIsRefused() {
    #expect(isRefused(evaluate(info: [:], arguments: ["/x/WhisperShortcut Dev"])))
  }

  @Test func mismatchedArgumentIsRefused() {
    #expect(isRefused(evaluate(arguments: ["/x", "--profile", "other"])))
    #expect(isRefused(evaluate(arguments: ["/x", "--profile"])))
  }

  @Test(arguments: ["com.magnusgoedde.whispershortcut.dev", "com.magnusgoedde.whispershortcut", "com.magnusgoedde.whispershortcut.dev.profile.other"])
  func foreignBundleIdentifierIsRefused(_ bundleID: String) {
    #expect(isRefused(evaluate(bundleID: .some(bundleID))))
  }

  @Test func unsandboxedOrForeignContainerIsRefused() {
    #expect(isRefused(evaluate(environment: [:])))
    #expect(isRefused(evaluate(environment: ["APP_SANDBOX_CONTAINER_ID": "com.magnusgoedde.whispershortcut.dev"])))
    #expect(isRefused(evaluate(homeDirectory: "/Users/u/Library/Containers/com.magnusgoedde.whispershortcut.dev/Data")))
    #expect(isRefused(evaluate(homeDirectory: "/Users/u")))
  }

  @Test func keychainGroupIsRefused() {
    #expect(isRefused(evaluate(keychainGroups: true)))
  }

  @Test func takeoverIsRefused() {
    #expect(isRefused(evaluate(arguments: ["/x", "--profile", name, AppConstants.takeoverArgument])))
  }

  @Test func modelSourceInsideTheProfileOrRelativeIsRefused() {
    #expect(isRefused(evaluate(info: [TestProfile.infoKey: name, TestProfile.modelSourceInfoKey: home + "/Library"])))
    #expect(isRefused(evaluate(info: [TestProfile.infoKey: name, TestProfile.modelSourceInfoKey: "relative/path"])))
  }

  @Test func downloadGuardIsInertOutsideAProfile() throws {
    // The test host is not a profile: the guard must never block a normal build's download.
    #expect(!TestProfile.isActive)
    try TestProfile.checkModelDownloadAllowed("anything")
  }

  @Test func inMemoryKeychainRoundTrip() {
    let manager = KeychainManager(store: InMemoryKeychainItemStore(), dataProtection: false)
    #expect(manager.backendDescription == "memory")
    #expect(manager.secret(account: "a") == nil)
    #expect(manager.saveSecret("v1", account: "a"))
    #expect(manager.saveSecret("v2", account: "a"))
    #expect(manager.secret(account: "a") == "v2")
    #expect(manager.deleteSecret(account: "a"))
    #expect(manager.secret(account: "a") == nil)
  }
}
