//
//  Qwen3PersonaEditorView.swift
//  WhisperShortcut
//
//  Editor for user-defined Qwen3 VoiceDesign personas.
//
//  The audience is not a prompt engineer: two fields (name, description), one language picker,
//  one gender picker, save. The placeholder description shows the shape that works — the
//  built-in personas' trick of naming the language, the region and the absence of a foreign
//  accent — so even a first-time user writes something that produces a native-sounding voice.
//

import SwiftUI
import UniformTypeIdentifiers

struct Qwen3PersonaEditorView: View {
  /// Dismisses the sheet.
  @Environment(\.dismiss) private var dismiss

  @State private var personas: [Qwen3VoicePersona] = []
  @State private var editingPersona: Qwen3VoicePersona?
  @State private var showNewPersonaSheet = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SheetHeader(title: "My own voices", subtitle: "Your own Read Aloud voices for the on-device Qwen3 model.")

      if personas.isEmpty {
        emptyState
      } else {
        List {
          ForEach(personas) { persona in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                // Verbatim: a persona's name is either the user's own text or a built-in summary
                // that was localized where it was defined. Passing it as a `LocalizedStringKey`
                // would look up the user's words in the catalogue.
                Text(verbatim: persona.summary)
                  .font(.body.weight(.medium))
                Text(persona.language == "English" ? String(localized: "English") : String(localized: "German"))
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              Spacer()
              Button("Edit") { editingPersona = persona }
                .buttonStyle(.link)
              Button("Delete", role: .destructive) {
                Qwen3CustomPersonas.delete(id: persona.id)
                personas = Qwen3CustomPersonas.all
              }
              .buttonStyle(.link)
            }
            .padding(.vertical, 2)
          }
        }
        .listStyle(.inset)
      }

      HStack {
        Button {
          showNewPersonaSheet = true
        } label: {
          Label("Add voice", systemImage: "plus")
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 560, height: 560)
    .onAppear { personas = Qwen3CustomPersonas.all }
    .sheet(isPresented: $showNewPersonaSheet) {
      Qwen3PersonaFormView(existing: nil) {
        personas = Qwen3CustomPersonas.all
      }
    }
    .sheet(item: $editingPersona) { persona in
      Qwen3PersonaFormView(existing: persona) {
        personas = Qwen3CustomPersonas.all
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: "person.wave.2")
        .font(.system(size: 36))
        .foregroundColor(.secondary)
      Text("No own voices yet. Add one — describe how it should sound, or clone it from a recording. It then appears in the Read Aloud voice picker.")
        .font(.callout)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      Spacer()
    }
  }
}

/// The form for one persona: name, gender, language, description. Used for both creating and
/// editing; `existing` is nil for a new one.
struct Qwen3PersonaFormView: View {
  @Environment(\.dismiss) private var dismiss

  let existing: Qwen3VoicePersona?
  var onSaved: () -> Void

  @State private var name = ""
  @State private var gender = "m"
  @State private var language = "German"
  @State private var prompt = ""
  /// Whether this persona's voice comes from a recording instead of a description. With a
  /// recording the description is meaningless — the clip *is* the voice — so the form hides it
  /// and stops requiring it.
  @State private var usesRecording = false
  /// A reference recording the user picked. Its voice replaces the described one for this persona.
  @State private var referenceURL: URL?
  /// What the reference recording says. Optional: empty means "transcribe it on this Mac".
  @State private var referenceTranscript = ""
  @State private var isImportingReference = false
  @State private var referenceError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SheetHeader(
        title: existing == nil ? "Add voice" : "Edit voice",
        subtitle: usesRecording
          ? "The voice comes from your recording — no description needed."
          : "Describe the voice in one or two sentences. English descriptions work best.")

      VStack(alignment: .leading, spacing: 12) {
        Picker("", selection: $usesRecording) {
          Text("Describe a voice").tag(false)
          Text("Clone from a recording").tag(true)
        }
        .pickerStyle(SegmentedPickerStyle())
        .labelsHidden()

        HStack(spacing: 16) {
          labeledField("Name:") {
            TextField("e.g. Grandpa", text: $name)
          }
          if !usesRecording {
            labeledField("Gender:") {
              Picker("", selection: $gender) {
                Text("Male").tag("m")
                Text("Female").tag("w")
              }
              .pickerStyle(MenuPickerStyle())
            }
          }
          labeledField("Language:") {
            Picker("", selection: $language) {
              Text("German").tag("German")
              Text("English").tag("English")
            }
            .pickerStyle(MenuPickerStyle())
          }
        }

        if usesRecording {
          referenceSection
        } else {
          descriptionSection
        }
      }

      HStack {
        if existing != nil {
          Button("Delete voice", role: .destructive) {
            if let existing {
              Qwen3CustomPersonas.delete(id: existing.id)
            }
            onSaved()
            dismiss()
          }
        }
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          save()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          isImportingReference
            || name.trimmingCharacters(in: .whitespaces).isEmpty
            || (!usesRecording && prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            || (usesRecording && referenceURL == nil))
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear {
      if let existing {
        name = existing.summary
        gender = existing.gender
        language = existing.language
        prompt = existing.prompt
        // A persona whose voice came from a recording opens in clone mode: its description is
        // not what produces the voice, so showing it as the editable source would be a lie.
        usesRecording = Qwen3VoiceReferenceStore.isUserProvided(for: existing.id)
      }
    }
  }

