import Foundation

/// `get_settings` / `update_settings` handlers, wired from `MCPConfigTools.call`. Kept in their own
/// file since the catalog this dispatches into (`MCPSettingsCatalog`) is itself a separate file;
/// `MCPConfigTools` stays the one dispatcher every tool is registered in.
extension MCPConfigTools {
  static let maxSettingsChangesPerCall = 20

  /// A catalog entry visible right now (its `unavailableReason` is nil).
  private func availableSettings(category: String?) -> [MCPSetting] {
    env.settingsCatalog.filter { setting in
      setting.unavailableReason() == nil && (category == nil || setting.category == category)
    }
  }

  // MARK: - get_settings

  private func settingJSON(_ setting: MCPSetting) -> [String: Any] {
    var out: [String: Any] = [
      "id": setting.id, "title": setting.title, "category": setting.category,
      "value": setting.read(), "requires_approval": setting.proposalOnly,
    ]
    switch setting.kind {
    case .bool: out["type"] = "bool"
    case .string(let maxLength):
      out["type"] = "string"
      out["max_length"] = maxLength
    case .enumeration(let options):
      out["type"] = "enum"
      out["options"] = options().map { opt in
        var o: [String: Any] = ["value": opt.value, "label": opt.label, "available": opt.available]
        if let reason = opt.reason { o["reason"] = reason }
        return o
      }
    case .shortcut:
      out["type"] = "shortcut"
      out["format"] = MCPSettingsCatalog.shortcutFormatHint
    }
    return out
  }

  func getSettings(_ args: [String: Any]) -> MCPToolResult {
    let category = (args["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let settings = availableSettings(category: category).map(settingJSON)
    log("get_settings", "applied", "read", len: settings.count)
    return (json(["settings": settings]), false)
  }

  // MARK: - update_settings

  /// One already-validated change, ready to apply or to become a proposal item.
  private struct ValidatedChange {
    let setting: MCPSetting
    let from: Any
    let to: Any
  }

  func updateSettings(_ args: [String: Any]) -> MCPToolResult {
    let tool = "update_settings"
    let r = rationale(args, tool: tool)
    if let e = r.error { return e }
    guard let changes = args["changes"] as? [String: Any], !changes.isEmpty else {
      return reject(tool, "no changes", "changes must be a non-empty object of setting id → new value.")
    }
    guard changes.count <= Self.maxSettingsChangesPerCall else {
      return reject(tool, "too many changes", "Send at most \(Self.maxSettingsChangesPerCall) changes per call.")
    }

    var validated: [ValidatedChange] = []
    for (id, to) in changes {
      guard let setting = env.settingsCatalog.first(where: { $0.id == id }) else {
        return reject(tool, "unknown setting", "Unknown setting id: \(id). Call get_settings first.")
      }
      if let unavailable = setting.unavailableReason() {
        return reject(tool, "unavailable", "\(setting.title): \(unavailable)")
      }
      if let problem = setting.validate(to) {
        return reject(tool, "invalid value", "\(setting.title): \(problem)")
      }
      validated.append(ValidatedChange(setting: setting, from: setting.read(), to: to))
    }

    let real = validated.filter { !MCPSettingsCatalog.sameValue($0.from, $0.to) }
    if real.isEmpty {
      log(tool, "applied", "no-op", len: 0)
      return (json(["status": "no_change", "changed": []]), false)
    }

    // Re-check the WHOLE batch together, not just each item against today's on-disk state — e.g.
    // two shortcut items in this call both claiming the same still-unused combo each pass the
    // per-item `validate` above (today's config has neither), but not together. Catching that
    // here means the AI app gets the error before any proposal is even created.
    if let problem = MCPSettingsCatalog.validateBatch(
      catalog: env.settingsCatalog, items: real.map { ($0.setting.id, $0.to) })
    {
      return reject(tool, "invalid value", problem)
    }

    let items = real.map { c in
      MCPSettingsChangeItem(
        id: c.setting.id, title: c.setting.title,
        fromLabel: MCPSettingsCatalog.label(for: c.from, kind: c.setting.kind),
        toLabel: MCPSettingsCatalog.label(for: c.setting.normalizeForLabel(c.to), kind: c.setting.kind),
        fromJSON: MCPSettingsCatalog.encodeValue(c.from), toJSON: MCPSettingsCatalog.encodeValue(c.to))
    }
    let changedSummary: [[String: Any]] = items.map {
      ["id": $0.id, "from": $0.fromLabel, "to": $0.toLabel]
    }

    let anyProposalOnly = real.contains { $0.setting.proposalOnly }
    let proposeThisCall = anyProposalOnly || env.accessLevel() == .propose
    return MCPMain.run {
      if proposeThisCall {
        do {
          let p = try env.proposals.create(
            kind: .settings, title: "\(items.count) setting\(items.count == 1 ? "" : "s")",
            rationale: r.value!, settingsChanges: items)
          log(tool, "proposed", len: items.count)
          return pendingResult(p.id)
        } catch {
          return reject(tool, "too many pending", error.localizedDescription)
        }
      }
      switch env.applier.applySettingsBatch(
        catalog: env.settingsCatalog, items: items, rationale: r.value!, viaProposal: false)
      {
      case .success(let changeID):
        log(tool, "applied", len: items.count)
        return (json(["status": "applied", "change_id": changeID, "changed": changedSummary]), false)
      case .failure(let error):
        return reject(tool, "write failed", error.localizedDescription)
      }
    }
  }
}

extension MCPSettingsCatalog {
  /// Loose equality for the heterogeneous `Any` values a setting reads/accepts (Bool, String,
  /// NSNull, or a shortcut's `[String: Any]`), used only to detect a no-op `update_settings` call.
  static func sameValue(_ a: Any, _ b: Any) -> Bool {
    if let a = a as? Bool, let b = b as? Bool { return a == b }
    if let a = a as? String, let b = b as? String { return a == b }
    if a is NSNull, b is NSNull { return true }
    if let a = a as? [String: Any], let b = b as? [String: Any] {
      return NSDictionary(dictionary: a).isEqual(to: b)
    }
    return false
  }
}
