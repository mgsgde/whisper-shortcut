//
//  MeetingTitleService.swift
//  WhisperShortcut
//
//  App-level meeting-title generation, independent of any chat window.
//
//  The title used to be generated only inside `ChatViewModel`: a live `.chatMeetingSummaryReady`
//  sink (needs an open chat window) plus a backfill that fires when the user opens the meeting
//  tab in Chat. The chat window auto-closes on focus loss (`chatCloseOnFocusLoss`), so at
//  summary-ready time the sink was usually gone and the meeting stayed untitled until the user
//  happened to open that meeting tab — measured on this Mac: every meeting whose summary was
//  written while Chat was closed (e.g. Meeting-2026-11-13-140644) has no title in the store.
//
//  `MenuBarController` observes the same notification and calls this service, so the title
//  lands in the session store no matter which windows are open. `ChatViewModel` keeps calling
//  it too (it needs the applied title for the live UI sync); both paths early-return once a
//  real title exists, so at most one Gemini call runs and a manual rename is never overwritten.
//

import Foundation

@MainActor
enum MeetingTitleService {

  /// Sessions whose title call is currently in flight. The live ChatView sink and the
  /// menu-bar observer can both receive `.chatMeetingSummaryReady`; without this set both
  /// would pass the title-empty pre-check and fire two Gemini calls for one meeting.
  private static var inFlight: Set<UUID> = []

  /// Generates a short title for the meeting chat session `sessionId` from its finished summary
  /// and persists it in the store. Returns the applied title, or nil when nothing was written
  /// (already titled, no summary text, Offline Mode, no Gemini credential, or the call failed —
  /// each logged, never surfaced as a popup: a missing title is cosmetic).
  static func generateAndPersistTitle(sessionId: UUID, summary: String) async -> String? {
    guard let target = ChatSessionStore.shared.session(by: sessionId),
      ChatViewModel.meetingTitleNeedsGeneration(target)
    else { return nil }
    guard !inFlight.contains(sessionId) else { return nil }
    inFlight.insert(sessionId)
    defer { inFlight.remove(sessionId) }
    let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !summaryText.isEmpty else { return nil }

    // The title model is a Gemini call, which Offline Mode blocks; failing it only adds retries.
    if OfflineMode.isEnabled {
      DebugLogger.log("TITLE-MEETING: Skipping title generation (Offline Mode)")
      return nil
    }
    guard let credential = await GeminiCredentialProvider.shared.getCredential() else {
      DebugLogger.log("TITLE-MEETING: Skipping title generation (no Gemini credential)")
      return nil
    }

    let prompt = """
      \(ChatDateContext.stableLine())

      Give this meeting a short title (2–4 words) that captures its main topic. \
      Begin with a single emoji that fits the topic, then one space, then the words. \
      Reply with only the title on a single line — no quotes, no trailing punctuation, no explanation. \
      Example: 🤝 Vendor Negotiation

      Meeting summary:
      \(String(summaryText.prefix(1200)))
      """
    do {
      // Structured output: the model must return {"title": "..."} — no free-text parsing.
      let titleSchema: [String: Any] = [
        "type": "object",
        "properties": [
          "title": [
            "type": "string",
            "description": "A short title capturing the core topic: a single leading emoji, then one space, then 2–4 words. No quotes, no trailing punctuation, no explanation. Example: 📊 Quarterly Revenue",
          ] as [String: Any],
        ] as [String: Any],
        "required": ["title"],
      ]
      let obj = try await MeetingListService.withRetry(label: "TITLE-MEETING") {
        try await GeminiAPIClient().generateStructured(
          model: TranscriptionModel.gemini31FlashLite.rawValue,
          contents: [["role": "user", "parts": [["text": prompt]]]],
          systemInstruction: nil,
          schema: titleSchema,
          credential: credential)
      }
      let title = ChatViewModel.cleanTitleResponse((obj["title"] as? String) ?? "")
      guard !title.isEmpty else { return nil }
      // Re-read and re-check post-network: the user may have renamed the meeting (or a racing
      // path may have titled it) while the call was in flight. A manual rename never equals
      // the fallback, so `meetingTitleNeedsGeneration` preserves it.
      guard var updated = ChatSessionStore.shared.session(by: sessionId),
        ChatViewModel.meetingTitleNeedsGeneration(updated)
      else { return nil }
      updated.title = String(title.prefix(ChatViewModel.maxSessionTitleLength))
      ChatSessionStore.shared.save(updated)
      DebugLogger.log("TITLE-MEETING: title generated for \(sessionId): \(title)")
      return updated.title
    } catch {
      DebugLogger.logError("TITLE-MEETING: title generation failed: \(error.logDescription)")
      return nil
    }
  }
}
