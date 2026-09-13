//
//  GeminiTranscriptionCall.swift
//  WhisperShortcut
//
//  One Gemini transcription round-trip, written once. `SpeechService` (single recording) and
//  `ChunkTranscriptionService` (one call per chunk) used to each build the request, decode the
//  response and run the plausibility gates by hand — and drifted: only one copy grew the
//  glossary-echo retry, another hard-coded its own fallback instruction. The recovery ladder
//  stays with the caller; what happens on the wire lives here.
//

import Foundation

struct GeminiTranscriptionResult {
  /// Normalized transcript after both gates — empty when a gate discarded it.
  let text: String
  /// True when the length gate passed and only the glossary-echo gate emptied the text — the
  /// one case where retrying without the glossary can still produce a transcript.
  let discardedAsGlossaryEcho: Bool
}

extension GeminiAPIClient {
  /// Sends `audioURL` inline (AAC when the transcoder can, raw bytes otherwise) with
  /// `instruction` and returns the normalized transcript after both confabulation gates —
  /// possibly empty, which is the caller's signal to retry or fall back.
  ///
  /// - Parameters:
  ///   - audioDurationSeconds: drives the chars-per-second plausibility gate.
  ///   - glossaryTerms: the vocabulary the instruction carried, for the echo gate.
  ///   - mode: log tag (`GEMINI-TRANSCRIPTION`, `CHUNK-3`, …).
  ///   - withRetry: the client's own retry loop. Chunks run their own `ChunkRetryPolicy` and
  ///     pass `false`; a single recording passes `true`.
  ///   - timeoutInterval: per-request override; chunks cap it so one slow response cannot
  ///     stall the whole transcription.
  func transcribe(
    audioURL: URL,
    instruction: String,
    model: TranscriptionModel,
    credential: GeminiCredential,
    audioDurationSeconds: TimeInterval,
    glossaryTerms: [String],
    mode: String,
    withRetry: Bool,
    timeoutInterval: TimeInterval? = nil
  ) async throws -> GeminiTranscriptionResult {
    // Read audio (as compact AAC when possible) and convert to base64
    let encodeStartTime = CFAbsoluteTimeGetCurrent()
    let audioData: Data
    let mimeType: String
    if let aacData = AudioTranscoder.aacData(for: audioURL) {
      audioData = aacData
      mimeType = AudioTranscoder.aacMimeType
    } else {
      audioData = try Data(contentsOf: audioURL)
      mimeType = getMimeType(for: audioURL.pathExtension.lowercased())
    }
    let base64Audio = audioData.base64EncodedString()
    let encodeTime = CFAbsoluteTimeGetCurrent() - encodeStartTime
    DebugLogger.logSpeech("SPEED: [\(mode)] Audio encoding took \(String(format: "%.3f", encodeTime))s (\(String(format: "%.0f", encodeTime * 1000))ms)")

    let endpoint = model.apiEndpoint
    DebugLogger.log("\(mode): Using model: \(model.displayName) (\(model.rawValue)) at \(endpoint)")
    DebugLogger.log("\(mode): Using prompt: \(instruction.prefix(100))...")

    let transcriptionRequest = GeminiTranscriptionRequest(
      contents: [
        GeminiTranscriptionRequest.GeminiTranscriptionContent(
          parts: [
            .text(instruction),
            .inline(mimeType: mimeType, data: base64Audio),
          ]
        )
      ],
      generationConfig: model.geminiTranscriptionGenerationConfig
    )

    var request = try createRequest(endpoint: endpoint, credential: credential)
    if let timeoutInterval { request.timeoutInterval = timeoutInterval }
    request.httpBody = try JSONEncoder().encode(transcriptionRequest)

    let networkStartTime = CFAbsoluteTimeGetCurrent()
    let response = try await performRequest(
      request,
      responseType: GeminiResponse.self,
      mode: mode,
      withRetry: withRetry
    )
    let networkTime = CFAbsoluteTimeGetCurrent() - networkStartTime
    DebugLogger.logSpeech("SPEED: [\(model.displayName)] \(mode) API network request took \(String(format: "%.3f", networkTime))s (\(String(format: "%.0f", networkTime * 1000))ms)")

    // Very short recordings can be imperceptible to Flash-tier models, which then confabulate
    // from the prompt context — gate on chars-per-second plausibility in both directions:
    // impossibly long output (invented paragraphs) and near-empty output that is pure glossary
    // vocabulary (a 6.3 s tail chunk once yielded exactly "sabaki.dance").
    let transcript = extractText(from: response)
    let afterLengthGate = TextProcessingUtility.discardingImplausibleTranscript(
      TextProcessingUtility.normalizeTranscriptionText(transcript),
      audioDurationSeconds: audioDurationSeconds, mode: mode)
    let text = TextProcessingUtility.discardingGlossaryEchoTranscript(
      afterLengthGate,
      audioDurationSeconds: audioDurationSeconds,
      glossaryTerms: glossaryTerms,
      mode: mode)
    return GeminiTranscriptionResult(
      text: text, discardedAsGlossaryEcho: text.isEmpty && !afterLengthGate.isEmpty)
  }
}
