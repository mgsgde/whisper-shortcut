import Foundation

/// The Chat's `app_settings` tool: the settings half of `/improve`. `review` lists what is worth
/// changing (`SettingsAdvisor`), `set` changes settings (always behind the approval card, see
/// `ChatToolRegistry.requiresUserApproval`) and `dismiss` remembers that the user does not want a
/// suggestion. Writes go through `MCPConfigApplier.applySettingsBatch`, the path MCP uses, so each
/// change is logged in `MCPChangeLog` and can be undone from Settings.
enum AppSettingsChatTool {
  static let name = "app_settings"
  static let maxChanges = 5
  static let rationale = "Changed from the in-app Chat (Improve)"

  static let description =
    "Reviews WhisperShortcut's settings and changes them with the user's approval. Call action='review' first when the user asks to improve or check their setup."

  static let parameters: [String: Any] = [
    "type": "object",
    "properties": [
      "action": [
        "type": "string",
        "enum": ["review", "set", "dismiss"],
        "description":
          "'review' returns the findings worth raising. 'set' changes settings (the user approves on a card). 'dismiss' records that the user does not want a finding raised again.",
      ],
      "category": [
        "type": "string",
        "description": "For 'review' only: also return the raw settings of this category (e.g. models, dictation, clipboard, dictate_prompt).",
      ],
      "changes": [
        "type": "array",
        "description": "For 'set': at most \(maxChanges) changes.",
        "items": [
          "type": "object",
          "properties": [
            "id": ["type": "string", "description": "Setting id, as in a finding's fix."],
            "value": ["description": "The new value: true/false for a switch, the option value for a model."],
          ] as [String: Any],
          "required": ["id", "value"],
        ] as [String: Any],
      ] as [String: Any],
      "ids": [
        "type": "array",
        "description": "For 'dismiss': the finding ids to stop raising.",
        "items": ["type": "string"] as [String: Any],
      ] as [String: Any],
    ] as [String: Any],
    "required": ["action"],
  ]

  static let declaration: [String: Any] = [
    "name": name, "description": description, "parameters": parameters,
  ]

  /// Built once: the catalog's closures read the live defaults on every call.
  nonisolated(unsafe) static let liveCatalog = MCPSettingsCatalog.build(.live)

  // MARK: - Arguments

  static func parsedChanges(_ args: [String: Any]) -> [(id: String, value: Any)] {
    guard let raw = args["changes"] as? [[String: Any]] else { return [] }
    return raw.compactMap { entry in
      guard let id = entry["id"] as? String, let value = entry["value"] else { return nil }
      return (id, value)
    }
  }

  // MARK: - Approval card

  /// "Change settings:" and one "<title>: <from> → <to>" line per change.
  static func approvalSummary(args: [String: Any], catalog: [MCPSetting] = liveCatalog) -> String {
    var lines = [String(localized: "Change settings:")]
    for change in parsedChanges(args) {
      guard let setting = catalog.first(where: { $0.id == change.id }) else {
        lines.append("\(change.id): → \(change.value)")
        continue
      }
      let from = MCPSettingsCatalog.reviewLabel(MCPSettingsCatalog.label(for: setting.read(), kind: setting.kind))
      let to = MCPSettingsCatalog.reviewLabel(
        MCPSettingsCatalog.label(for: setting.normalizeForLabel(change.value), kind: setting.kind))
      lines.append("\(MCPSettingsCatalog.reviewTitle(setting.title)): \(from) → \(to)")
    }
    return lines.joined(separator: "\n")
  }

  /// The user said no to a `set` card: do not raise those findings again until the value moves.
  static func suppressDeclined(
    args: [String: Any], catalog: [MCPSetting] = liveCatalog,
    suppressions: ImproveSuppressions = ImproveSuppressions()
  ) {
    guard (args["action"] as? String) == "set" else { return }
    for change in parsedChanges(args) {
      if let current = SettingsAdvisor.currentLabel(forFindingID: change.id, catalog: catalog) {
        suppressions.suppress(id: change.id, currentValue: current)
      }
    }
  }

  // MARK: - Execution

