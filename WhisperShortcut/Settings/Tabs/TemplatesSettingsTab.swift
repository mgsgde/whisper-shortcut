import SwiftUI

/// Settings → Templates. A template is a recurring format (a treatment note with Anamnese, Befund,
/// Therapie) that a dictation comes back in. It has its own sidebar tab because it has its own
/// shortcut, like Screenshot and Read Aloud; Dictate Prompt is left exactly as it was.
///
/// Built to be understood without a manual, top to bottom:
/// - Nothing saved: one example and the Add button. A key for nothing would only confuse.
/// - The key first, with the three steps it takes spelled out using that key ("Press ⌘3, Speak,
///   Press ⌘3 again"): without it a template does nothing.
/// - The templates: a numbered dropdown heads the card and picks the one being edited, so the tab
///   stays one card however many there are. Name and Format follow it directly; the Format box
///   grows with its text, so the page scrolls and the box never does. A template's own key is
///   folded away; it is for a dictation microphone's buttons, and most people never need it.
/// Orange is reserved for a key that does not work; everything else is plain secondary text.
///
/// With no template saved the `dictationTemplates` key stays absent and nothing changes.
struct TemplatesSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  @State private var templates: [DictationTemplate] = []
  @State private var pickerShortcut: ShortcutDefinition?
  /// The template shown in the editor.
  @State private var selectedID: UUID?
  @State private var confirmsRemove = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Templates",
        systemImage: "doc.text",
        subtitle: "Dictate straight into a fixed format, such as a treatment note."
      )
      if templates.isEmpty {
        emptyState
      } else {
        // The key first: it is what makes a template do anything, so it must not hide below the fold.
        keyCard
        templatesCard
      }
    }
    .onAppear {
      templates = DictationTemplateStore.load()
      pickerShortcut = DictationTemplateStore.loadPickerShortcut()
      selectedID = DictationTemplateStore.lastUsedTemplateID.flatMap { id in
        templates.contains { $0.id == id } ? id : nil
      } ?? templates.first?.id
    }
    .onChange(of: templates) { _, newValue in
      // Only real edits are written: a user who just opens Settings keeps the key absent.
      guard newValue != DictationTemplateStore.load() else { return }
      DictationTemplateStore.save(newValue)
    }
    .onChange(of: pickerShortcut) { _, newValue in
      guard newValue != DictationTemplateStore.loadPickerShortcut() else { return }
      DictationTemplateStore.savePickerShortcut(newValue)
    }
  }

  // MARK: - Choosing a template

  /// The dropdown is the card's header and picks the template shown below it. Numbered like the
  /// list on the recording card, so "press 2" means the same thing in both places.
  private var templatesCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      templateBar
      if let index = templates.firstIndex(where: { $0.id == selectedID }) {
        TemplateEditor(
          template: $templates[index],
          focusedField: $focusedField,
          keyNote: ownKeyNote(for: templates[index]),
          findConflict: { candidate in conflict(for: candidate, template: templates[index].id) },
          clear: clear)
        .id(templates[index].id)
      }
    }
    .padding(SettingsConstants.rowPadding)
    .cardChrome()
    .confirmationDialog(
      Text("Delete \u{201C}\(selectedTemplate?.displayName ?? "")\u{201D}?"),
      isPresented: $confirmsRemove
    ) {
      Button("Delete", role: .destructive, action: removeSelected)
    }
  }

  private var selectedTemplate: DictationTemplate? {
    templates.first { $0.id == selectedID }
  }

  private var templateBar: some View {
    // No "Template" label: the picker shows the name, and a label would say it a second time.
    HStack(spacing: 16) {
      HStack(spacing: 8) {
        Picker("Template", selection: $selectedID) {
          ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
            Text("\(index + 1)  \(template.displayName)").tag(Optional(template.id))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .pointerCursorOnHover()

        Button(action: addTemplate) {
          Image(systemName: "plus")
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .help("Add Template")
        .accessibilityLabel(String(localized: "Add Template"))
        .pointerCursorOnHover()

        Button(action: { confirmsRemove = true }) {
          Image(systemName: "trash")
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .help("Remove this template")
        .accessibilityLabel(String(localized: "Remove this template"))
        .pointerCursorOnHover()
      }
      Spacer(minLength: 0)
    }
  }

  private func addTemplate() {
    let template = DictationTemplate()
    templates.append(template)
    selectedID = template.id
  }

  private func removeSelected() {
    guard let index = templates.firstIndex(where: { $0.id == selectedID }) else { return }
    templates.remove(at: index)
    selectedID = templates.isEmpty ? nil : templates[min(index, templates.count - 1)].id
  }

  // MARK: - Empty state

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("For example a treatment note: you speak as usual, and the note comes back with Anamnese, Befund and Therapie.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      addButton
    }
    .padding(SettingsConstants.rowPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardChrome()
  }

  private var addButton: some View {
    Button(action: addTemplate) {
      Label("Add Template", systemImage: "plus")
        .font(.callout)
    }
    .buttonStyle(.bordered)
    .help("Add a format to dictate into")
    .pointerCursorOnHover()
  }

  // MARK: - The Template key

  private var usableCount: Int { templates.filter(\.isUsable).count }

  private var keyCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      ShortcutRecorderRow(
        label: "Shortcut",
        shortcut: $pickerShortcut,
        focusedField: .templatePickerShortcut,
        currentFocus: $focusedField,
        findConflict: { candidate, _ in pickerConflict(for: candidate) },
        clearShortcut: clear
      )
      if let note = pickerNote {
        captionRow(note.text, reassign: note.reassign)
      } else {
        // Only a key that works gets the steps; next to a warning they would promise too much.
        steps
      }

      VStack(alignment: .leading, spacing: 3) {
        if usableCount > 1 {
          hint("With several templates, press 1, 2, 3 … while you speak to choose one. It starts on the one you used last.")
        }
        hint("Press Tab while you speak to skip the format this time.")
        hint("If text is selected, the key edits that text instead.")
      }
    }
    .padding(SettingsConstants.rowPadding)
    .cardChrome()
  }

  /// "Press ⌘3 › Speak › Press ⌘3 again", with the key the user recorded, so the explanation is
  /// the actual gesture rather than a description of one.
  private var steps: some View {
    let key = pickerShortcut.flatMap { $0.isEnabled ? $0.displayString : nil }
    return HStack(spacing: 8) {
      step(key.map { String(localized: "Press \($0)") } ?? String(localized: "Press the key"))
      chevron
      step(String(localized: "Speak"))
      chevron
      step(key.map { String(localized: "Press \($0) again") } ?? String(localized: "Press it again"))
    }
    .accessibilityElement(children: .combine)
  }

  private func step(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.secondary.opacity(0.12))
      )
  }

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.caption2.weight(.semibold))
      .foregroundColor(.secondary)
      .accessibilityHidden(true)
  }

  private func hint(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// Why the Template key does nothing yet, or nil when it works.
  private var pickerNote: (text: String, reassign: Reassign?)? {
    guard let shortcut = pickerShortcut, shortcut.isEnabled else { return nil }
    if usableCount == 0 {
      return (String(localized: "Give a template instructions to use this key."), nil)
    }
    guard
      let owner = TemplateShortcuts.pickerOwner(
        pickerShortcut: shortcut, templates: templates, appConfig: appConfig)
    else { return nil }
    let text = String(localized: "\(shortcut.displayString) is already used by \(owner.localizedName). Take it from there, or record a different key.")
    return (text, reassign(for: owner, excludingTemplate: nil, shortcut: shortcut))
  }

  /// Why a template's own key does nothing, or nil when it works or has none.
  private func ownKeyNote(for template: DictationTemplate) -> (text: String, reassign: Reassign?)? {
    guard let shortcut = template.shortcut, shortcut.isEnabled, template.isUsable,
      let owner = TemplateShortcuts.owner(
        of: template, in: templates, appConfig: appConfig, pickerShortcut: pickerShortcut)
    else { return nil }
    let text = String(localized: "\(shortcut.displayString) is already used by \(owner.localizedName). Take it from there, or record a different key.")
    return (text, reassign(for: owner, excludingTemplate: template.id, shortcut: shortcut))
  }

  /// Takes the key from whoever has it. The button names the loser, so it is clear which way it goes.
  private func reassign(
    for owner: TemplateShortcutOwner, excludingTemplate id: UUID?, shortcut: ShortcutDefinition
  ) -> Reassign? {
    let action: (() -> Void)?
    switch owner {
    case .app(let name):
      action = Self.appField(named: name).map { field in { clear(field) } }
    case .picker:
      action = { clear(.templatePickerShortcut) }
    case .template:
      action = templateConflict(shortcut, excluding: id).map { conflict in { clear(conflict.field) } }
    }
    return action.map { Reassign(title: String(localized: "Take it from \(owner.localizedName)"), action: $0) }
  }

  private func captionRow(_ text: String, reassign: Reassign?) -> some View {
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
          Button(reassign.title, action: reassign.action)
            .buttonStyle(.bordered)
            .controlSize(.small)
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

  /// A key recorded for the Template key: an app shortcut beats it, and it beats a template's own
  /// key, so the recorder offers to take it from either.
  private func pickerConflict(for candidate: ShortcutDefinition) -> ShortcutConflict? {
    if case .app(let name)? = TemplateShortcuts.owner(
      key: candidate.key, modifiers: candidate.modifiers, templates: [],
      excludingTemplateID: nil, appConfig: appConfig)
    {
      return Self.appField(named: name).map { ShortcutConflict(field: $0, label: name) }
    }
    return templateConflict(candidate, excluding: nil)
  }

  /// A key recorded for a template's own key.
  private func conflict(for candidate: ShortcutDefinition, template id: UUID) -> ShortcutConflict? {
    switch TemplateShortcuts.owner(
      key: candidate.key, modifiers: candidate.modifiers, templates: templates,
      excludingTemplateID: id, appConfig: appConfig, pickerShortcut: pickerShortcut)
    {
    case .app(let name)?:
      return Self.appField(named: name).map { ShortcutConflict(field: $0, label: name) }
    case .picker?:
      return ShortcutConflict(field: .templatePickerShortcut, label: String(localized: "Template"))
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
  /// template recorders only write the template list and the Template key.
  private func clear(_ field: SettingsFocusField) {
    switch field {
    case .templatePickerShortcut:
      pickerShortcut = nil
    case .templateShortcut(let id):
      if let index = templates.firstIndex(where: { $0.id == id }) {
        templates[index].shortcut = nil
      }
    default:
      viewModel.clearShortcut(for: field)
      Task { await viewModel.saveSettings() }
    }
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

// MARK: - The selected template

private struct TemplateEditor: View {
  @Binding var template: DictationTemplate
  @FocusState.Binding var focusedField: SettingsFocusField?
  let keyNote: (text: String, reassign: Reassign?)?
  let findConflict: (ShortcutDefinition) -> ShortcutConflict?
  let clear: (SettingsFocusField) -> Void

  @State private var showsOwnKey = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        Text("Name")
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
        TextField("e.g. Treatment note", text: $template.name)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(String(localized: "Template name"))
      }

      instructionsEditor
      ownKey
    }
    .onAppear { showsOwnKey = template.shortcut != nil }
  }

  private var instructionsEditor: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Format")
        .padding(.bottom, 2)
      ZStack(alignment: .topLeading) {
        // Invisible copy of the text that sizes the box, so a 30-line prompt shows all 30 lines
        // instead of 8 behind a second scrollbar inside the scrolling page. The extra line keeps
        // room for the caret after a trailing newline.
        Text(template.instructions + "\n ")
          .font(.system(.callout))
          .padding(.horizontal, 5)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .hidden()
          .accessibilityHidden(true)
        TextEditor(text: $template.instructions)
          .font(.system(.callout))
          .scrollContentBackground(.hidden)
          .scrollDisabled(true)
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
      .frame(minHeight: 140, alignment: .topLeading)
      .padding(6)
      .background(Color(nsColor: .textBackgroundColor))
      .cornerRadius(SettingsConstants.cornerRadius)
      .overlay(
        RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )
      Text(template.isUsable
        ? "What you say is written down as usual, then put into this format."
        : "Describe the format to use this template.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Folded unless the template already has one: the Template key covers almost everyone.
  private var ownKey: some View {
    DisclosureGroup(isExpanded: $showsOwnKey) {
      VStack(alignment: .leading, spacing: 6) {
        ShortcutRecorderRow(
          label: "Shortcut",
          shortcut: $template.shortcut,
          focusedField: .templateShortcut(template.id),
          currentFocus: $focusedField,
          findConflict: { candidate, _ in findConflict(candidate) },
          clearShortcut: clear
        )
        if let keyNote {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption2)
              .foregroundColor(.orange)
            Text(keyNote.text)
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if let reassign = keyNote.reassign {
              Button(reassign.title, action: reassign.action)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
          }
        }
        Text("Starts this template directly, without choosing.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 6)
    } label: {
      Text("Separate key, e.g. for a dictation microphone (optional)")
        .font(.callout)
        .foregroundColor(.secondary)
    }
  }
}

/// A Reassign button: what it says ("Take it from Screenshot") and what it clears.
private struct Reassign {
  let title: String
  let action: () -> Void
}
