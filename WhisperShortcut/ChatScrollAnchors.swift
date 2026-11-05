import Foundation

/// Per-session reading position of the chat scroll view: the message pinned to the top, and
/// whether the session was following the newest content.
///
/// Survives window hide/show, tab switches, and relaunch. Keyed by session UUID; pruned to
/// live sessions on load. Owned by `ChatViewModel`, which keeps thin forwarders so the views
/// do not change.
///
/// The follow flag is stored next to the anchor because the anchor alone cannot express it: a
/// session read at the bottom still has a top message, so "an anchor exists" used to mean "the
/// user was reading further up" and every tab switch back to a live conversation stopped the
/// autoscroll. The flag is what the user actually chose.
@MainActor
final class ChatScrollAnchors {
  private var anchors: [UUID: UUID] = [:]
  /// Sessions whose view was at the bottom when it was last left. Absent means "not following".
  private var following: Set<UUID> = []

  func load(liveSessionIds: Set<UUID>) {
    let raw = UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.chatScrollAnchors) as? [String: String] ?? [:]
    anchors = raw.reduce(into: [:]) { acc, pair in
      guard let sessionId = UUID(uuidString: pair.key),
            let messageId = UUID(uuidString: pair.value),
            liveSessionIds.contains(sessionId) else { return }
      acc[sessionId] = messageId
    }
    let rawFollowing = UserDefaults.standard.array(forKey: UserDefaultsKeys.chatScrollFollowing) as? [String] ?? []
    following = Set(rawFollowing.compactMap(UUID.init(uuidString:)).filter(liveSessionIds.contains))
  }

  /// The saved top message for `sessionId`, if any.
  func anchor(for sessionId: UUID) -> UUID? { anchors[sessionId] }

  /// True when `sessionId` was left at the bottom, so new content should keep pulling it down.
  func isFollowing(_ sessionId: UUID) -> Bool { following.contains(sessionId) }

  /// Stores (or clears, when `messageId` is nil) the top message for `sessionId`.
  func set(_ messageId: UUID?, for sessionId: UUID) {
    guard anchors[sessionId] != messageId else { return }
    anchors[sessionId] = messageId
    persistAnchors()
  }

  /// Records whether `sessionId` is following the newest content.
  func setFollowing(_ isFollowing: Bool, for sessionId: UUID) {
    let changed = isFollowing ? following.insert(sessionId).inserted : following.remove(sessionId) != nil
    guard changed else { return }
    UserDefaults.standard.set(following.map(\.uuidString), forKey: UserDefaultsKeys.chatScrollFollowing)
  }

  private func persistAnchors() {
    let raw = Dictionary(uniqueKeysWithValues: anchors.map { ($0.key.uuidString, $0.value.uuidString) })
    UserDefaults.standard.set(raw, forKey: UserDefaultsKeys.chatScrollAnchors)
  }
}
