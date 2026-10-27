import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The Done step used to pick Screen Recording or Accessibility from the build flag alone.
/// The recording path branches on the model: screenshot, App Store clipboard, or synthetic ⌘C.
@Suite("Dictate Prompt selection permission")
struct DictatePromptSelectionPermissionTests {

  @Test("Each model asks for the permission its capture mode actually needs")
  func matchesCaptureMode() {
    for model in PromptModel.allCases {
      if model.dictatePromptUsesScreenshotSelection {
        #expect(model.dictatePromptSelectionPermission == .screenRecording, "\(model.rawValue)")
      } else if AppConstants.dictatePromptUsesScreenshotSelection {
        #expect(model.dictatePromptSelectionPermission == nil, "\(model.rawValue)")
      } else {
        #expect(model.dictatePromptSelectionPermission == .accessibility, "\(model.rawValue)")
      }
    }
  }
}
