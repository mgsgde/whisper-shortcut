import SwiftUI

// MARK: - Metric vocabulary

/// The scorecard's numbers as the UI names them. Every one of them is "lower is better", which is
/// what lets a single colour rule (down = green, up = orange) apply across the board.
enum ScorecardMetric: CaseIterable, Identifiable {
  case rejectedSpellings
  case followUps
  case dashes
  case promptRetries
  case chatRetries

  var id: Self { self }

  var title: String {
    switch self {
    case .rejectedSpellings: return String(localized: "Rejected spellings")
    case .followUps: return String(localized: "Follow-up fixes")
    case .dashes: return String(localized: "Dashes added")
    case .promptRetries: return String(localized: "Prompt retries")
    case .chatRetries: return String(localized: "Chat retries")
    }
  }

  /// Column header in the weekly table, where the full title would not fit.
  var shortTitle: String {
    switch self {
    case .rejectedSpellings: return String(localized: "Spellings")
    case .followUps: return String(localized: "Follow-ups")
    case .dashes: return String(localized: "Dashes")
    case .promptRetries: return String(localized: "Prompt retries")
    case .chatRetries: return String(localized: "Chat retries")
    }
  }

  var explanation: String {
    switch self {
    case .rejectedSpellings:
      return String(localized: "Spellings you rejected in the Glossary (X (not \"Y\")) that still showed up, per 100 dictations.")
    case .followUps:
      return String(localized: "Share of Dictate Prompts that reworked the previous result within 5 minutes, because the first one missed.")
    case .dashes:
      return String(localized: "Share of Dictate Prompts that added an em or en dash to text that had none.")
    case .promptRetries:
      return String(localized: "Dictate Prompts re-run on the same selection with a new instruction, per 100 prompts.")
    case .chatRetries:
      return String(localized: "Chat messages sent again because the answer wasn't good enough, per 100 chat turns.")
    }
  }

  var isPercent: Bool { self == .followUps || self == .dashes }

  func value(in metrics: ScorecardMetrics) -> Double? {
    switch self {
    case .rejectedSpellings: return metrics.rejectedSpellingHitsPer100
    case .followUps: return metrics.followUpRate
    case .dashes: return metrics.dashInsertionRate
    case .promptRetries: return metrics.promptRetriesPer100
    case .chatRetries: return metrics.chatRetriesPer100
    }
  }

  /// The denominator, so a rate built on three prompts can be shown as the guess it is.
  func sampleSize(in metrics: ScorecardMetrics) -> Int {
    switch self {
    case .rejectedSpellings: return metrics.transcriptions
    case .followUps, .promptRetries: return metrics.prompts
    case .dashes: return metrics.dashFreeSelections
    case .chatRetries: return metrics.chatTurns
    }
  }

  var sampleNoun: String {
    switch self {
    case .rejectedSpellings: return "dictations"
    case .followUps, .promptRetries, .dashes: return "prompts"
    case .chatRetries: return "chat turns"
    }
  }

  func formatted(_ value: Double?) -> String {
    guard let value else { return "–" }
    if isPercent { return "\(Int(value.rounded()))%" }
    return value < 10 ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
  }

  /// Which numbers a change to a section can plausibly move. A glossary edit cannot change how
  /// often Dictate Prompt adds dashes, so the review panel does not pretend it might.
  static func relevant(to section: SystemPromptSection?) -> [ScorecardMetric] {
    switch section {
    case .dictation?, .whisperGlossary?: return [.rejectedSpellings]
    case .promptMode?: return [.followUps, .dashes, .promptRetries]
    case .chat?: return [.chatRetries]
    case .readAloudRewrite?: return []
    case nil: return ScorecardMetric.allCases
    }
  }
}

/// Below this many events a rate is still shown, but greyed out and never coloured as a trend.
private let scorecardMinimumSample = 10

extension SystemPromptSection {
  var scorecardDisplayName: String {
    switch self {
    case .dictation: return String(localized: "Dictation")
    case .whisperGlossary: return String(localized: "Glossary")
    case .promptMode: return String(localized: "Dictate Prompt")
    case .chat: return String(localized: "Chat")
    case .readAloudRewrite: return String(localized: "Read Aloud")
    }
  }
}

private func scorecardSourceName(_ source: String) -> String {
  PromptHistorySource.displayName(for: source)
}