  /// The description editor — only shown when the voice is described rather than cloned.
  @ViewBuilder
  private var descriptionSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Description:")
        .font(.body.weight(.medium))
      TextEditor(text: $prompt)
        .font(.body)
        .frame(height: 110)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(alignment: .topLeading) {
          if prompt.isEmpty {
            Text(placeholderPrompt)
              .font(.body)
              .foregroundColor(Color(nsColor: .placeholderTextColor))
              .padding(.horizontal, 6)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
        }
      Text("Tip: name the language, the region and the absence of a foreign accent — that is what makes the voice sound native.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.body.weight(.medium))
      content()
    }
  }

  /// Optional reference recording. A clip makes the persona speak in *that* voice instead of a
  /// described one — the checkpoint's ICL path needs the audio and its transcript, so the user can
  /// type the text or let the on-device ASR checkpoint transcribe it.
  @ViewBuilder
  private var referenceSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Only clone a voice with the consent of the person it belongs to. The recording stays on this Mac.")
        .font(.caption)
        .foregroundColor(.secondary)

      Text("Reference recording:")
        .font(.body.weight(.medium))

      HStack(spacing: 12) {
        Button {
          pickReferenceFile()
        } label: {
          Label("Choose audio file…", systemImage: "waveform.badge.plus")
        }
        .disabled(isImportingReference)

        if let referenceURL {
          Text(referenceURL.lastPathComponent)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Button("Remove") {
            self.referenceURL = nil
            referenceTranscript = ""
            referenceError = nil
          }
          .buttonStyle(.link)
        }

        if isImportingReference {
          ProgressView().controlSize(.small)
        }
      }

      TextField("What the recording says (leave empty to transcribe it on this Mac)", text: $referenceTranscript)
        .textFieldStyle(.roundedBorder)
        .disabled(referenceURL == nil)

      if let referenceError {
        Text(referenceError)
          .font(.caption)
          .foregroundColor(.red)
      }

      Text("Use a clean, single-speaker clip of 3–15 seconds. WAV, MP3, M4A, AIFF, CAF and FLAC work.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  /// The audio formats the picker offers. Everything `AVAudioFile` can decode on macOS, which is
  /// what `AudioFileMonoLoader` uses: WAV, MP3, M4A/AAC, AIFF, CAF and FLAC. Listed explicitly rather
  /// than as `.audio` so the panel's filter matches the sentence under it, and so a format that
  /// cannot be decoded is not offered in the first place.
  private static let referenceAudioTypes: [UTType] = [
    .wav, .mp3, .mpeg4Audio, .aiff,
    UTType("com.apple.coreaudio-format") ?? .audio,
    UTType("org.xiph.flac") ?? .audio,
  ]

  /// Opens a picker for an audio file. The clip is not copied yet — it is imported on Save, so
  /// cancelling the form leaves no half-imported voice behind.
  private func pickReferenceFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = Self.referenceAudioTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = String(localized: "Choose a short recording of the voice this persona should speak in.")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    referenceURL = url
    referenceError = nil
  }

  /// The placeholder doubles as the template that produces good voices — see the tip below it.
  private var placeholderPrompt: String {
    language == "English"
      ? "e.g. Native English speaker, female, 35 years old, British, warm and calm, professional narrator voice, natural intonation"
      : "e.g. Native German speaker, male, 60 years old, born and raised in Germany, clear Standard German (Hochdeutsch), no foreign or English accent, deep and calm narrator voice"
  }

  private func save() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = existing?.id ?? Qwen3CustomPersonas.uniqueID(for: trimmedName)
    // A cloned persona has no description to store. The prompt is only ever read by the
    // VoiceDesign calibration path, which a user-provided clip bypasses, so an empty string is
    // the honest value — not a placeholder sentence the user never wrote.
    let persona = Qwen3VoicePersona(
      id: id, gender: gender, summary: trimmedName, language: language,
      prompt: usesRecording ? "" : trimmedPrompt)
    Qwen3CustomPersonas.save(persona)

    if let referenceURL {
      // Importing is the slow part (decode, resample, maybe a local transcription), so the form
      // stays open with a spinner instead of closing and leaving the user without feedback.
      isImportingReference = true
      referenceError = nil
      Task {
        defer { isImportingReference = false }
        do {
          _ = try await Qwen3TTSService.shared.importVoiceReference(
            from: referenceURL, for: persona, transcript: referenceTranscript)
          onSaved()
          dismiss()
        } catch {
          referenceError = error.localizedDescription
        }
      }
      return
    }

    // Only a changed description (or language) invalidates the frozen voice — the voice is the
    // description. Renaming or flipping the gender label keeps it; a needless reset costs a
    // full calibration generation on the 1.7B checkpoint. A clip the user imported is never
    // discarded here: the description no longer defines that voice.
    if let existing,
      existing.prompt != trimmedPrompt || existing.language != language,
      !Qwen3VoiceReferenceStore.isUserProvided(for: id)
    {
      Qwen3VoiceReferenceStore.removeReference(for: id)
    }
    // Switching a cloned persona back to "describe a voice" drops the imported clip, or the
    // description would be stored and then ignored by the next Read Aloud.
    if !usesRecording, Qwen3VoiceReferenceStore.isUserProvided(for: id) {
      Qwen3VoiceReferenceStore.removeReference(for: id)
    }
    onSaved()
    dismiss()
  }
}

/// Small reusable sheet header, matching the Settings look.
private struct SheetHeader: View {
  let title: LocalizedStringResource
  let subtitle: LocalizedStringResource

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.title2)
        .fontWeight(.semibold)
      Text(subtitle)
        .font(.callout)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding([.horizontal, .top], 20)
  }
}
