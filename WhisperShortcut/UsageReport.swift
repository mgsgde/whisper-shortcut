import Foundation

/// A content-free summary of how the app was used, composed on the user's own Mac.
///
/// The app has never had analytics, and this does not add any: nothing here transmits. `build()`
/// returns a string, the user reads it in full, and it leaves the machine only if they press Send
/// in their own mail or WhatsApp client. That is what keeps `PrivacyCopy.promiseBullets` — "no
/// hidden telemetry and no third-party tracking, we don't run a server" — literally true.
///
/// **Why this can exist at all:** `signals-YYYY-MM-DD.jsonl` was designed content-free (see
/// `SignalLogEntry`), so the verdicts it holds are safe to aggregate. The interaction stream is
/// not — it is full of transcripts — which is why this file decodes it through its own narrow
/// `InteractionMetaEntry` rather than through `InteractionLogEntry`. The privacy property is
/// therefore structural: content fields are never materialised, not merely never printed.
enum UsageReport {

  static let defaultDays = 30

  /// Both `wa.me` and `mailto:` carry their payload inside the URL, and an over-long URL is
  /// silently dropped by some clients rather than erroring — the same hazard `FeedbackLinks`
  /// documents. The report is capped here so it always survives the trip.
  static let maxCharacters = 1200

  private static let reportVersion = 1
  /// How many entries each histogram shows. Also what bounds the report's length.
  private static let topEntries = 3

  /// The only `detail` keys the report may read.
  ///
  /// `SignalLogEntry` forbids user text in `detail`, but that is a comment, not a compiler. An
  /// allow-list means a future signal that breaks the rule still cannot reach this report.
  private static let allowedDetailKeys: Set<String> = [
    "autoPasteAvailable", "targetBundleId", "reason",
  ]

  // MARK: - Environment

  /// Facts about the build, injected rather than read inline so tests can exercise both variants —
  /// the test target compiles with `APP_STORE` defined, which would otherwise pin every test to
  /// the App Store branch.
  struct Environment {
    let appVersion: String
    let osVersion: String
    let isAppStoreBuild: Bool

    static var current: Environment {
      let os = ProcessInfo.processInfo.operatingSystemVersion
      #if APP_STORE
        let appStore = true
      #else
        let appStore = false
      #endif
      return Environment(
        appVersion: AppConstants.appVersion,
        osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        isAppStoreBuild: appStore
      )
    }
  }

  // MARK: - Public API

  /// Builds the report from the last `lastDays` of on-disk logs.
  ///
  /// Does blocking file I/O — call it off the main thread.
  static func build(lastDays: Int = defaultDays) -> String {
    render(
      interactionFiles: ContextLogger.shared.interactionLogFiles(lastDays: lastDays),
      signalFiles: ContextLogger.shared.signalLogFiles(lastDays: lastDays),
      lastDays: lastDays,
      environment: .current
    )
  }

  static func render(
    interactionFiles: [URL],
    signalFiles: [URL],
    lastDays: Int = defaultDays,
    environment: Environment = .current
  ) -> String {
    let interactions = decode(InteractionMetaEntry.self, from: interactionFiles)
    let signals = decode(SignalLogEntry.self, from: signalFiles)

    let buildLabel = environment.isAppStoreBuild ? "App Store build" : "direct build"
    var lines = [
      "WhisperShortcut usage report — last \(lastDays) days",
      "App \(environment.appVersion) (\(buildLabel)) · macOS \(environment.osVersion) · report v\(reportVersion)",
    ]

    guard !interactions.isEmpty || !signals.isEmpty else {
      return (lines + ["", "No usage data recorded."]).joined(separator: "\n")
    }

    lines += dictationSection(interactions: interactions, signals: signals, environment: environment)
    lines += promptSection(interactions: interactions, signals: signals)
    lines += chatSection(interactions: interactions, signals: signals)
    lines += pasteTargetSection(signals: signals)

    let days = Set(interactions.map { day($0.ts) } + signals.map { day($0.ts) })
    lines += ["", "Active on \(days.count) of \(lastDays) days"]

    return capped(lines.joined(separator: "\n"))
  }

  // MARK: - Sections

