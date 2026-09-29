import SwiftUI

/// One row of the transcript's tool-step group, built from a persisted `ChatToolCallRecord` or a
/// live `ChatToolStep` so both render through the same view.
struct ChatToolStepDisplay: Identifiable, Equatable {
  enum Status: Equatable { case running, awaitingApproval, done, failed, denied }

  let id: String
  let label: String
  let status: Status
  let summary: String?
  /// Raw JSON for the "Details" disclosure; nil while the step is live.
  let argsJSON: String?
  let resultJSON: String?

  static func from(record: ChatToolCallRecord, index: Int) -> ChatToolStepDisplay {
    let args = jsonObject(record.argsJSON) ?? [:]
    let status: Status
    var summary = record.summary
    switch record.status {
    case .done: status = .done
    case .failed: status = .failed
    case .denied: status = .denied
    case nil:
      // Records from before the display fields: derive from the stored (possibly capped) result.
      let response = jsonObject(record.resultJSON) ?? [:]
      if let error = ChatToolRegistry.resultError(response) {
        status = error.hasPrefix("The user denied") ? .denied : .failed
        summary = status == .failed ? error : nil
      } else {
        status = .done
        summary = ChatToolRegistry.resultSummary(name: record.name, response: response)
      }
    }
    return ChatToolStepDisplay(
      id: "\(index)-\(record.name)",
      label: ChatToolRegistry.stepLabel(name: record.name, args: args, done: true),
      status: status,
      summary: summary,
      argsJSON: record.argsJSON,
      resultJSON: record.resultJSON)
  }

  static func from(step: ChatToolStep) -> ChatToolStepDisplay {
    let status: Status
    switch step.phase {
    case .running: status = .running
    case .awaitingApproval: status = .awaitingApproval
    case .done: status = .done
    case .failed: status = .failed
    case .denied: status = .denied
    }
    return ChatToolStepDisplay(
      id: step.id.uuidString,
      label: step.isActive ? step.runningLabel : step.doneLabel,
      status: status,
      summary: step.resultSummary,
      argsJSON: nil,
      resultJSON: nil)
  }

  var isActive: Bool { status == .running || status == .awaitingApproval }

  private static func jsonObject(_ json: String) -> [String: Any]? {
    guard let data = json.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}

/// Header line for a group: the single step's label, or "Used N tools" with failure counts.
enum ChatToolStepsSummary {
  static func header(for steps: [ChatToolStepDisplay]) -> String {
    if let active = steps.last(where: \.isActive) {
      return active.status == .awaitingApproval ? "Waiting for your approval…" : active.label
    }
    if steps.count == 1, let only = steps.first {
      return [only.label, statusSuffix(only)].compactMap { $0 }.joined(separator: " · ")
    }
    var parts = ["Used \(steps.count) tools"]
    let failed = steps.filter { $0.status == .failed }.count
    let denied = steps.filter { $0.status == .denied }.count
    if failed > 0 { parts.append("\(failed) failed") }
    if denied > 0 { parts.append("\(denied) denied") }
    return parts.joined(separator: " · ")
  }

  /// "3 results" / "Failed" / "Denied by you" for one step.
  static func statusSuffix(_ step: ChatToolStepDisplay) -> String? {
    switch step.status {
    case .failed: return "Failed"
    case .denied: return "Denied by you"
    case .done: return step.summary
    case .running, .awaitingApproval: return nil
    }
  }
}

/// Collapsible tool-step group shown above an assistant reply. Collapsed by default; plain `Text`
/// only — no `.textSelection` anywhere in the transcript (see chat-freeze-investigation.md).
struct ChatToolStepsView: View {
  let steps: [ChatToolStepDisplay]
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 6) {
          headerIcon
          Text(ChatToolStepsSummary.header(for: steps))
            .lineLimit(1)
            .truncationMode(.middle)
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .font(.system(size: 13))
        .foregroundColor(ChatTheme.secondaryText)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .pointerCursorOnHover()
      .accessibilityLabel(ChatToolStepsSummary.header(for: steps))
      .accessibilityHint(isExpanded ? "Hide tool steps" : "Show tool steps")

      if isExpanded {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(steps) { step in
            ChatToolStepRow(step: step)
          }
        }
        .padding(.leading, 20)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var headerIcon: some View {
    if steps.contains(where: \.isActive) {
      ProgressView().controlSize(.mini).frame(width: 13, height: 13)
    } else if steps.contains(where: { $0.status == .failed }) {
      Image(systemName: "exclamationmark.circle").foregroundColor(Color.red.opacity(0.8))
    } else {
      Image(systemName: "wrench.and.screwdriver")
    }
  }
}

private struct ChatToolStepRow: View {
  let step: ChatToolStepDisplay
  @State private var showsDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        statusIcon
          .frame(width: 12)
        Text(step.label)
          .foregroundColor(ChatTheme.primaryText.opacity(0.8))
          .lineLimit(2)
        if let suffix = ChatToolStepsSummary.statusSuffix(step) {
          Text("· \(suffix)")
            .foregroundColor(ChatTheme.secondaryText)
            .lineLimit(2)
        }
        if step.argsJSON != nil {
          Button(showsDetails ? "Hide details" : "Details") { showsDetails.toggle() }
            .buttonStyle(.plain)
            .foregroundColor(ChatTheme.secondaryText)
            .underline()
            .pointerCursorOnHover()
        }
      }
      .font(.system(size: 12))
      if showsDetails, let args = step.argsJSON {
        detailsBlock(args: args, result: step.resultJSON ?? "")
      }
    }
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch step.status {
    case .running, .awaitingApproval:
      ProgressView().controlSize(.mini)
    case .done:
      Image(systemName: "checkmark").foregroundColor(ChatTheme.secondaryText)
    case .failed:
      Image(systemName: "xmark").foregroundColor(Color.red.opacity(0.8))
    case .denied:
      Image(systemName: "hand.raised").foregroundColor(ChatTheme.secondaryText)
    }
  }

  private func detailsBlock(args: String, result: String) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Input: \(args)")
        Text("Result: \(result)")
          .lineLimit(12)
      }
      .font(.system(size: 11, design: .monospaced))
      .foregroundColor(ChatTheme.secondaryText)
      .fixedSize(horizontal: true, vertical: false)
      .padding(8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(ChatTheme.primaryText.opacity(ChatTheme.borderOpacity), lineWidth: 1)
    )
  }
}

/// Live variant for the streaming bubble: observes the turn's `ToolStepsBuffer` so only this view
/// re-renders per step. Web search stays in the typing indicator only — it has no persisted
/// record, so showing it here would make the group jump at finalize.
struct LiveChatToolStepsView: View {
  @ObservedObject var buffer: ToolStepsBuffer

  var body: some View {
    let steps = buffer.steps
      .filter { $0.name != ChatToolRegistry.webSearchStepName }
      .map(ChatToolStepDisplay.from(step:))
    if !steps.isEmpty {
      ChatToolStepsView(steps: steps)
    }
  }
}
