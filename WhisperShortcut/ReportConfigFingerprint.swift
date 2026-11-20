//
//  ReportConfigFingerprint.swift
//  WhisperShortcut
//
//  A short hash of the prompts and templates a dictation ran with, so a problem report can say
//  whether those settings have changed since.
//

import CryptoKit
import Foundation

enum ReportConfigFingerprint {

  /// First 12 hex characters of the SHA-256 of `text`.
  static func shortHash(_ text: String) -> String {
    let hex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(12))
  }

  /// Hash of every configured prompt section and every template, in a stable order.
  /// `templates` defaults to the list the app has stored; tests pass their own.
  static func current(
    store: SystemPromptsStore = .shared,
    templates: [DictationTemplate] = DictationTemplateStore.load()
  ) -> String {
    shortHash(payload(store: store, templates: templates))
  }

  /// Sections in `MCPConfigTools.sections` order, then templates sorted by id.
  /// Each field is length-prefixed, so a separator that happens to occur inside a prompt
  /// cannot make two different configurations hash the same.
  private static func payload(store: SystemPromptsStore, templates: [DictationTemplate]) -> String {
    var parts: [String] = []
    for item in MCPConfigTools.sections {
      let text = store.loadSection(item.section)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      parts.append(item.name)
      parts.append(text)
    }
    let ordered = templates.sorted { $0.id.uuidString < $1.id.uuidString }
    for template in ordered {
      parts.append(template.name)
      parts.append(template.instructions)
    }
    return parts.map { "\($0.utf8.count):\($0)" }.joined()
  }
}