  /// Empty sections are omitted rather than rendered as `0%`: a zero that means "never happened"
  /// and a zero that means "not measurable in this build" would be indistinguishable.
  private static func dictationSection(
    interactions: [InteractionMetaEntry], signals: [SignalLogEntry], environment: Environment
  ) -> [String] {
    let dictations = interactions.filter { $0.mode == "transcription" }
    guard !dictations.isEmpty else { return [] }
    let total = dictations.count

    var body: [String] = []
    let start = windowStart(signals, mode: "transcription")
    // Restarts are only meaningful where auto-paste exists to prove the opposite case. See the
    // App Store caveat in `ContextLogger.noteDictationStart`.
    let restarts = signals.filter { entry in
      guard entry.kind == "dictationRestart", isInWindow(entry, since: start) else { return false }
      return detail(entry, "autoPasteAvailable") == "true"
    }
    let pasted = signals.filter { entry in
      guard entry.kind == "pasted", entry.mode == "transcription" else { return false }
      return isInWindow(entry, since: start)
    }.count

    let measurable = measurableCount(interactions, since: start, mode: "transcription")

    if pasted > 0 || !restarts.isEmpty, measurable > 0 {
      let rates =
        "\(pct(pasted, of: measurable)) delivered · \(pct(restarts.count, of: measurable)) restarted (\(restarts.count))"
      if measurable == total {
        body.append("  \(total) dictations · \(rates)")
      } else {
        body.append("  \(total) dictations")
        body.append("  of the \(measurable) since outcome tracking began: \(rates)")
      }
      if let median = medianGap(restarts) { body.append("  median restart gap \(median)") }
    } else {
      body.append("  \(total) dictations")
      body.append(
        environment.isAppStoreBuild
          ? "  delivery/restart metrics unavailable in App Store builds (no auto-paste)"
          : "  delivery/restart metrics unavailable (auto-paste off)"
      )
    }

    // `transcriptionModel` is the stable rawValue and the one worth comparing; `model` is the
    // display name kept as a fallback for rows written before that field existed.
    let models = dictations.compactMap { $0.transcriptionModel ?? $0.model }
    if let mix = histogram(models) { body.append("  models: \(mix)") }

    return ["", "Dictation"] + body
  }

  private static func promptSection(
    interactions: [InteractionMetaEntry], signals: [SignalLogEntry]
  ) -> [String] {
    let runs = interactions.filter { $0.mode == "prompt" }
    guard !runs.isEmpty else { return [] }
    let total = runs.count

    var parts = ["\(total) runs"]
    let cancels = signals.filter { $0.kind == "cancelledWhileProcessing" && $0.mode == "prompt" }
      .count
    if cancels > 0 {
      parts.append("\(cancels) cancelled while processing (\(pct(cancels, of: total)))")
    }
    let screenshots = runs.filter { $0.hadScreenshot == true }.count
    if screenshots > 0 { parts.append("screenshot attached in \(pct(screenshots, of: total))") }

    return ["", "Dictate Prompt", "  " + parts.joined(separator: " · ")]
  }

  private static func chatSection(
    interactions: [InteractionMetaEntry], signals: [SignalLogEntry]
  ) -> [String] {
    let turns = interactions.filter { $0.mode == "geminiChat" }
    guard !turns.isEmpty else { return [] }

    var body = ["  \(turns.count) turns"]

    let start = windowStart(signals, mode: "geminiChat")
    let retries = signals.filter { entry in
      guard entry.kind == "chatRetry" else { return false }
      return start == nil || isInWindow(entry, since: start)
    }.count
    // Only the user's Stop is a verdict. A watchdog cancellation says the main thread stalled,
    // which is a bug report about us, not about the answer — see `OutcomeSignal.chatStopped`.
    let stops = signals.filter { entry in
      guard entry.kind == "chatStopped", start == nil || isInWindow(entry, since: start) else {
        return false
      }
      return detail(entry, "reason") == "user"
    }.count

    let measurable = measurableCount(interactions, since: start, mode: "geminiChat")
    if retries > 0 || stops > 0 {
      // Retries get a rate when there is a denominator they belong to: a retried turn was logged
      // when its answer completed. Stops never do — a send killed mid-stream never reaches
      // `logChat` and never becomes a turn, so `stops / turns` would divide by a set that excludes
      // exactly the events being counted.
      var parts: [String] = []
      let countsOnly = measurable == 0
      if retries > 0 {
        parts.append(countsOnly ? "\(retries) retried" : "\(pct(retries, of: measurable)) retried (\(retries))")
      }
      if stops > 0 { parts.append("\(stops) stopped mid-stream") }
      let rendered = parts.joined(separator: " · ")
      if countsOnly || measurable == turns.count {
        body.append("  \(rendered)")
      } else {
        body.append("  of the \(measurable) since outcome tracking began: \(rendered)")
      }
    }

    if let mix = histogram(turns.compactMap { $0.model }) { body.append("  models: \(mix)") }
    return ["", "Chat"] + body
  }

  /// When signals for `mode` became attributable, or nil if none of them are.
  ///
  /// Signals began long after interactions did, and they will again whenever a new signal ships.
  /// Dividing a signal count by every interaction in the window reports a rate like "2.7%
  /// delivered" for an app that delivered nearly everything — the numerator covers days the
  /// denominator does not. Everything on both sides of a rate is therefore clipped to this start.
  ///
  /// Anchored on `refTs`, the interaction each signal judges, rather than the signal's own `ts`:
  /// anchoring on `ts` puts the very first judged interaction just outside the denominator while
  /// its verdict stays in the numerator, which is how a rate reaches 102%.
  ///
  /// Nil is not "no data". `refTs` comes from an in-memory marker, so a verdict delivered right
  /// after an app relaunch — pressing Retry on an answer from before the update — carries none.
  /// Real logs produced exactly that: four genuine retries, all unattributable. They judge turns
  /// that sit *outside* any window anchored on their own timestamps, so counting them against such
  /// a window read as a 33% retry rate on a machine whose real rate was far lower. Callers fall
  /// back to reporting those signals as a bare count — see `countsOnly` below.
  private static func windowStart(_ signals: [SignalLogEntry], mode: String) -> String? {
    signals.filter { $0.mode == mode }.compactMap { $0.refTs }.min()
  }

