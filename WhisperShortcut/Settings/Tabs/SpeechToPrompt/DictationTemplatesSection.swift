import SwiftUI

/// Settings → Dictate Prompt → Templates. A template is a recurring format (a treatment note with
/// Anamnese, Befund, Therapie) with its own global shortcut: press it, dictate, press again, and the
/// dictation comes back in that format. The generic Dictate Prompt keeps its own shortcut, so the
/// format never forces itself onto an email. Kept apart from Quick Prompts on purpose: a quick
/// prompt replaces what was said, a template works on it.
///
/// The key overview at the top is the one place a practice set-up needs: it edits Dictate Prompt's
/// shortcut next to every template's, so "⌘2 → Praxisnotiz, ⌘3 → Dictate Prompt" is two recorder
/// clicks, and a combination two actions share is named there instead of silently losing.
///
/// With no template saved the `dictationTemplates` key stays absent and nothing changes.
struct DictationTemplatesSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  @State private var templates: [DictationTemplate] = []

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Templates",
        systemImage: "doc.text",
        subtitle: "Give a recurring format its own shortcut: press it, dictate, press it again, and what you said comes back in that format. Tab while recording skips the template once. With text selected, the shortcut edits it like Dictate Prompt."
      )

      VStack(alignment: .leading, spacing: 12) {
        if !templates.isEmpty {
          shortcutOverview
        }

        ForEach($templates) { $template in
          TemplateCard(
            template: $template,
            onRemove: { templates.removeAll { $0.id == template.id } })
        }

        Button(action: { templates.append(DictationTemplate()) }) {
          Label("Add Template", systemImage: "plus")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Add a format with its own shortcut")
        .pointerCursorOnHover()
      }
    }
    .onAppear { templates = DictationTemplateStore.load() }
    .onChange(of: templates) { _, newValue in
      // Only real edits are written: a user who just opens Settings keeps the key absent.
      guard newValue != DictationTemplateStore.load() else { return }
      DictationTemplateStore.save(newValue)
    }
  }

  // MARK: - Key overview

  /// Dictate Prompt's shortcut and every template's, editable, with the conflicts that decide which
  /// one a key actually starts.
  private var shortcutOverview: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Shortcuts")
        .font(.callout)
        .fontWeight(.semibold)

      ShortcutRecorderRow(
        label: LocalizedStringKey(ShortcutAction.dictatePrompt.title),
        shortcut: $viewModel.data.togglePrompting,
        focusedField: .togglePrompting,
        currentFocus: $focusedField,
        onChanged: { Task { await viewModel.saveSettings() } },
        findConflict: { candidate, field in
          viewModel.findShortcutConflict(candidate, for: field)
            ?? templateConflict(candidate, excluding: nil)
        },
        clearShortcut: clear
      )

      ForEach($templates) { $template in
        VStack(alignment: .leading, spacing: 2) {
          ShortcutRecorderRow(
            label: LocalizedStringKey(template.displayName),
            shortcut: $template.shortcut,
            focusedField: .templateShortcut(template.id),
            currentFocus: $focusedField,
            findConflict: { candidate, _ in conflict(for: candidate, template: template.id) },
            clearShortcut: clear
          )
          if let note = overviewNote(for: template) {
            captionRow(note.text, reassign: note.reassign)
          }
        }
      }

      Text("Press once to start, again to stop. They work in every app.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(SettingsConstants.rowPadding)
    .cardChrome()
  }

  /// Why a saved template shortcut does nothing yet, or nil when it works. A key another action owns
  /// comes with Reassign, so the practice set-up (Dictate Prompt to ⌘3, then the template to ⌘2)
  /// never ends in a template that silently does nothing.
  private func overviewNote(for template: DictationTemplate) -> (text: String, reassign: (() -> Void)?)? {
    guard template.isUsable else {
      return (String(localized: "Not active yet: add the instructions below."), nil)
    }
    guard let shortcut = template.shortcut, shortcut.isEnabled else {
      return (String(localized: "Record a shortcut to use this template."), nil)
    }
    guard let owner = TemplateShortcuts.owner(of: template, in: templates, appConfig: appConfig) else {
      return nil
    }
    let text = String(localized: "\(shortcut.displayString) belongs to \(ownerName(owner)), so this template does not start yet.")
    let reassign: (() -> Void)?
    switch owner {
    case .app(let name):
      reassign = Self.appField(named: name).map { field in { clear(field) } }
    case .template:
      reassign = templateConflict(shortcut, excluding: template.id).map { conflict in { clear(conflict.field) } }
    }
    return (text, reassign)
  }

  private func ownerName(_ owner: TemplateShortcutOwner) -> String {
    switch owner {
    case .app(let name): return name
    case .template(let name): return name
    }
  }

  private func captionRow(_ text: String, reassign: (() -> Void)?) -> some View {
    // Same column as the recorder field above it, so the note never runs past its Record button.
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Spacer().frame(width: SettingsConstants.labelWidth + 16)
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption2)
        .foregroundColor(.orange)
      VStack(alignment: .leading, spacing: 6) {
        Text(text)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let reassign {
          Button("Reassign", action: reassign)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Take the key away from the other action and give it to this template")
        }
      }
      .frame(maxWidth: SettingsConstants.shortcutMaxWidth - 20, alignment: .leading)
      Spacer(minLength: 0)
    }
  }

  // MARK: - Conflicts

  /// The app's shortcuts as they are in this form right now, saved or not.
  private var appConfig: ShortcutConfig {
    SettingsViewModel.shortcutConfig(from: viewModel.data)
  }

  /// A recorded key for a template: an app shortcut or another template may already own it.
  private func conflict(for candidate: ShortcutDefinition, template id: UUID) -> ShortcutConflict? {
    switch TemplateShortcuts.owner(
      key: candidate.key, modifiers: candidate.modifiers, templates: templates,
      excludingTemplateID: id, appConfig: appConfig)
    {
    case .app(let name)?:
      guard let field = Self.appField(named: name) else { return nil }
      return ShortcutConflict(field: field, label: name)
    case .template?:
      return templateConflict(candidate, excluding: id)
    case nil:
      return nil
    }
  }

  /// The first other template using `candidate`, as a recorder conflict its Reassign can clear.
  private func templateConflict(_ candidate: ShortcutDefinition, excluding id: UUID?) -> ShortcutConflict? {
    guard
      let owner = templates.first(where: { other in
        guard other.id != id, other.isUsable, let shortcut = other.shortcut, shortcut.isEnabled else {
          return false
        }
        return shortcut.key == candidate.key && shortcut.modifiers == candidate.modifiers
      })
    else { return nil }
    return ShortcutConflict(field: .templateShortcut(owner.id), label: owner.displayName)
  }

  /// Reassign: frees the slot that owned the key. App slots are saved right away, because the
  /// template recorder's own change only writes the template list.
  private func clear(_ field: SettingsFocusField) {
    if case .templateShortcut(let id) = field {
      if let index = templates.firstIndex(where: { $0.id == id }) {
        templates[index].shortcut = nil
      }
      return
    }
    viewModel.clearShortcut(for: field)
    Task { await viewModel.saveSettings() }
  }

  /// Matches the names `TemplateShortcuts` gives app shortcuts back to their Settings fields.
  private static func appField(named name: String) -> SettingsFocusField? {
    let fields: [(String, SettingsFocusField)] = [
      (String(localized: "Dictate"), .toggleDictation),
      (String(localized: "Dictate Prompt"), .togglePrompting),
      (String(localized: "Screenshot"), .screenshotCapture),
      (String(localized: "Read Aloud"), .readAloudShortcut),
      (String(localized: "Add to Glossary"), .addToGlossaryShortcut),
      (String(localized: "Chat"), .toggleChat),
      (String(localized: "Settings"), .toggleSettings),
    ]
    return fields.first { $0.0 == name }?.1
  }
}

