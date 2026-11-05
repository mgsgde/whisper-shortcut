//
//  Qwen3CustomPersonas.swift
//  WhisperShortcut
//
//  User-defined VoiceDesign personas, persisted as JSON.
//
//  The built-in catalogue in `Qwen3VoicePersonas.all` covers the common cases; a user who wants
//  their own narrator writes their own description here. Custom personas behave exactly like
//  built-in ones in the picker and in the voice-reference cache — including the "reset voice"
//  button, which regenerates the frozen reference from the description.
//
//  The description is stored as the user wrote it (German or English). The checkpoint was
//  trained on English instructions, so the editor UI recommends English and the built-in
//  prompts are English — but a German description still produces audio, just a less precisely
//  steered voice, and forbidding it would help nobody.
//

import Foundation

/// Storage and resolution for user-defined personas. Same lookup contract as
/// `Qwen3VoicePersona.persona(for:)`: unknown or empty ids fall back to the default.
enum Qwen3CustomPersonas {

  /// All user-defined personas, in creation order. Oldest first so the picker order is stable.
  static var all: [Qwen3VoicePersona] {
    load()
  }

  /// Resolves a stored id against the custom personas only. nil when it is not one of them.
  static func persona(for id: String) -> Qwen3VoicePersona? {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return load().first { $0.id == trimmed }
  }

  /// Adds or replaces a persona. New ids get a stable, unique slug derived from the name.
  static func save(_ persona: Qwen3VoicePersona) {
    var personas = load()
    if let index = personas.firstIndex(where: { $0.id == persona.id }) {
      personas[index] = persona
    } else {
      personas.append(persona)
    }
    persist(personas)
  }

  /// Deletes a persona and its frozen voice reference. Deleting the reference matters: a stale
  /// reference for a removed persona is dead weight, and if the user recreates a persona with
  /// the same name the old voice must not silently come back.
  static func delete(id: String) {
    var personas = load()
    personas.removeAll { $0.id == id }
    persist(personas)
    Qwen3VoiceReferenceStore.removeReference(for: id)
  }

  /// A slug that is safe as a filename fragment and collision-free against existing ids.
  static func uniqueID(for name: String) -> String {
    let base = "custom-" + name
      .lowercased()
      .map { character in
        character.isLetter && character.isASCII || character.isNumber ? character : "-"
      }
      .reduce(into: "") { $0.append($1) }
      .split(separator: "-")
      .joined(separator: "-")
    let existing = Set(load().map { $0.id } + Qwen3VoicePersona.all.map { $0.id })
    guard existing.contains(base) else { return base }
    var counter = 2
    while existing.contains("\(base)-\(counter)") { counter += 1 }
    return "\(base)-\(counter)"
  }

  // MARK: - Persistence

  private static var fileURL: URL {
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("Qwen3CustomPersonas.json")
    return url
  }

  private static func load() -> [Qwen3VoicePersona] {
    guard let data = try? Data(contentsOf: fileURL),
      let decoded = try? JSONDecoder().decode([StoredPersona].self, from: data)
    else { return [] }
    return decoded.map {
      Qwen3VoicePersona(
        id: $0.id, gender: $0.gender, summary: $0.summary, language: $0.language,
        prompt: $0.prompt)
    }
  }

  private static func persist(_ personas: [Qwen3VoicePersona]) {
    let stored = personas.map {
      StoredPersona(id: $0.id, gender: $0.gender, summary: $0.summary, language: $0.language, prompt: $0.prompt)
    }
    guard let data = try? JSONEncoder().encode(stored) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }

  /// On-disk shape. Kept separate from `Qwen3VoicePersona` so a future prompt change in the
  /// struct cannot silently rewrite what users saved.
  private struct StoredPersona: Codable {
    let id: String
    let gender: String
    let summary: String
    let language: String
    let prompt: String
  }
}
