import Foundation

/// Assembles one chat turn's provider payload.
///
/// Lifted out of `ChatViewModel` (R40). `private` is file-scoped, so the session id,
/// on-screen messages, store, and selected model are parameters instead of instance state.
enum ChatRequestBuilder {

  @MainActor
  static func buildContents(
    sessionId: UUID,
    currentSessionId: UUID,
    messages: [ChatMessage],
    store: ChatSessionStore,
    model: PromptModel
  ) -> [[String: Any]] {
    // Queued sends can target a session that is no longer the visible one,
    // so the history must come from the target session — not `messages`.
    let history = sessionId == currentSessionId
      ? messages
      : (store.session(by: sessionId)?.messages ?? [])
    // Send the full conversation history. Gemini 2.x has a 1M–2M token context window,
    // so truncation is only a safeguard against pathological sessions.
    let maxMessages = AppConstants.chatFullHistoryMaxMessages
    let toSend = history.count > maxMessages
      ? Array(history.suffix(maxMessages))
      : history
    logImagePayloadMeasurement(toSend)
    // A YouTube link is only a link to every provider except Gemini, which can watch the video
    // when it arrives as a `file_data` part (its `url_context` tool refuses YouTube). Resolve
    // which messages get a video part before mapping: the budget is per request and counts from
    // the newest message backwards, so a session full of links doesn't send a dozen videos.
    let isGemini = model.provider == .gemini
    let videoLinksByMessage = isGemini ? youTubeLinksToAttach(in: toSend) : [:]
    // Every other provider is blind to the link but perfectly willing to describe the video from
    // search results — the failure this feature exists to fix. Tell the newest linking turn so the
    // model says it cannot watch the video instead of confabulating it.
    let unwatchableLinkMessageID: UUID? = isGemini
      ? nil
      : toSend.last { $0.role == .user && !YouTubeVideoLink.detect(in: $0.content).isEmpty }?.id
    // Re-send each user message's attached images on every turn, not just the
    // final one. Otherwise an image is visible to the model only on the turn it
    // was attached and is stripped to text afterwards — so a follow-up like
    // "look at the screenshot" sees no image at all. All providers (Gemini,
    // OpenAI, Grok) convert inline_data on any message, so this is safe.
    return toSend.map { msg in
      // Assistant turns that generated an image carry a ⟦GEMINI_IMG:…⟧ marker with the full
      // base64 inline. Strip it to a short placeholder before re-sending as history: the blob
      // would otherwise bloat every subsequent request and is useless to the model as text.
      let text = msg.role == .model
        ? GeminiAPIClient.stripImageMarkers(msg.content)
        : msg.content
      let videoLinks = videoLinksByMessage[msg.id] ?? []
      if msg.id == unwatchableLinkMessageID {
        var parts: [[String: Any]] = msg.attachedImageParts.map { part in
          ["inline_data": ["mime_type": part.mimeType ?? "image/png", "data": part.data.base64EncodedString()]]
        }
        if !text.isEmpty { parts.append(["text": text]) }
        parts.append(["text":
          "[System note: the message above contains a YouTube link. You cannot watch YouTube videos — "
          + "in this app only Gemini models can. Do not describe the video's contents as if you had seen "
          + "it. Say plainly that you cannot open the video with this model, offer what you can find about "
          + "it from other sources, and mention that switching to a Gemini model lets it be analysed.]"])
        return ["role": msg.role.rawValue, "parts": parts]
      }
      if msg.role == .user && (!msg.attachedImageParts.isEmpty || !videoLinks.isEmpty) {
        var parts: [[String: Any]] = msg.attachedImageParts.map { part in
          ["inline_data": ["mime_type": part.mimeType ?? "image/png", "data": part.data.base64EncodedString()]]
        }
        // Video part first, its note right after: the note explains the clip window, and a model
        // reads it as a caption for the media directly above it.
        for link in videoLinks {
          parts.append(link.geminiVideoPart)
          parts.append(["text": link.geminiContextNote])
        }
        if !text.isEmpty {
          parts.append(["text": text])
        }
        return ["role": msg.role.rawValue, "parts": parts]
      }
      return ["role": msg.role.rawValue, "parts": [["text": text]]]
    }
  }

