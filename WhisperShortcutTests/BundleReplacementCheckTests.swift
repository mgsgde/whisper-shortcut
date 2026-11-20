import Testing

@testable import WhisperShortcut_AppStore

/// Pure comparison of the version this process launched with against the plist on disk.
/// `currentMismatch()` is not exercised here: it reads `Bundle.main`.
@Suite("Bundle replacement check")
struct BundleReplacementCheckTests {

  @Test("Same version and build is not a replacement")
  func sameValues() {
    #expect(
      !BundleReplacementCheck.isReplaced(
        runningVersion: "1.2.3", runningBuild: "45",
        onDiskVersion: "1.2.3", onDiskBuild: "45"))
  }

  @Test("A different build is a replacement")
  func buildDiffers() {
    #expect(
      BundleReplacementCheck.isReplaced(
        runningVersion: "1.2.3", runningBuild: "45",
        onDiskVersion: "1.2.3", onDiskBuild: "46"))
  }

  @Test("A different version is a replacement")
  func versionDiffers() {
    #expect(
      BundleReplacementCheck.isReplaced(
        runningVersion: "1.2.3", runningBuild: "45",
        onDiskVersion: "1.2.4", onDiskBuild: "45"))
  }

  @Test("Unreadable on-disk values are not a replacement")
  func onDiskNil() {
    #expect(
      !BundleReplacementCheck.isReplaced(
        runningVersion: "1.2.3", runningBuild: "45",
        onDiskVersion: nil, onDiskBuild: nil))
    #expect(
      !BundleReplacementCheck.isReplaced(
        runningVersion: "1.2.3", runningBuild: "45",
        onDiskVersion: nil, onDiskBuild: "45"))
    #expect(
      !BundleReplacementCheck.isReplaced(
        runningVersion: "1.2.3", runningBuild: "45",
        onDiskVersion: "1.2.3", onDiskBuild: nil))
  }

  @Test("A running value that was never read still differs from a readable bundle")
  func runningNilOnDiskSet() {
    #expect(
      BundleReplacementCheck.isReplaced(
        runningVersion: nil, runningBuild: nil,
        onDiskVersion: "1.2.3", onDiskBuild: "45"))
  }
}
