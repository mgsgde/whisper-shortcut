import Foundation

/// Per-session id of the message pinned to the top of the chat scroll view.
///
/// Survives window hide/show, tab switches, and relaunch. Keyed by session UUID; pruned to
/// live sessions on load. Owned by `ChatViewModel`, which keeps thin forwarders so the views
/// do not change.
@MainActor
final class ChatScrollAnchors {
  private var anchors: [UUID: UUID] = [:]

  func load(liveSessionIds: Set<UUID>) {
    let raw = UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.chatScrollAnchors) as? [String: String] ?? [:]
    anchors = raw.reduce(into: [:]) { acc, pair in
      guard let sessionId = UUID(uuidString: pair.key),
            let messageId = UUID(uuidString: pair.value),
            liveSessionIds.contains(sessionId) else { return }
      acc[sessionId] = messageId
    }
  }

  /// The saved top message for `sessionId`, if any.
  func anchor(for sessionId: UUID) -> UUID? { anchors[sessionId] }

  /// Stores (or clears, when `messageId` is nil) the top message for `sessionId`.
  func set(_ messageId: UUID?, for sessionId: UUID) {
    guard anchors[sessionId] != messageId else { return }
    anchors[sessionId] = messageId
    let raw = Dictionary(uniqueKeysWithValues: anchors.map { ($0.key.uuidString, $0.value.uuidString) })
    UserDefaults.standard.set(raw, forKey: UserDefaultsKeys.chatScrollAnchors)
  }
}
