import Testing

@testable import WhisperShortcut_AppStore

@Suite("App bundle location")
struct AppBundleLocationTests {
  private let home = "/Users/anna"

  private func classify(_ path: String) -> AppBundleLocation {
    AppBundleLocation.classify(bundlePath: path, homeDirectory: home)
  }

  @Test("Applications and ~/Applications need no move")
  func applications() {
    #expect(classify("/Applications/WhisperShortcut.app") == .applications)
    #expect(classify("/Applications/Utilities/WhisperShortcut.app") == .applications)
    #expect(classify("/Users/anna/Applications/WhisperShortcut.app") == .applications)
    #expect(!AppBundleLocation.applications.shouldOfferMove)
  }

  @Test("A translocated or disk-image launch is offered the move")
  func translocatedAndDiskImage() {
    let translocated =
      "/private/var/folders/xy/abc/T/AppTranslocation/1F2E3D4C-0000-1111-2222-333344445555/d/WhisperShortcut.app"
    #expect(classify(translocated) == .translocated)
    #expect(classify("/Volumes/WhisperShortcut/WhisperShortcut.app") == .diskImage)
    #expect(AppBundleLocation.translocated.shouldOfferMove)
    #expect(AppBundleLocation.diskImage.shouldOfferMove)
  }

  @Test("Downloads or the Desktop is offered the move")
  func elsewhere() {
    #expect(classify("/Users/anna/Downloads/WhisperShortcut.app") == .elsewhere)
    #expect(classify("/Users/anna/Desktop/WhisperShortcut.app") == .elsewhere)
    #expect(AppBundleLocation.elsewhere.shouldOfferMove)
  }

  @Test("Another user's or a look-alike folder is not Applications")
  func lookAlikes() {
    #expect(classify("/Users/other/Applications/WhisperShortcut.app") == .elsewhere)
    #expect(classify("/ApplicationsOld/WhisperShortcut.app") == .elsewhere)
  }

  @Test("Build products are never offered a move")
  func developerBuilds() {
    #expect(
      classify("/Users/anna/Library/Developer/Xcode/DerivedData/WS-abc/Build/Products/Release/WhisperShortcut.app")
        == .developerBuild)
    #expect(classify("/Users/anna/code/whisper-shortcut/build/Release/WhisperShortcut.app") == .developerBuild)
    #expect(
      classify("/Users/anna/code/whisper-shortcut/.claude/worktrees/x/build/WhisperShortcut Dev.app")
        == .developerBuild)
    #expect(!AppBundleLocation.developerBuild.shouldOfferMove)
  }

  @Test("Not Now is remembered for that path only")
  func declinedPath() {
    let downloads = "/Users/anna/Downloads/WhisperShortcut.app"
    let desktop = "/Users/anna/Desktop/WhisperShortcut.app"
    #expect(ApplicationsFolderMove.shouldOffer(currentMarker: downloads, declinedMarker: nil))
    #expect(!ApplicationsFolderMove.shouldOffer(currentMarker: downloads, declinedMarker: downloads))
    #expect(ApplicationsFolderMove.shouldOffer(currentMarker: desktop, declinedMarker: downloads))
  }

  @Test("Not Now on a translocated app holds across launches, though the path changes every time")
  func declinedTranslocated() {
    func marker(_ uuid: String, version: String = "8.1(100)") -> String {
      ApplicationsFolderMove.declineMarker(
        location: .translocated,
        bundlePath: "/private/var/folders/ab/xyz/T/AppTranslocation/\(uuid)/d/WhisperShortcut.app",
        version: version)
    }
    let first = marker("11111111-1111")
    #expect(!ApplicationsFolderMove.shouldOffer(currentMarker: marker("22222222-2222"), declinedMarker: first))
    // A new version asks once more.
    #expect(ApplicationsFolderMove.shouldOffer(currentMarker: marker("33333333-3333", version: "8.2(101)"), declinedMarker: first))
    // A normal location still keys on the path.
    let path = "/Users/anna/Downloads/WhisperShortcut.app"
    #expect(ApplicationsFolderMove.declineMarker(location: .elsewhere, bundlePath: path, version: "8.1(100)") == path)
  }
}
