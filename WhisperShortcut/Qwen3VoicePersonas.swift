//
//  Qwen3VoicePersonas.swift
//  WhisperShortcut
//
//  Selectable voice descriptions for Qwen3-TTS VoiceDesign.
//
//  VoiceDesign takes no speaker id: the voice *is* a natural-language description. The model
//  card's own examples are English, and the checkpoint was trained on English instructions, so
//  every prompt here is English even though the app's UI is bilingual.
//
//  Why the prompts are this long and this explicit: the failure mode of a German narrator voice
//  is an audible English or American accent, because the checkpoint's speaker prior is dominated
//  by English and Chinese training data. Naming the language, the region, the age and the
//  absence of a foreign accent is what suppresses it. Short prompts ("warm German male") reliably
//  produce a translated-sounding voice; the long form does not.
//
//  Every prompt therefore opens with "Native German speaker" / "Native English speaker" and
//  repeats "no foreign or English accent" for the German ones. That repetition is not padding —
//  it is the part that makes the voice sound native rather than translated.
//

import Foundation

/// One selectable VoiceDesign persona: a display name, a short description for the picker, and
/// the full instruction string handed to the model as `voice`.
struct Qwen3VoicePersona: Identifiable, Hashable {
  /// Stable id, persisted in `UserDefaults`. Never change an existing one — a stored selection
  /// would silently fall back to the default.
  let id: String
  /// "m" / "w", matching `TTSVoice.gender` so the picker can sort and label it the same way.
  let gender: String
  /// One-line summary shown under the name in the picker.
  let summary: String
  /// The model's own language name ("German", "English"). Qwen3-TTS takes this as a separate
  /// argument from the voice description, and getting it wrong is audible: the checkpoint reads
  /// German text with an English voice if the language says English.
  let language: String
  /// The instruction the model receives. English, deliberately verbose — see the file header.
  let prompt: String
  /// CustomVoice checkpoints take a fixed speaker name instead of a description. nil for
  /// VoiceDesign personas, whose `prompt` is the whole voice.
  var customVoiceSpeaker: String? = nil

  /// What the Read Aloud voice picker shows. Mirrors `TTSVoice.displayName`'s shape so a
  /// VoiceDesign persona and a cloud voice read the same way in the same list.
  var displayName: String {
    "\(summary) (\(gender))"
  }

