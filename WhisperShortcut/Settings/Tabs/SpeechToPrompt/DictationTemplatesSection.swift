import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Dictate Prompt → Template. One default template: whenever nothing is selected,
/// stopping a Dictate Prompt recording applies it to the dictation (Tab while recording runs
/// without it). It can optionally be limited to certain apps, off by default — practice software
/// often runs in a browser, where the app alone cannot tell a note from webmail. Kept apart from
/// Quick Prompts on purpose: a quick prompt replaces what was said, a template works on it.
///
/// Read by `DictationTemplateStore.current()` on every ⌘2, so an edit here applies to the next
/// recording. With no template saved the key stays absent and nothing changes for the user.
/// Stored as a list so more templates can follow without a migration; the UI offers one.
struct DictationTemplatesSection: View {
  @State private var templates: [DictationTemplate] = []

  /// One default template; Tab switches between it and a normal run, which only works with one.
  private static let maxTemplates = 1

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Template",
        systemImage: "doc.text",
        subtitle: "Formats what you dictate, for example as a treatment note with Anamnese, Befund and Therapie. With nothing selected, stopping the recording applies it; press Tab while recording to run without it, e.g. for an email. With text selected, Dictate Prompt edits it as usual."
      )

      VStack(alignment: .leading, spacing: 12) {
        ForEach($templates) { $template in
          TemplateCard(
            template: $template,
            onRemove: { templates.removeAll { $0.id == template.id } })
        }

        if templates.count < Self.maxTemplates {
          Button(action: addTemplate) {
            Label("Add Template", systemImage: "plus")
              .font(.callout)
          }
          .buttonStyle(.bordered)
          .help("Add a template that formats what you dictate")
          .pointerCursorOnHover()
        }
      }
    }
    .onAppear { templates = DictationTemplateStore.load() }
    .onChange(of: templates) { _, newValue in
      // Only real edits are written: a user who just opens Settings keeps the key absent.
      guard newValue != DictationTemplateStore.load() else { return }
      DictationTemplateStore.save(newValue)
    }
  }

  private func addTemplate() {
    guard templates.count < Self.maxTemplates else { return }
    templates.append(DictationTemplate())
  }
}

// MARK: - One template

private struct TemplateCard: View {
  @Binding var template: DictationTemplate
  let onRemove: () -> Void

  /// Edited as one comma-separated line; stored as a list.
  @State private var keywordsText = ""
  /// The optional app restriction is shown only while on; turning it off clears it.
  @State private var restrictsApps = false

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

      Toggle(isOn: $restrictsApps) {
        Text("Only in certain apps")
          .font(.callout)
      }
      .toggleStyle(.checkbox)
      .help("Off: the template applies in every app")
      .onChange(of: restrictsApps) { _, isOn in
        guard !isOn else { return }
        template.appBundleIDs = []
        template.windowTitleKeywords = []
        keywordsText = ""
      }

      if restrictsApps {
        VStack(alignment: .leading, spacing: 10) {
          appsRow
          VStack(alignment: .leading, spacing: 4) {
            TextField("Only when the window title contains … (optional)", text: $keywordsText)
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel(String(localized: "Window title contains"))
              .onChange(of: keywordsText) { _, newValue in
                template.windowTitleKeywords = newValue
                  .split(separator: ",")
                  .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                  .filter { !$0.isEmpty }
              }
            Text("For a desktop app. Software in a browser shares the browser with webmail; a word from the page title can tell them apart, separate several with commas.")
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.leading, 20)
      }

      if let problem = usabilityProblem {
        Label(problem, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundColor(.orange)
      }
    }
    .padding(SettingsConstants.rowPadding)
    .cardChrome()
    .onAppear {
      keywordsText = template.windowTitleKeywords.joined(separator: ", ")
      restrictsApps = !template.appBundleIDs.isEmpty
    }
  }

  private var usabilityProblem: String? {
    if template.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return String(localized: "Not used yet: add the instructions.")
    }
    if restrictsApps, template.appBundleIDs.isEmpty {
      return String(localized: "No app chosen yet, so it applies in every app.")
    }
    return nil
  }

  // MARK: Instructions

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

  // MARK: Apps

  private var appsRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Applies in")
        .font(.callout)
        .foregroundColor(.secondary)
      FlowingChips(spacing: 6) {
        ForEach(template.appBundleIDs, id: \.self) { bundleID in
          AppChip(bundleID: bundleID) {
            template.appBundleIDs.removeAll { $0 == bundleID }
          }
        }
        addAppMenu
      }
    }
  }

  private var addAppMenu: some View {
    Menu {
      let running = Self.runningApps(excluding: template.appBundleIDs)
      if !running.isEmpty {
        Section("Open apps") {
          ForEach(running, id: \.bundleID) { app in
            Button(app.name) { addApp(app.bundleID) }
          }
        }
      }
      Button("Choose App…", action: chooseApp)
    } label: {
      Label("Add App", systemImage: "plus")
        .font(.callout)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Choose the app you dictate notes into")
    .pointerCursorOnHover()
  }

  private func addApp(_ bundleID: String) {
    guard !template.appBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
    else { return }
    template.appBundleIDs.append(bundleID)
  }

  private func chooseApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Add")
    guard panel.runModal() == .OK, let url = panel.url,
      let bundleID = Bundle(url: url)?.bundleIdentifier
    else { return }
    addApp(bundleID)
  }

  /// Regular (Dock) apps that are running now, by name; WhisperShortcut itself is left out.
  private static func runningApps(excluding taken: [String]) -> [(bundleID: String, name: String)] {
    let own = Bundle.main.bundleIdentifier
    let takenLowercased = Set(taken.map { $0.lowercased() })
    var seen = Set<String>()
    return NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap { app -> (bundleID: String, name: String)? in
        guard let id = app.bundleIdentifier, id != own,
          !takenLowercased.contains(id.lowercased()), seen.insert(id).inserted
        else { return nil }
        return (id, app.localizedName ?? id)
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

// MARK: - Chips

/// An app the template applies in: icon, name, and ✕. Falls back to the bundle ID for an app that
/// is no longer installed, so a stale binding stays visible and removable.
private struct AppChip: View {
  let bundleID: String
  let onRemove: () -> Void

  var body: some View {
    let info = Self.info(for: bundleID)
    HStack(spacing: 5) {
      if let icon = info.icon {
        Image(nsImage: icon)
          .resizable()
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
      }
      Text(info.name)
        .font(.callout)
        .lineLimit(1)
      Button(action: onRemove) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Remove this app")
      .accessibilityLabel(String(localized: "Remove \(info.name)"))
      .pointerCursorOnHover()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
    .help(bundleID)
  }

  private static func info(for bundleID: String) -> (name: String, icon: NSImage?) {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return (bundleID, nil)
    }
    let name = FileManager.default.displayName(atPath: url.path)
      .replacingOccurrences(of: ".app", with: "")
    return (name, NSWorkspace.shared.icon(forFile: url.path))
  }
}

/// Lays chips out left to right and wraps to the next line when the row is full.
private struct FlowingChips: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(
          at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = [Row()]
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let extra = rows[rows.count - 1].indices.isEmpty ? size.width : spacing + size.width
      if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
        rows.append(Row())
      }
      var row = rows[rows.count - 1]
      row.width += row.indices.isEmpty ? size.width : spacing + size.width
      row.height = max(row.height, size.height)
      row.indices.append(index)
      rows[rows.count - 1] = row
    }
    return rows
  }
}
