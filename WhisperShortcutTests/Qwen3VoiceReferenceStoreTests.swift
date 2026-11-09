//
//  Qwen3VoiceReferenceStoreTests.swift
//  WhisperShortcutTests
//
//  The reference store is what makes a persona the same voice across sessions and across
//  "reset voice" presses. Its failure modes are silent by nature (a corrupt file must read as
//  "no reference", not as a crash), so the contract is pinned here.
//

import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Qwen3 voice reference store")
struct Qwen3VoiceReferenceStoreTests {

  @Test("Store, read back and remove a reference")
  func storeReadRemove() {
    let id = "test-persona-\(UUID().uuidString)"
    defer { Qwen3VoiceReferenceStore.removeReference(for: id) }

    #expect(!Qwen3VoiceReferenceStore.hasReference(for: id))

    let samples: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5]
    Qwen3VoiceReferenceStore.store(samples: samples, sampleRate: 24_000, text: "Hallo", for: id)

    #expect(Qwen3VoiceReferenceStore.hasReference(for: id))
    let read = Qwen3VoiceReferenceStore.reference(for: id)
    #expect(read != nil)
    #expect(read?.sampleRate == 24_000)
    #expect(read?.text == "Hallo")
    // Float32 round trip must be exact — the ICL path aligns these samples against the text.
    #expect(read?.samples == samples)

    Qwen3VoiceReferenceStore.removeReference(for: id)
    #expect(!Qwen3VoiceReferenceStore.hasReference(for: id))
    #expect(Qwen3VoiceReferenceStore.reference(for: id) == nil)
  }

  @Test("Removing a reference that never existed is a no-op")
  func removeMissingIsNoOp() {
    let id = "test-persona-missing-\(UUID().uuidString)"
    Qwen3VoiceReferenceStore.removeReference(for: id)
    #expect(!Qwen3VoiceReferenceStore.hasReference(for: id))
  }

  @Test("Calibration text exists for both picker languages")
  func calibrationTextExists() {
    let german = Qwen3VoiceReferenceStore.calibrationText(for: "German")
    let english = Qwen3VoiceReferenceStore.calibrationText(for: "English")
    #expect(!german.isEmpty)
    #expect(!english.isEmpty)
    #expect(german != english)
  }
}

@Suite("Qwen3 custom personas")
struct Qwen3CustomPersonasTests {

  private func makePersona(name: String) -> Qwen3VoicePersona {
    Qwen3VoicePersona(
      id: Qwen3CustomPersonas.uniqueID(for: name), gender: "m", summary: name,
      language: "German", prompt: "Native German speaker, male, calm narrator voice")
  }

  @Test("Save, resolve and delete a custom persona")
  func saveResolveDelete() {
    let persona = makePersona(name: "Teststimme \(UUID().uuidString)")
    defer { Qwen3CustomPersonas.delete(id: persona.id) }

    Qwen3CustomPersonas.save(persona)
    #expect(Qwen3CustomPersonas.persona(for: persona.id) == persona)
    #expect(Qwen3VoicePersona.persona(for: persona.id) == persona)

    Qwen3CustomPersonas.delete(id: persona.id)
    #expect(Qwen3CustomPersonas.persona(for: persona.id) == nil)
    // Unknown ids fall back to the default, never to nil.
    #expect(Qwen3VoicePersona.persona(for: persona.id) == Qwen3VoicePersona.default)
  }

  @Test("Editing a persona keeps its id and position")
  func editKeepsId() {
    let persona = makePersona(name: "Editstimme \(UUID().uuidString)")
    defer { Qwen3CustomPersonas.delete(id: persona.id) }
    Qwen3CustomPersonas.save(persona)

    let edited = Qwen3VoicePersona(
      id: persona.id, gender: "w", summary: persona.summary, language: "German",
      prompt: "Native German speaker, female, warm narrator voice")
    Qwen3CustomPersonas.save(edited)

    let all = Qwen3CustomPersonas.all
    #expect(all.filter { $0.id == persona.id }.count == 1)
    #expect(Qwen3CustomPersonas.persona(for: persona.id) == edited)
  }

  @Test("Unique ids never collide with built-ins or existing customs")
  func uniqueIDDoesNotCollide() {
    let first = Qwen3CustomPersonas.uniqueID(for: "Erzähler")
    Qwen3CustomPersonas.save(
      Qwen3VoicePersona(
        id: first, gender: "m", summary: "Erzähler", language: "German",
        prompt: "Native German speaker, male"))
    defer { Qwen3CustomPersonas.delete(id: first) }

    let second = Qwen3CustomPersonas.uniqueID(for: "Erzähler")
    #expect(second != first)
    #expect(!Qwen3VoicePersona.all.contains { $0.id == second })
  }

  @Test("Custom personas appear in the picker behind the built-ins")
  func pickerIncludesCustoms() {
    let persona = makePersona(name: "Pickersichtbar \(UUID().uuidString)")
    defer { Qwen3CustomPersonas.delete(id: persona.id) }
    Qwen3CustomPersonas.save(persona)

    let ids = Qwen3VoicePersona.pickerVoices.map { $0.id }
    #expect(ids.contains(persona.id))
    #expect(ids.first == Qwen3VoicePersona.all.first?.id)
  }

  private struct ImportFailed: Error {}

  @Test("A failed voice-clip import does not leave the persona saved")
  func failedImportDoesNotSave() async {
    let persona = makePersona(name: "Importfail \(UUID().uuidString)")
    defer { Qwen3CustomPersonas.delete(id: persona.id) }

    await #expect(throws: ImportFailed.self) {
      try await Qwen3CustomPersonas.save(persona) { throw ImportFailed() }
    }
    #expect(Qwen3CustomPersonas.persona(for: persona.id) == nil)
  }

  @Test("The voice clip is imported before the persona is persisted")
  func importRunsBeforePersist() async throws {
    let persona = makePersona(name: "Importok \(UUID().uuidString)")
    defer { Qwen3CustomPersonas.delete(id: persona.id) }
    var sawUnsaved = false

    try await Qwen3CustomPersonas.save(persona) {
      sawUnsaved = Qwen3CustomPersonas.persona(for: persona.id) == nil
    }
    #expect(sawUnsaved)
    #expect(Qwen3CustomPersonas.persona(for: persona.id) == persona)
  }

  @Test("Deleting a persona removes its frozen voice")
  func deleteRemovesReference() {
    let persona = makePersona(name: "Reflösch \(UUID().uuidString)")
    Qwen3CustomPersonas.save(persona)
    Qwen3VoiceReferenceStore.store(
      samples: [0.1, 0.2], sampleRate: 24_000, text: "x", for: persona.id)
    #expect(Qwen3VoiceReferenceStore.hasReference(for: persona.id))

    Qwen3CustomPersonas.delete(id: persona.id)
    #expect(!Qwen3VoiceReferenceStore.hasReference(for: persona.id))
  }
}
