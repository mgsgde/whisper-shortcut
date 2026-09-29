import Foundation

/// One agent turn — model rounds, tool calls, loop guards — with no UI attached.
///
/// Lifted out of `ChatViewModel.performSend` (plans/active/voice-agent-core.md, slice 1) so the
/// same loop can run outside the chat window. Everything that is about *how an agent turn works*
/// lives here: the round cap and the final tool-less round, text accumulation with the leaked
/// thought-token strip and the repeating-status guard, per-round grounding sources, generated-image
/// markers, tool execution with approval, the per-turn memo, and the tool records kept for history.
/// Everything that is about *where the turn is shown* — the streaming bubble, the approval card,
/// persistence, titles — stays with the caller and is reached through the closures below.
///
/// One instance per turn. After `run` throws (Stop, provider error), `partialText` and `records`
/// still hold what the turn produced, so the caller can keep it.
@MainActor
final class ChatAgentRunner {

  struct Result {
    /// Model text with image markers, thought tokens stripped, trailing whitespace trimmed.
    /// Empty when the model wrote nothing — the caller picks the fallback copy.
    let text: String
    /// Only the text of the round that ended the turn — no lead-in narration from rounds that
    /// called tools ("Let me check your calendar."). What a paste wants; the chat shows `text`.
    let finalRoundText: String
    let sources: [GroundingSource]
    let supports: [GroundingSupport]
    let records: [ChatToolCallRecord]
    let executedToolCalls: Int
    /// The model was still calling tools when the round cap's tool-less final round ran.
    let toolLoopExhausted: Bool
    /// The provider cut the reply short (max tokens).
    let truncated: Bool
  }

  private let provider: LLMChatProvider
  private let model: String
  private let tools: [LLMToolDeclaration]
  private let maxToolRounds: Int
  private let steps: ToolStepsBuffer
  /// Rebuilt every round, as before the extraction: memory or meeting context can change mid-turn.
  private let systemInstruction: () -> [String: Any]
  /// Request options for a round; `isFinalRound` must disable built-in tools.
  private let options: (_ isFinalRound: Bool) -> ChatRequestOptions
  private let toolContext: () -> ChatToolContext
  /// Asks the user about a side-effectful call; `stepId` identifies the step awaiting approval.
  private let approve: (_ name: String, _ summary: String, _ stepId: UUID) async -> Bool
  /// The reply so far. `immediate` marks one-shot swaps (image fold, loop-guard notice) that must
  /// not wait for the caller's throttle.
  private let onDisplayText: (_ text: String, _ immediate: Bool) -> Void

  /// Finalized content, including ⟦GEMINI_IMG:…⟧ markers (multi-MB base64). Split from `streamed`
  /// so per-token work never re-scans marker bytes; the reply is always `markerPrefix + streamed`.
  private var markerPrefix = ""
  private var streamed = ""
  private(set) var records: [ChatToolCallRecord] = []

  /// What the turn has shown so far, for a caller that keeps the partial after a throw.
  var partialText: String { ChatViewModel.stripLeakedThoughtTokens(markerPrefix + streamed) }

  init(
    provider: LLMChatProvider,
    model: String,
    tools: [LLMToolDeclaration],
    maxToolRounds: Int,
    steps: ToolStepsBuffer,
    systemInstruction: @escaping () -> [String: Any],
    options: @escaping (_ isFinalRound: Bool) -> ChatRequestOptions,
    toolContext: @escaping () -> ChatToolContext,
    approve: @escaping (_ name: String, _ summary: String, _ stepId: UUID) async -> Bool,
    onDisplayText: @escaping (_ text: String, _ immediate: Bool) -> Void
  ) {
    self.provider = provider
    self.model = model
    self.tools = tools
    self.maxToolRounds = maxToolRounds
    self.steps = steps
    self.systemInstruction = systemInstruction
    self.options = options
    self.toolContext = toolContext
    self.approve = approve
    self.onDisplayText = onDisplayText
  }

