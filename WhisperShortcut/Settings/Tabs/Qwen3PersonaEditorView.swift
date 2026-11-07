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
    .frame(width: 560, height: 420)
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
      Text("No own voices yet. Add one and describe how it should sound — it then appears in the Read Aloud voice picker.")
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

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SheetHeader(
        title: existing == nil ? "Add voice" : "Edit voice",
        subtitle: "Describe the voice in one or two sentences. English descriptions work best.")

      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 16) {
          labeledField("Name:") {
            TextField("e.g. Grandpa", text: $name)
          }
          labeledField("Gender:") {
            Picker("", selection: $gender) {
              Text("Male").tag("m")
              Text("Female").tag("w")
            }
            .pickerStyle(MenuPickerStyle())
          }
          labeledField("Language:") {
            Picker("", selection: $language) {
              Text("German").tag("German")
              Text("English").tag("English")
            }
            .pickerStyle(MenuPickerStyle())
          }
        }

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
          onSaved()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
          || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
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
      }
    }
  }

  private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.body.weight(.medium))
      content()
    }
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
    Qwen3CustomPersonas.save(
      Qwen3VoicePersona(
        id: id, gender: gender, summary: trimmedName, language: language, prompt: trimmedPrompt))
    // Only a changed description (or language) invalidates the frozen voice — the voice is the
    // description. Renaming or flipping the gender label keeps it; a needless reset costs a
    // full calibration generation on the 1.7B checkpoint.
    if let existing,
      existing.prompt != trimmedPrompt || existing.language != language
    {
      Qwen3VoiceReferenceStore.removeReference(for: id)
    }
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
