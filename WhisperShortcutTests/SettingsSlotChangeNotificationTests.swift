import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// `SettingsViewModel` persists through `UserDefaults.standard` and has no suite to inject, so
/// this drives the slot table as a pure function. `slotsToSave` is the gate `saveSettings`
/// uses, and each changed slot's `onDidChange` is what posts. A save whose values match what
/// was last loaded has no slot to fire, which is what used to fail: the Dictate picker posted
/// `.modelChanged` itself and `saveSettings` posted it again.
@Suite("Settings slot change notifications", .serialized)
@MainActor
struct SettingsSlotChangeNotificationTests {

  private final class NoteBag {
    var notes: [Notification] = []
  }

  /// Posts are synchronous (`queue: nil`), so the bag is full when `body` returns.
  private func notices(during body: () -> Void) -> [Notification] {
    let bag = NoteBag()
    let center = NotificationCenter.default
    let names: [Notification.Name] = [.modelChanged, .promptModelChanged]
    let tokens = names.map { name in
      center.addObserver(forName: name, object: nil, queue: nil) { bag.notes.append($0) }
    }
    defer { tokens.forEach { center.removeObserver($0) } }
    body()
    return bag.notes
  }

  /// What `saveSettings` posts for this snapshot: the hooks of the slots that actually differ.
  private func fireChanges(data: SettingsData, persisted: SettingsData) -> [Notification] {
    let changed = SettingsSlot.slotsToSave(SettingsViewModel.slots, data: data, persisted: persisted)
    return notices {
      for slot in changed { slot.onDidChange?(data) }
    }
  }

  @Test("A changed transcription model posts .modelChanged once")
  func transcriptionChangePostsOnce() {
    var persisted = SettingsData()
    var data = persisted
    data.selectedTranscriptionModel = .gemini35FlashLite
    #expect(data.selectedTranscriptionModel != persisted.selectedTranscriptionModel)

    let changed = SettingsSlot.slotsToSave(SettingsViewModel.slots, data: data, persisted: persisted)
    #expect(changed.count == 1)

    let posted = fireChanges(data: data, persisted: persisted)
    #expect(posted.count == 1)
    #expect(posted.first?.name == .modelChanged)
    #expect(posted.first?.object as? TranscriptionModel == .gemini35FlashLite)
    #expect(posted.first?.userInfo == nil)
  }

  @Test("Chat and Dictate Prompt post .promptModelChanged with that model")
  func chatAndPromptPostPromptModelChanged() {
    var persisted = SettingsData()

    var chat = persisted
    chat.selectedChatModel = .grok43
    let chatPosted = fireChanges(data: chat, persisted: persisted)
    #expect(chatPosted.count == 1)
    #expect(chatPosted.first?.name == .promptModelChanged)
    #expect(chatPosted.first?.object as? PromptModel == .grok43)
    #expect(chatPosted.first?.userInfo == nil)

    var prompt = persisted
    prompt.selectedPromptModel = .gemini35FlashLite
    let promptPosted = fireChanges(data: prompt, persisted: persisted)
    #expect(promptPosted.count == 1)
    #expect(promptPosted.first?.name == .promptModelChanged)
    #expect(promptPosted.first?.object as? PromptModel == .gemini35FlashLite)
    #expect(promptPosted.first?.userInfo == nil)
  }

  @Test("Read Aloud, Smart Improvement and meeting models post nothing")
  func silentModelSlotsPostNothing() {
    var persisted = SettingsData()
    var data = persisted
    data.selectedImprovementModel = .grok43
    data.selectedReadAloudModel = .openAIGpt4oMiniTTS
    data.selectedTranscriptionModelForMeetings = .gemini35FlashLite
    data.selectedMeetingSummaryModel = .grok43
    let changed = SettingsSlot.slotsToSave(SettingsViewModel.slots, data: data, persisted: persisted)
    #expect(changed.count == 4)
    #expect(fireChanges(data: data, persisted: persisted).isEmpty)
  }

  @Test("Saving with nothing changed posts nothing")
  func unchangedPostsNothing() {
    let data = SettingsData()
    let changed = SettingsSlot.slotsToSave(SettingsViewModel.slots, data: data, persisted: data)
    #expect(changed.isEmpty)
    #expect(fireChanges(data: data, persisted: data).isEmpty)
  }
}