  func run(contents initialContents: [[String: Any]]) async throws -> Result {
    var currentContents = initialContents
    // Gemini 3.x can leak `start_thought`/`end_thought` into the visible answer, but only ever
    // in its opening region (see `stripLeakedThoughtTokens`). Once the reply has grown past that
    // zone we stop re-scanning the whole accumulated string on every token — that scan was O(N)
    // per token (O(N²) over the reply) on the MainActor. Reset when `streamed` restarts after an
    // image-marker fold, since fresh narration begins there.
    var thoughtStripSettled = false
    // Consecutive in-place-status ignores (same trailing sentence, not appended).
    // Three of these must stop the stream even though `streamed` stayed at one copy.
    var duplicateStatusStreak = 0
    var loopDeltaIndex = 0
    var finalSources: [GroundingSource] = []
    var finalSupports: [GroundingSupport] = []
    var truncatedFinish = false
    var toolLoopExhausted = false
    // Counts the tool calls executed this turn. Lets the caller tell an empty final turn that
    // *followed* tool work apart from a model that just said nothing, and lets the exhaustion
    // copy say how much work actually ran.
    var executedToolCalls = 0
    // Remembers the read-only calls this turn already made, so a model that keeps re-issuing
    // the same fruitless lookup is answered from the cache and told it is repeating itself,
    // instead of burning another provider round trip per repeat (see ChatToolTurnMemo).
    let toolMemo = ChatToolTurnMemo()
    var lastRoundText = ""

    toolLoop: for round in 0..<(maxToolRounds + 1) {
      // Final round: strip every tool so the model is forced to synthesize an answer from
      // what it already gathered, instead of firing yet another tool call we'd discard. Without
      // this, a model that keeps searching (e.g. re-querying Gmail with reworded terms) ends the
      // loop on an unanswered batch of function calls and the user is shown nothing.
      let isFinalRound = (round == maxToolRounds)
      var pendingCalls: [(name: String, args: [String: Any], thoughtSignature: String?)] = []
      // Narration the model emits in THIS round; echoed back in the model turn that carries
      // the round's function calls so the re-sent history is faithful (see executeToolCalls).
      var roundText = ""
      // Grounding supports index this round's own stream; earlier rounds' text (and any image
      // markers) already sit in front of it in the final reply.
      let roundOffset = (markerPrefix + streamed).count
      let stream = provider.sendChatStream(
        model: model,
        contents: currentContents,
        systemInstruction: systemInstruction(),
        tools: isFinalRound ? [] : tools,
        options: options(isFinalRound))
      for try await event in stream {
        try Task.checkCancellation()
        switch event {
        case .activity(let activity):
          switch activity {
          case .searchingWeb:
            if steps.activeStep?.name != ChatToolRegistry.webSearchStepName {
              DebugLogger.log("CHAT-SEND: activity=\(activity)")
              steps.begin(name: ChatToolRegistry.webSearchStepName, args: [:])
            }
          }
        case .textDelta(let delta):
          if steps.activeStep?.name == ChatToolRegistry.webSearchStepName {
            steps.finishActive(named: ChatToolRegistry.webSearchStepName)
          }
          roundText = ChatStreamLoopGuard.mergeDelta(streamed: roundText, delta: delta)
          let merge = ChatStreamLoopGuard.merge(streamed: streamed, delta: delta)
          streamed = merge.text
          let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
          if merge.kind == .ignored, !trimmedDelta.isEmpty {
            duplicateStatusStreak += 1
          } else if merge.kind != .ignored {
            duplicateStatusStreak = 0
          }
          // Only strip while still in the marker zone. Once stripped, `streamed` never
          // re-acquires a start-anchored marker (deltas append at the end), so re-scanning
          // the whole string every subsequent token is pure waste.
          if !thoughtStripSettled {
            streamed = ChatViewModel.stripLeakedThoughtTokens(streamed)
            if streamed.utf8.count > 512 { thoughtStripSettled = true }
          }
          onDisplayText(markerPrefix + streamed, false)
          loopDeltaIndex += 1
          // Gemini can repeat the same status sentence for minutes. Stop only this stream so the
          // good prefix is kept. Breaking `toolLoop` releases the AsyncThrowingStream iterator;
          // Gemini's `onTermination` cancels the URLSession task the same way a consumer stop
          // does, and the turn finalizes the partial normally.
          if ChatStreamLoopGuard.shouldStop(
            streamed: streamed, ignoredStreak: duplicateStatusStreak, deltaIndex: loopDeltaIndex
          ) {
            DebugLogger.logWarning(
              "CHAT: stream loop detected — stopping this reply without dropping the queue (chars=\(streamed.count))")
            streamed = ChatStreamLoopGuard.appendStopNotice(to: streamed)
            onDisplayText(markerPrefix + streamed, true)
            lastRoundText = roundText
            break toolLoop
          }
        case .functionCall(let name, let args, let thoughtSignature):
          steps.finishActive(named: ChatToolRegistry.webSearchStepName)
          pendingCalls.append((name, args, thoughtSignature))
        case .finished(let sources, let supports, let finishReason):
          // Each round cites on its own: a search before a tool call must keep its chips when
          // the next round answers without searching. Append this round's sources (reusing
          // ones already listed) and remap its supports onto the combined list.
          let indexMap = sources.map { source -> Int in
            if let existing = finalSources.firstIndex(where: { $0.uri == source.uri }) {
              return existing
            }
            finalSources.append(source)
            return finalSources.count - 1
          }
          finalSupports += supports.map {
            GroundingSupport(
              startIndex: $0.startIndex + roundOffset, endIndex: $0.endIndex + roundOffset,
              groundingChunkIndices: $0.groundingChunkIndices.compactMap {
                indexMap.indices.contains($0) ? indexMap[$0] : nil
              })
          }
          if ChatViewModel.isTruncatedFinishReason(finishReason) { truncatedFinish = true }
        }
      }
      lastRoundText = roundText
      if pendingCalls.isEmpty { break toolLoop }
      // Tools were already disabled this round, yet the model still emitted only function
      // calls and no usable text — nothing left to try, so surface the exhaustion.
      if isFinalRound {
        DebugLogger.logWarning(
          "CHAT: tool loop exceeded \(maxToolRounds) rounds after \(executedToolCalls) call(s) — stopping (final round wanted \(pendingCalls.map(\.name).joined(separator: ", ")))")
        toolLoopExhausted = true
        break toolLoop
      }
      executedToolCalls += pendingCalls.count
      let (turns, imageMarkers, roundRecords) = try await executeToolCalls(
        pendingCalls, narration: ChatViewModel.stripLeakedThoughtTokens(roundText), memo: toolMemo)
      records.append(contentsOf: roundRecords)
      // Generated images go straight into the reply: the image shows up the moment the tool
      // finishes, and the model's follow-up narration streams below it. The marker becomes part
      // of the persisted message content (rendered inline); buildContents strips it again before
      // re-sending history.
      if !imageMarkers.isEmpty {
        let joined = imageMarkers.joined(separator: "\n\n")
        // Trailing break: the model's follow-up narration streams directly after the
        // marker block, and a glued `…⟧Text` paragraph wouldn't render as an image.
        let current = markerPrefix + streamed
        markerPrefix = (current.isEmpty ? joined : current + "\n\n" + joined) + "\n\n"
        streamed = ""
        thoughtStripSettled = false
        duplicateStatusStreak = 0
        loopDeltaIndex = 0
        onDisplayText(markerPrefix, true)
      } else if let last = streamed.last, !last.isNewline {
        // The next round's narration streams into the same reply. Without a paragraph
        // break it glues onto this round's last sentence ("…zu Grok 4.7.Noch kurz…").
        streamed += "\n\n"
      }
      currentContents.append(contentsOf: turns)
    }

    // A cancelled turn must never reach the caller's fallback copy: cancelling the task makes
    // the provider's `AsyncThrowingStream` *finish* rather than throw, so the loop above exits
    // normally with an empty reply. This check turns that into a `CancellationError`.
    try Task.checkCancellation()

    // Final belt-and-suspenders strip: streaming stops re-scanning past the marker zone
    // (see `thoughtStripSettled`), so a marker leaking later would otherwise reach the reply.
    var text = ChatViewModel.stripLeakedThoughtTokens(markerPrefix + streamed)
    // A round-boundary paragraph break (above) dangles when the final round emitted only
    // function calls; a whitespace-only reply must count as empty.
    while let last = text.last, last.isWhitespace { text.removeLast() }
    var finalRoundText = ChatViewModel.stripLeakedThoughtTokens(lastRoundText)
    while let last = finalRoundText.last, last.isWhitespace { finalRoundText.removeLast() }
    return Result(
      text: text, finalRoundText: finalRoundText,
      sources: finalSources, supports: finalSupports, records: records,
      executedToolCalls: executedToolCalls, toolLoopExhausted: toolLoopExhausted,
      truncated: truncatedFinish)
  }