// MARK: - Loading

/// Reads the scorecard off the main thread. The logs are several MB of JSONL; parsing them on the
/// main thread would stall the Settings window or the review panel while it opens.
@MainActor
final class SmartImprovementScorecardModel: ObservableObject {
  @Published private(set) var report: SmartImprovementScorecard.Report?
  let section: SystemPromptSection?

  init(section: SystemPromptSection? = nil) {
    self.section = section
  }

  func load() async {
    let directory = ContextLogger.shared.directoryURL
    let glossary = SystemPromptsStore.shared.loadWhisperGlossary()
    let sectionKey = section?.rawValue
    let result = await Task.detached(priority: .utility) {
      SmartImprovementScorecard.report(
        directory: directory, currentGlossary: glossary, section: sectionKey)
    }.value
    report = result
  }
}

/// Why there is nothing to show. Offline Mode keeps no interaction logs at all, so the scorecard
/// says that instead of showing a misleading row of zeros.
private enum ScorecardEmptyReason {
  case offline, loggingOff, noData

  static var current: ScorecardEmptyReason {
    if OfflineMode.isEnabled { return .offline }
    if !ContextLoggingPreference.storedFlag { return .loggingOff }
    return .noData
  }

  var message: String {
    switch self {
    case .offline:
      return String(localized: "Offline Mode keeps no usage logs, so there is nothing to measure.")
    case .loggingOff:
      return String(localized: "Turn on \"Save usage data\" to start measuring.")
    case .noData:
      return String(localized: "Nothing to measure yet. Numbers appear once you've used the app for a few days.")
    }
  }
}

// MARK: - Shared pieces

/// "17% → 9%", with the second value coloured by direction once both rest on enough data.
private struct ScorecardChange: View {
  let metric: ScorecardMetric
  let before: ScorecardMetrics
  let after: ScorecardMetrics

  private var beforeValue: Double? { metric.value(in: before) }
  private var afterValue: Double? { metric.value(in: after) }
  private var enoughData: Bool {
    metric.sampleSize(in: before) >= scorecardMinimumSample
      && metric.sampleSize(in: after) >= scorecardMinimumSample
  }

  private var trendColor: Color {
    guard enoughData, let b = beforeValue, let a = afterValue else { return .secondary }
    // Moves smaller than a tenth of the old value (or one point) are noise at these sample sizes.
    let tolerance = max(b * 0.1, metric.isPercent ? 1 : 0.1)
    if a < b - tolerance { return .green }
    if a > b + tolerance { return .orange }
    return .secondary
  }

  var body: some View {
    HStack(spacing: 4) {
      Text(metric.formatted(beforeValue))
        .foregroundStyle(.secondary)
      Image(systemName: "arrow.right")
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(metric.formatted(afterValue))
        .fontWeight(.semibold)
        .foregroundStyle(trendColor)
    }
    .monospacedDigit()
    .help(
      "\(metric.explanation)\nBefore: \(metric.sampleSize(in: before)) \(metric.sampleNoun) · since: \(metric.sampleSize(in: after)) \(metric.sampleNoun)"
    )
  }
}

private func scorecardChangeCaption(_ change: SmartImprovementScorecard.Report.Change) -> String {
  let section = SystemPromptSection(rawValue: change.section)?.scorecardDisplayName ?? change.section
  let date = change.ts.formatted(.dateTime.month(.abbreviated).day())
  return "\(section), by \(scorecardSourceName(change.source)), \(date)"
}

private struct ScorecardLoading: View {
  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Counting…").font(.callout).foregroundStyle(.secondary)
    }
  }
}

// MARK: - Settings card

