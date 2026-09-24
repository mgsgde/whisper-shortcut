import Foundation

/// `remember_about_user` and `forget_about_user`.
///
/// Lifted out of `ChatViewModel` (R42). Neither function reads view-model state; both only
/// call `ChatMemoryStore.shared`.
enum ChatMemoryTools {

  /// Backs the `remember_about_user` chat tool. Appends one durable fact to persistent memory
  /// (UserContext/memory.md), deduped. Synchronous — the file is tiny and writes are local.
  static func executeRememberAboutUserTool(args: [String: Any]) -> [String: Any] {
    guard let fact = (args["fact"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !fact.isEmpty else {
      return ["error": "Missing required argument: fact"]
    }
    let added = ChatMemoryStore.shared.addFact(fact)
    if added {
      return ["ok": true, "remembered": fact,
              "detail": "Saved to persistent memory. Briefly confirm in one sentence; do not list the rest of the memory."]
    }
    return ["ok": true, "remembered": fact, "duplicate": true,
            "detail": "This fact was already remembered — nothing changed. Acknowledge briefly."]
  }

  /// Backs the `forget_about_user` chat tool. Removes every stored fact containing the given text.
  static func executeForgetAboutUserTool(args: [String: Any]) -> [String: Any] {
    guard let matching = (args["matching"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !matching.isEmpty else {
      return ["error": "Missing required argument: matching"]
    }
    let removed = ChatMemoryStore.shared.removeFacts(matching: matching)
    guard removed > 0 else {
      return ["ok": true, "removed": 0,
              "detail": "No remembered fact matched \"\(matching)\". Tell the user there was nothing to forget."]
    }
    return ["ok": true, "removed": removed,
            "detail": "Forgot \(removed) fact(s). Confirm briefly."]
  }
}