  private func executeToolCalls(
    _ calls: [(name: String, args: [String: Any], thoughtSignature: String?)],
    narration: String,
    memo: ChatToolTurnMemo
  ) async throws -> (turns: [[String: Any]], imageMarkers: [String], records: [ChatToolCallRecord]) {
    var callParts: [[String: Any]] = calls.map { call in
      var part: [String: Any] = ["functionCall": ["name": call.name, "args": call.args]]
      if let sig = call.thoughtSignature { part["thoughtSignature"] = sig }
      return part
    }
    // Echo the narration the model emitted alongside the calls: the function-calling contract
    // (Gemini docs; the Responses/Chat Completions converters mirror it) expects the model turn
    // re-sent as received. Without it the model can't see what it already told the user
    // mid-loop and may repeat itself across rounds.
    if !narration.isEmpty {
      callParts.insert(["text": narration], at: 0)
    }
    var responseParts: [[String: Any]] = []
    // ⟦GEMINI_IMG:…⟧ markers produced by generate_image. They go straight into the reply,
    // NOT back through the model — the functionResponse only carries a short status, so
    // megabytes of base64 never enter the model's context.
    var imageMarkers: [String] = []
    let context = toolContext()
    // Gemini 3.x sometimes calls tools it was never offered. Only declared tools run: the caller's
    // tool list is the policy (Dictate Prompt offers read-only tools only), and an undeclared call
    // such as `copy_to_clipboard` must not slip past it just because it needs no approval.
    let declaredNames = Set(tools.map(\.name))
    var stepIds: [UUID] = []
    for call in calls {
      try Task.checkCancellation()
      guard declaredNames.contains(call.name) else {
        let stepId = steps.begin(name: call.name, args: call.args)
        stepIds.append(stepId)
        steps.finish(stepId, phase: .failed, summary: "Not available here")
        DebugLogger.logWarning("CHAT-TOOL-UNDECLARED: refused \(call.name)")
        responseParts.append([
          "functionResponse": [
            "name": call.name,
            "response": ["error": "The tool \(call.name) is not available in this conversation."],
          ]
        ])
        continue
      }
      let needsApproval = ChatToolRegistry.requiresUserApproval(call.name, args: call.args)
      let stepId = steps.begin(
        name: call.name, args: call.args, phase: needsApproval ? .awaitingApproval : .running)
      stepIds.append(stepId)
      if needsApproval {
        let summary = ChatToolRegistry.approvalSummary(name: call.name, args: call.args)
        let allowed = await approve(call.name, summary, stepId)
        if allowed { steps.setPhase(stepId, .running) }
        if !allowed {
          steps.finish(stepId, phase: .denied)
          DebugLogger.log("CHAT-TOOL-DENIED: \(call.name)")
          responseParts.append([
            "functionResponse": [
              "name": call.name,
              "response": ["error": "The user denied this \(call.name) call."],
            ]
          ])
          continue
        }
      }
      DebugLogger.log("CHAT-TOOL-CALL: \(call.name) args=\(Self.compactDescription(call.args))")
      let response: [String: Any]
      if let cached = memo.cachedResponse(name: call.name, args: call.args) {
        // Identical read-only call, same turn: the answer cannot have changed, and re-running it
        // would hide from the model that it is going in circles.
        DebugLogger.log("CHAT-TOOL-REPEAT: \(call.name) served from this turn's cache")
        response = cached
      } else {
        let outcome = await ChatToolRegistry.execute(
          name: call.name, args: call.args, context: context)
        imageMarkers.append(contentsOf: outcome.imageMarkers)
        response = memo.record(name: call.name, args: call.args, response: outcome.response)
      }
      if let error = ChatToolRegistry.resultError(response) {
        steps.finish(stepId, phase: .failed, summary: error)
      } else {
        steps.finish(
          stepId, phase: .done, summary: ChatToolRegistry.resultSummary(name: call.name, response: response))
      }
      DebugLogger.log("CHAT-TOOL-RESULT: \(call.name) -> \(Self.compactDescription(response))")
      responseParts.append(["functionResponse": ["name": call.name, "response": response]])
    }
    DebugLogger.log("CHAT: executed \(calls.count) tool call(s), continuing stream")
    let turns: [[String: Any]] = [
      ["role": "model", "parts": callParts],
      ["role": "user", "parts": responseParts],
    ]
    // One response part per call, in call order (denied calls included), so they zip 1:1.
    let roundRecords = ChatToolHistory.records(
      calls: calls.map { ($0.name, $0.args) },
      responses: responseParts.map {
        (($0["functionResponse"] as? [String: Any])?["response"] as? [String: Any]) ?? [:]
      },
      steps: stepIds.map { steps.step($0) })
    return (turns, imageMarkers, roundRecords)
  }

  /// Compact, length-capped JSON string for logging tool-call args/results
  /// without flooding the log. Lets us see exactly what the model passed and
  /// got back (e.g. the precise event_id), which plain name-only logging hid.
  static func compactDescription(_ value: [String: Any], maxLength: Int = 600) -> String {
    let raw: String
    if let data = try? JSONSerialization.data(withJSONObject: value),
       let json = String(data: data, encoding: .utf8) {
      raw = json
    } else {
      raw = String(describing: value)
    }
    return raw.count > maxLength ? String(raw.prefix(maxLength)) + "…(\(raw.count) chars)" : raw
  }
}