  static func execute(
    args: [String: Any], catalog: [MCPSetting] = liveCatalog,
    deps: MCPSettingsCatalog.Dependencies = .live,
    suppressions: ImproveSuppressions = ImproveSuppressions(),
    applier: MCPConfigApplier = MCPConfigApplier(targets: .live, changeLog: .shared)
  ) -> [String: Any] {
    switch args["action"] as? String {
    case "review":
      return review(args: args, catalog: catalog, deps: deps, suppressions: suppressions)
    case "set":
      return set(args: args, catalog: catalog, applier: applier)
    case "dismiss":
      return dismiss(args: args, catalog: catalog, suppressions: suppressions)
    default:
      return ["error": "action must be review, set or dismiss."]
    }
  }

  private static func review(
    args: [String: Any], catalog: [MCPSetting], deps: MCPSettingsCatalog.Dependencies,
    suppressions: ImproveSuppressions
  ) -> [String: Any] {
    let result = SettingsAdvisor.review(catalog: catalog, deps: deps, suppressions: suppressions)
    let usage: String
    if deps.defaults.bool(forKey: UserDefaultsKeys.offlineModeEnabled) {
      usage = "offline"
    } else {
      usage = deps.defaults.bool(forKey: UserDefaultsKeys.contextLoggingEnabled) ? "on" : "off"
    }
    let language = catalog.first { $0.id == "dictation.language" }.map { $0.read() } ?? ""
    var out: [String: Any] = [
      "usage_data": usage,
      "language": language,
      "findings": result.findings.map(SettingsAdvisor.json),
      "suppressed_count": result.suppressedCount,
    ]
    if let category = (args["category"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
      out["settings"] = catalog
        .filter { !$0.chatOnly && $0.unavailableReason() == nil && $0.category == category }
        .map(MCPConfigTools.settingJSON)
    }
    return out
  }

  private static func set(
    args: [String: Any], catalog: [MCPSetting], applier: MCPConfigApplier
  ) -> [String: Any] {
    let changes = parsedChanges(args)
    guard !changes.isEmpty else { return ["error": "changes must list at least one {id, value}."] }
    guard changes.count <= maxChanges else { return ["error": "Send at most \(maxChanges) changes per call."] }
    let batch = Dictionary(changes.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })
    var items: [MCPSettingsChangeItem] = []
    for change in changes {
      guard let setting = catalog.first(where: { $0.id == change.id }) else {
        return ["error": "Unknown setting id: \(change.id)."]
      }
      if let reason = setting.unavailableReason() { return ["error": "\(setting.title): \(reason)"] }
      if let problem = setting.validateWithBatch(change.value, batch: batch) {
        return ["error": "\(setting.title): \(problem)"]
      }
      let from = setting.read()
      if MCPSettingsCatalog.sameValue(from, setting.normalizeForLabel(change.value)) { continue }
      items.append(MCPSettingsChangeItem(
        id: setting.id, title: setting.title,
        fromLabel: MCPSettingsCatalog.label(for: from, kind: setting.kind),
        toLabel: MCPSettingsCatalog.label(for: setting.normalizeForLabel(change.value), kind: setting.kind),
        fromJSON: MCPSettingsCatalog.encodeValue(from), toJSON: MCPSettingsCatalog.encodeValue(change.value)))
    }
    guard !items.isEmpty else { return ["status": "no_change", "changed": [] as [Any]] }
    switch applier.applySettingsBatch(
      catalog: catalog, items: items, rationale: rationale, viaProposal: false)
    {
    case .success:
      return [
        "status": "applied",
        "changed": items.map { ["id": $0.id, "from": $0.fromLabel, "to": $0.toLabel] },
      ]
    case .failure(let error):
      return ["error": error.localizedDescription]
    }
  }

  private static func dismiss(
    args: [String: Any], catalog: [MCPSetting], suppressions: ImproveSuppressions
  ) -> [String: Any] {
    let ids = (args["ids"] as? [Any])?.compactMap { $0 as? String } ?? []
    guard !ids.isEmpty else { return ["error": "ids must list at least one finding id."] }
    var dismissed: [String] = []
    for id in ids {
      guard let current = SettingsAdvisor.currentLabel(forFindingID: id, catalog: catalog) else { continue }
      suppressions.suppress(id: id, currentValue: current)
      dismissed.append(id)
    }
    return ["status": "dismissed", "ids": dismissed]
  }
}