  /// The catalogue. German first: the app's users dictate and read German, and a German voice
  /// that sounds translated is the one complaint this list exists to prevent. Within each
  /// language the order runs narrator → audiobook → news → documentary → essay, i.e. from the
  /// general-purpose voice to the most specialised one.
  static let all: [Qwen3VoicePersona] = [
    // MARK: German — male
    Qwen3VoicePersona(
      id: "de-male-narrator",
      gender: "m",
      summary: String(localized: "German narrator (male, 40)"),
      language: "German",
      prompt: """
        Native German speaker, male, 40 years old, born and raised in Germany, clear Standard \
        German (Hochdeutsch), completely neutral accent, no foreign or English accent, warm, \
        calm, professional narrator voice, natural intonation and rhythm
        """
    ),
    Qwen3VoicePersona(
      id: "de-male-audiobook",
      gender: "m",
      summary: String(localized: "German audiobook (male, deep, suspenseful)"),
      language: "German",
      prompt: """
        Native German speaker, male, 55 years old, born and raised in Germany, deep resonant \
        serious voice, clear Standard German (Hochdeutsch), completely neutral accent, no \
        foreign or English accent, experienced audiobook narrator reading a historical novel, \
        measured pace, subtle suspense and dramatic tension, rich timbre, natural intonation \
        and rhythm
        """
    ),
    Qwen3VoicePersona(
      id: "de-male-news",
      gender: "m",
      summary: String(localized: "German newsreader (male, neutral)"),
      language: "German",
      prompt: """
        Native German speaker, male, 45 years old, born and raised in Germany, clear Standard \
        German (Hochdeutsch), completely neutral accent, no foreign or English accent, \
        authoritative neutral newsreader voice, even pace, precise articulation, restrained \
        emotion, natural intonation
        """
    ),
    Qwen3VoicePersona(
      id: "de-male-documentary",
      gender: "m",
      summary: String(localized: "German documentary (male, calm)"),
      language: "German",
      prompt: """
        Native German speaker, male, 50 years old, born and raised in Germany, clear Standard \
        German (Hochdeutsch), completely neutral accent, no foreign or English accent, calm \
        composed documentary narrator voice, unhurried pace, thoughtful and precise, warm but \
        restrained, natural intonation and rhythm
        """
    ),
    Qwen3VoicePersona(
      id: "de-male-essay",
      gender: "m",
      summary: String(localized: "German essay (male, distinguished)"),
      language: "German",
      prompt: """
        Native German speaker, male, 62 years old, born and raised in Germany, clear Standard \
        German (Hochdeutsch), completely neutral accent, no foreign or English accent, \
        distinguished mature voice with gravitas, serious and reflective, reading a philosophical \
        essay, deliberate pace, precise articulation, natural intonation and rhythm
        """
    ),

    // MARK: German — female
    Qwen3VoicePersona(
      id: "de-female-narrator",
      gender: "w",
      summary: String(localized: "German narrator (female, 35)"),
      language: "German",
      prompt: """
        Native German speaker, female, 35 years old, born and raised in Germany, clear Standard \
        German (Hochdeutsch), completely neutral accent, no foreign or English accent, warm, \
        friendly, professional narrator voice, natural intonation and rhythm
        """
    ),
    Qwen3VoicePersona(
      id: "de-female-audiobook",
      gender: "w",
      summary: String(localized: "German audiobook (female, warm, expressive)"),
      language: "German",
      prompt: """
        Native German speaker, female, 45 years old, born and raised in Germany, warm expressive \
        voice, clear Standard German (Hochdeutsch), completely neutral accent, no foreign or \
        English accent, experienced audiobook narrator, measured pace, gentle emotional colour, \
        natural intonation and rhythm
        """
    ),
    Qwen3VoicePersona(
      id: "de-female-news",
      gender: "w",
      summary: String(localized: "German newsreader (female, neutral)"),
      language: "German",
      prompt: """
        Native German speaker, female, 40 years old, born and raised in Germany, clear Standard \
        German (Hochdeutsch), completely neutral accent, no foreign or English accent, \
        authoritative neutral newsreader voice, even pace, precise articulation, restrained \
        emotion, natural intonation
        """
    ),
    Qwen3VoicePersona(
      id: "de-female-documentary",
      gender: "w",
      summary: String(localized: "German documentary (female, composed)"),
      language: "German",
      prompt: """
        Native German speaker, female, 48 years old, born and raised in Germany, clear Standard \
        German (Hochdeutsch), completely neutral accent, no foreign or English accent, calm \
        composed documentary narrator voice, unhurried pace, thoughtful and precise, warm but \
        restrained, natural intonation and rhythm
        """
    ),

    // MARK: English — male
    Qwen3VoicePersona(
      id: "en-male-narrator",
      gender: "m",
      summary: String(localized: "English narrator (male, 40)"),
      language: "English",
      prompt: """
        Native English speaker, male, 40 years old, clear General American English, neutral \
        accent, no foreign accent, warm, calm, professional narrator voice, natural intonation \
        and rhythm
        """
    ),
    Qwen3VoicePersona(
      id: "en-male-audiobook",
      gender: "m",
      summary: String(localized: "English audiobook (male, deep, suspenseful)"),
      language: "English",
      prompt: """
        Native English speaker, male, 55 years old, deep resonant serious voice, clear Received \
        Pronunciation British English, neutral accent, no foreign accent, experienced audiobook \
        narrator reading a historical novel, measured pace, subtle suspense and dramatic tension, \
        rich timbre, natural intonation and rhythm
        """
    ),
    Qwen3VoicePersona(
      id: "en-male-news",
      gender: "m",
      summary: String(localized: "English newsreader (male, neutral)"),
      language: "English",
      prompt: """
        Native English speaker, male, 45 years old, clear General American English, neutral \
        accent, no foreign accent, authoritative neutral newsreader voice, even pace, precise \
        articulation, restrained emotion, natural intonation
        """
    ),
    Qwen3VoicePersona(
      id: "en-male-documentary",
      gender: "m",
      summary: String(localized: "English documentary (male, calm)"),
      language: "English",
      prompt: """
        Native English speaker, male, 50 years old, clear Received Pronunciation British English, \
        neutral accent, no foreign accent, calm composed documentary narrator voice, unhurried \
        pace, thoughtful and precise, warm but restrained, natural intonation and rhythm
        """
    ),

    // MARK: English — female
    Qwen3VoicePersona(
      id: "en-female-narrator",
      gender: "w",
      summary: String(localized: "English narrator (female, 35)"),
      language: "English",
      prompt: """
        Native English speaker, female, 35 years old, clear General American English, neutral \
        accent, no foreign accent, warm, friendly, professional narrator voice, natural \
        intonation and rhythm
        """
    ),
    Qwen3VoicePersona(
      id: "en-female-audiobook",
      gender: "w",
      summary: String(localized: "English audiobook (female, warm, expressive)"),
      language: "English",
      prompt: """
        Native English speaker, female, 45 years old, warm expressive voice, clear Received \
        Pronunciation British English, neutral accent, no foreign accent, experienced audiobook \
        narrator, measured pace, gentle emotional colour, natural intonation and rhythm
        """
    ),
    Qwen3VoicePersona(
      id: "en-female-news",
      gender: "w",
      summary: String(localized: "English newsreader (female, neutral)"),
      language: "English",
      prompt: """
        Native English speaker, female, 40 years old, clear General American English, neutral \
        accent, no foreign accent, authoritative neutral newsreader voice, even pace, precise \
        articulation, restrained emotion, natural intonation
        """
    ),
  ]