  /// Which YouTube links get attached as video parts, keyed by message id.
  ///
  /// Videos are the most expensive thing this app can put in a request (~90 tokens per second of
  /// video, re-sent on every follow-up turn), so the budget is small and spent newest-first: the
  /// video the user is currently asking about always wins over one from ten turns ago.
  @MainActor
  private static func youTubeLinksToAttach(in messages: [ChatMessage]) -> [UUID: [YouTubeVideoLink]] {
    var result: [UUID: [YouTubeVideoLink]] = [:]
    var seenVideoIDs = Set<String>()
    var budget = YouTubeVideoLink.maxVideosPerRequest
    for msg in messages.reversed() where msg.role == .user {
      guard budget > 0 else { break }
      for link in YouTubeVideoLink.detect(in: msg.content) {
        guard budget > 0 else { break }
        // The same video re-posted in a later turn is already attached (with that turn's
        // timestamp) — sending it twice just doubles the token bill.
        guard seenVideoIDs.insert(link.videoID).inserted else { continue }
        result[msg.id, default: []].append(link)
        budget -= 1
      }
    }
    if !result.isEmpty {
      let attached = result.values.flatMap { $0 }
      DebugLogger.log(
        "CHAT-YOUTUBE: attaching \(attached.count) video part(s): "
        + attached.map { link in
          link.shouldClipUpFront
            ? "\(link.videoID)@\(YouTubeVideoLink.formatTimestamp(link.clipRange.start))+\(YouTubeVideoLink.clipWindowSeconds)s"
            : "\(link.videoID)/full"
        }.joined(separator: ", "))
    }
    return result
  }

  /// Measures the image payload re-sent on this turn (images are sent in full on *every*
  /// turn — see `buildContents`). Logs the total plus the portion carried by user turns
  /// older than the last `AppConstants.chatRecentImageTurns` turns: that `savablePerTurn`
  /// figure is what an "images only for the recent N turns" policy would drop from each
  /// request, and is the number to watch before deciding whether the cap is worth it.
  /// Pure measurement — it changes nothing about what gets sent.
  @MainActor
  private static func logImagePayloadMeasurement(_ toSend: [ChatMessage]) {
    let userTurnIdx = toSend.indices.filter { toSend[$0].role == .user }
    guard !userTurnIdx.isEmpty else { return }
    let window = AppConstants.chatRecentImageTurns
    let recentTurns = Set(userTurnIdx.suffix(window))

    var imgTurns = 0, images = 0, bytes = 0
    var staleTurns = 0, staleImages = 0, staleBytes = 0
    for i in userTurnIdx {
      let parts = toSend[i].attachedImageParts
      guard !parts.isEmpty else { continue }
      let turnBytes = parts.reduce(0) { $0 + $1.data.count }
      imgTurns += 1; images += parts.count; bytes += turnBytes
      if !recentTurns.contains(i) {
        staleTurns += 1; staleImages += parts.count; staleBytes += turnBytes
      }
    }
    guard images > 0 else { return }

    // Decoded bytes; the base64 wire payload is ~4/3 of this.
    func mb(_ b: Int) -> String { String(format: "%.1fMB", Double(b) / 1_048_576) }
    DebugLogger.logNetwork(
      "CHAT-IMG-MEASURE: msgsSent=\(toSend.count) imgTurns=\(imgTurns) images=\(images) "
        + "imgBytes=\(mb(bytes)) wire≈\(mb(bytes * 4 / 3)) | window=\(window)turns "
        + "staleTurns=\(staleTurns) staleImages=\(staleImages) savablePerTurn=\(mb(staleBytes))")
  }

}