  /// Whether a signal falls inside the measurement window. Clipping the numerator to the same
  /// start as the denominator is what keeps a rate from exceeding 100%.
  private static func isInWindow(_ entry: SignalLogEntry, since start: String?) -> Bool {
    guard let start else { return false }
    return entry.ts >= start
  }

  /// How many interactions in `mode` fall inside the measurement window.
  private static func measurableCount(
    _ interactions: [InteractionMetaEntry], since start: String?, mode: String
  ) -> Int {
    guard let start else { return 0 }
    return interactions.filter { $0.mode == mode && $0.ts >= start }.count
  }

  /// Which apps dictation actually lands in — the single most actionable line in the report.
  /// Isolated in its own function on purpose: it is also the only section that names anything
  /// about the user's environment, so dropping it stays a one-line change.
  private static func pasteTargetSection(signals: [SignalLogEntry]) -> [String] {
    let targets = signals
      .filter { $0.kind == "pasted" }
      .compactMap { detail($0, "targetBundleId") }
      .filter { $0 != "unknown" }
    guard let line = histogram(targets) else { return [] }
    return ["", "Pasted into", "  " + line]
  }

  // MARK: - Helpers

  private static func decode<T: Decodable>(_ type: T.Type, from files: [URL]) -> [T] {
    let decoder = JSONDecoder()
    var entries: [T] = []
    for url in files {
      guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for line in content.components(separatedBy: .newlines) where !line.isEmpty {
        guard let data = line.data(using: .utf8),
          let entry = try? decoder.decode(T.self, from: data)
        else { continue }
        entries.append(entry)
      }
    }
    return entries
  }

  private static func detail(_ entry: SignalLogEntry, _ key: String) -> String? {
    guard allowedDetailKeys.contains(key) else { return nil }
    return entry.detail?[key]
  }

  /// Ties break on the key so the same data always renders the same report — a report that
  /// reshuffles between two builds is impossible to compare against an earlier one.
  private static func histogram(_ values: [String]) -> String? {
    guard !values.isEmpty else { return nil }
    var counts: [String: Int] = [:]
    for value in values { counts[value, default: 0] += 1 }
    return counts
      .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
      .prefix(topEntries)
      .map { "\($0.key) \(pct($0.value, of: values.count))" }
      .joined(separator: " · ")
  }

  /// One decimal below 10 %, whole numbers above: "4.1%" carries information, "83.7%" does not.
  private static func pct(_ count: Int, of total: Int) -> String {
    guard total > 0 else { return "0%" }
    let value = Double(count) / Double(total) * 100
    return value > 0 && value < 10
      ? String(format: "%.1f%%", value)
      : String(format: "%.0f%%", value)
  }

  /// A median, never the raw sequence: a list of gap timings is a behavioural fingerprint, an
  /// aggregate is not.
  private static func medianGap(_ entries: [SignalLogEntry]) -> String? {
    let gaps = entries.compactMap { $0.gapMs }.sorted()
    guard !gaps.isEmpty else { return nil }
    let mid = gaps.count / 2
    let ms = gaps.count.isMultiple(of: 2) ? Double(gaps[mid - 1] + gaps[mid]) / 2 : Double(gaps[mid])
    return String(format: "%.1f s", ms / 1000)
  }

  private static func day(_ timestamp: String) -> String { String(timestamp.prefix(10)) }

  /// Appends the footer and guarantees the whole thing fits `maxCharacters`. The footer is added
  /// after trimming, never trimmed itself — it is the sentence that tells the reader what the
  /// report does not contain.
  private static func capped(_ body: String) -> String {
    let footer = "---\nCounts and timings only — no transcripts, prompts, replies, or audio."
    let budget = maxCharacters - footer.count - 2
    guard body.count > budget else { return body + "\n" + footer }
    return String(body.prefix(budget - 1)) + "…\n" + footer
  }
}

// MARK: - Narrow decoder

/// The interaction stream's fields, minus everything the user said or the model answered.
///
/// Decoding through this instead of `InteractionLogEntry` is what makes the report incapable of
/// leaking content — not careful printing, which the next edit could undo. **Never add `result`,
/// `selectedText`, `userInstruction`, `modelResponse`, `text`, `voice`, or `audioRef` here.`
private struct InteractionMetaEntry: Decodable {
  let ts: String
  let mode: String
  let model: String?
  let transcriptionModel: String?
  let hadScreenshot: Bool?
}