  /// The persona a fresh install starts with: the German male narrator, because the default
  /// Read Aloud language for this app's users is German.
  static var `default`: Qwen3VoicePersona { all[0] }

  /// Resolves a stored id, falling back to the default when it is empty or no longer offered.
  /// Same contract as `ReadAloudPreferences.voice(for:)` for the cloud providers.
  static func persona(for id: String) -> Qwen3VoicePersona {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .default }
    return all.first { $0.id == trimmed } ?? .default
  }

  /// The picker's rows, in catalogue order (German narrators first, then the rest).
  static var pickerVoices: [TTSVoice] {
    all.map { TTSVoice(id: $0.id, gender: $0.gender, descriptor: $0.summary) }
  }

  // MARK: - CustomVoice speakers

  /// The nine fixed speakers of the 0.6B CustomVoice checkpoint (`spk_id` in its `config.json`).
  /// None of them is a German native, so the instruction below asks each one for the least
  /// accented German it can produce. This is the fast local option, not the accurate one — the
  /// VoiceDesign catalogue above is what a German listener should pick.
  static let customVoiceSpeakers: [Qwen3VoicePersona] = [
    Qwen3VoicePersona(
      id: "aiden", gender: "m",
      summary: String(localized: "Aiden (male, warm)"),
      language: "German",
      prompt: "Speak clear Standard German (Hochdeutsch) with a neutral accent and no English "
        + "accent, warm and natural, calm pace.",
      customVoiceSpeaker: "aiden"),
    Qwen3VoicePersona(
      id: "ryan", gender: "m",
      summary: String(localized: "Ryan (male, clear)"),
      language: "German",
      prompt: "Speak clear Standard German (Hochdeutsch) with a neutral accent and no English "
        + "accent, clear and steady, professional narrator.",
      customVoiceSpeaker: "ryan"),
    Qwen3VoicePersona(
      id: "eric", gender: "m",
      summary: String(localized: "Eric (male, lively)"),
      language: "German",
      prompt: "Speak clear Standard German (Hochdeutsch) with a neutral accent and no English "
        + "accent, lively and friendly, natural intonation.",
      customVoiceSpeaker: "eric"),
    Qwen3VoicePersona(
      id: "dylan", gender: "m",
      summary: String(localized: "Dylan (male, youthful)"),
      language: "German",
      prompt: "Speak clear Standard German (Hochdeutsch) with a neutral accent and no English "
        + "accent, youthful and relaxed, conversational.",
      customVoiceSpeaker: "dylan"),
    Qwen3VoicePersona(
      id: "uncle_fu", gender: "m",
      summary: String(localized: "Uncle Fu (male, mature)"),
      language: "German",
      prompt: "Speak clear Standard German (Hochdeutsch) with a neutral accent and no English "
        + "accent, mature and composed, measured pace.",
      customVoiceSpeaker: "uncle_fu"),
    Qwen3VoicePersona(
      id: "serena", gender: "w",
      summary: String(localized: "Serena (female, warm)"),
      language: "German",
      prompt: "Speak clear Standard German (Hochdeutsch) with a neutral accent and no English "
        + "accent, warm and natural, calm pace.",
      customVoiceSpeaker: "serena"),
    Qwen3VoicePersona(
      id: "vivian", gender: "w",
      summary: String(localized: "Vivian (female, clear)"),
      language: "German",
      prompt: "Speak clear Standard German (Hochdeutsch) with a neutral accent and no English "
        + "accent, clear and steady, professional narrator.",
      customVoiceSpeaker: "vivian"),
    Qwen3VoicePersona(
      id: "ono_anna", gender: "w",
      summary: String(localized: "Ono Anna (female, bright)"),
      language: "German",
      prompt: "Speak clear Standard German (Hochdeutsch) with a neutral accent and no English "
        + "accent, bright and friendly, natural intonation.",
      customVoiceSpeaker: "ono_anna"),
    Qwen3VoicePersona(
      id: "sohee", gender: "w",
      summary: String(localized: "Sohee (female, soft)"),
      language: "German",
      prompt: "Speak clear Standard German (Hochdeutsch) with a neutral accent and no English "
        + "accent, soft and gentle, unhurried pace.",
      customVoiceSpeaker: "sohee"),
  ]

  /// The CustomVoice picker's rows.
  static var customVoicePickerVoices: [TTSVoice] {
    customVoiceSpeakers.map { TTSVoice(id: $0.id, gender: $0.gender, descriptor: $0.summary) }
  }

  /// Resolves a stored CustomVoice speaker id, falling back to the first speaker.
  static func customVoiceSpeaker(for id: String) -> Qwen3VoicePersona {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return customVoiceSpeakers[0] }
    return customVoiceSpeakers.first { $0.id == trimmed } ?? customVoiceSpeakers[0]
  }
}