/// Settings → Smart Improvement: did the changes you accepted actually help?
struct SmartImprovementScorecardSection: View {
  @StateObject private var model = SmartImprovementScorecardModel()

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Scorecard",
        systemImage: "chart.bar.xaxis",
        subtitle: "Did the changes you accepted help? Counted on this Mac from your usage logs, without AI, and nothing leaves your Mac. Lower is better for every number."
      )

      Group {
        if let report = model.report {
          if report.weeks.isEmpty && report.current.isEmpty {
            emptyState
          } else {
            VStack(alignment: .leading, spacing: 16) {
              sinceLastChange(report.lastChange)
              Divider()
              weeklyTable(report.weeks)
            }
          }
        } else {
          ScorecardLoading()
        }
      }
      .padding(SettingsConstants.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )
    }
    .task { await model.load() }
  }

  private var emptyState: some View {
    HStack(spacing: 10) {
      Image(systemName: "chart.bar")
        .font(.title3)
        .foregroundStyle(.tertiary)
      Text(ScorecardEmptyReason.current.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func sinceLastChange(_ change: SmartImprovementScorecard.Report.Change?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("Since the last change")
          .font(.callout)
          .fontWeight(.semibold)
        if let change {
          Text(scorecardChangeCaption(change))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if let change {
        if change.after.isEmpty {
          Text("No usage since then yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          let relevant = ScorecardMetric.relevant(to: SystemPromptSection(rawValue: change.section))
          HStack(alignment: .top, spacing: 24) {
            ForEach(relevant.isEmpty ? ScorecardMetric.allCases : relevant) { metric in
              VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                ScorecardChange(metric: metric, before: change.before, after: change.after)
                  .font(.callout)
              }
            }
          }
        }
      } else {
        Text("The next change you accept is measured from then on.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func weeklyTable(_ weeks: [ScorecardWeek]) -> some View {
    Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
      GridRow {
        Text("Week of")
          .gridColumnAlignment(.leading)
        ForEach(ScorecardMetric.allCases) { metric in
          Text(metric.shortTitle)
            .help(metric.explanation)
        }
      }
      .font(.caption)
      .fontWeight(.medium)
      .foregroundStyle(.secondary)

      Divider().gridCellUnsizedAxes(.horizontal)

      ForEach(weeks.reversed()) { week in
        GridRow {
          Text(week.start.formatted(.dateTime.month(.abbreviated).day()))
            .foregroundStyle(.secondary)
            .help(week.id)
          ForEach(ScorecardMetric.allCases) { metric in
            let thin = metric.sampleSize(in: week.metrics) < scorecardMinimumSample
            Text(metric.formatted(metric.value(in: week.metrics)))
              .foregroundStyle(thin ? .tertiary : .primary)
              .help(
                "\(metric.sampleSize(in: week.metrics)) \(metric.sampleNoun)\(thin ? ", too few to read much into" : "")"
              )
          }
        }
        .font(.callout)
        .monospacedDigit()
      }
    }
  }
}

// MARK: - Review panel strip

/// One block above the diff in the review panel: how the numbers this section can move have gone
/// since its last change, so accepting the next one is not a blind decision.
struct SmartImprovementScorecardStrip: View {
  @StateObject private var model: SmartImprovementScorecardModel
  private let metrics: [ScorecardMetric]

  init(section: SystemPromptSection) {
    _model = StateObject(wrappedValue: SmartImprovementScorecardModel(section: section))
    metrics = ScorecardMetric.relevant(to: section)
  }

  var body: some View {
    if !metrics.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Measured so far")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        content
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
      }
      .task { await model.load() }
    }
  }

  @ViewBuilder
  private var content: some View {
    if let report = model.report {
      if report.current.isEmpty && report.lastChange == nil {
        Text(ScorecardEmptyReason.current.message)
          .font(.callout)
          .foregroundStyle(.secondary)
      } else if let change = report.lastChange, !change.after.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Since the last change (\(scorecardChangeCaption(change)))")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack(spacing: 20) {
            ForEach(metrics) { metric in
              HStack(spacing: 6) {
                Text(metric.title).foregroundStyle(.secondary)
                ScorecardChange(metric: metric, before: change.before, after: change.after)
              }
            }
          }
          .font(.callout)
        }
      } else {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            report.lastChange == nil
              ? ("Last 4 weeks. No earlier change was measured, so accepting this one sets the baseline." as LocalizedStringKey)
              : "Last 4 weeks. No usage since the last change yet."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          HStack(spacing: 20) {
            ForEach(metrics) { metric in
              HStack(spacing: 6) {
                Text(metric.title).foregroundStyle(.secondary)
                Text(metric.formatted(metric.value(in: report.current)))
                  .fontWeight(.semibold)
                  .monospacedDigit()
                  .help(metric.explanation)
              }
            }
          }
          .font(.callout)
        }
      }
    } else {
      ScorecardLoading()
    }
  }
}