// MARK: - One template

private struct TemplateCard: View {
  @Binding var template: DictationTemplate
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "doc.text")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.secondary)
          .frame(width: 18, alignment: .center)
          .accessibilityHidden(true)
        TextField("Name, e.g. Treatment note", text: $template.name)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(String(localized: "Template name"))
        Button(action: onRemove) {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove this template")
        .accessibilityLabel(String(localized: "Remove template \(template.displayName)"))
        .pointerCursorOnHover()
      }

      instructionsEditor
    }
    .padding(SettingsConstants.rowPadding)
    .cardChrome()
  }

  private var instructionsEditor: some View {
    VStack(alignment: .leading, spacing: 4) {
      ZStack(alignment: .topLeading) {
        TextEditor(text: $template.instructions)
          .font(.system(.callout))
          .scrollContentBackground(.hidden)
          .accessibilityLabel(String(localized: "Template instructions"))
        if template.instructions.isEmpty {
          Text("Instructions, e.g. \u{201C}The dictation is a treatment note. Write it with the sections Anamnese, Befund, Therapie. Add nothing, leave nothing out.\u{201D}")
            .font(.callout)
            .foregroundColor(Color(nsColor: .placeholderTextColor))
            .padding(.horizontal, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      .frame(height: 140)
      .padding(6)
      .background(Color(nsColor: .textBackgroundColor))
      .cornerRadius(SettingsConstants.cornerRadius)
      .overlay(
        RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )
      Text("Sent instead of the Dictate Prompt system prompt for that run. Your speech is transcribed as usual, with your Glossary, and is the text these instructions work on.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
