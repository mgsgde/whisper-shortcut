//
//  OfflineModelStatusView.swift
//  WhisperShortcut
//
//  What Chat shows while its offline MLX model is still getting ready. A multi-gigabyte first
//  download behind three pulsing dots reads as a hang (2026-10-18, Qwen3.5 9B), so the dots give
//  way to the download itself — and the composer's model chip says so from the moment the model
//  is picked, before any message is sent.
//

import SwiftUI

/// The typing dots, or — while `model` is downloading or loading — that status instead.
/// Observes the store here, not in `ChatView`, so a progress tick re-renders this pill only.
struct ChatPendingReplyIndicator: View {
  let model: LocalLLMModelType?
  let typing: AnyView
  @ObservedObject private var store = LocalLLMModelManager.shared

  var body: some View {
    if let model, let phase = store.readyPhase[model] {
      OfflineModelStatusView(model: model, phase: phase)
    } else {
      typing
    }
  }
}

/// Inline card: what is happening, how far along, and that the message is not lost.
struct OfflineModelStatusView: View {
  let model: LocalLLMModelType
  let phase: ReadyPhase

  private static let width: CGFloat = 340

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: icon)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.accentColor)
        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(ChatTheme.primaryText)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        if let amount {
          Text(amount)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(ChatTheme.secondaryText)
        }
      }
      ThinProgressBar(fraction: fraction)
      Text(caption)
        .font(.system(size: 11))
        .foregroundStyle(ChatTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .frame(width: Self.width, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14).fill(ChatTheme.controlBackground))
    .accessibilityElement(children: .combine)
  }

  private var fraction: Double? {
    if case .downloading(let fraction, _) = phase { return fraction }
    return nil
  }

  private var icon: String {
    if case .downloading = phase { return "arrow.down.circle" }
    return "memorychip"
  }

  private var title: String {
    switch phase {
    case .downloading(_, let isRetry):
      return isRetry ? "Downloading \(model.displayName) again" : "Downloading \(model.displayName)"
    case .loading:
      return "Loading \(model.displayName) into memory…"
    }
  }

  private var amount: String? {
    guard let fraction else { return nil }
    return "\(Int(fraction * 100))% of \(model.estimatedSizeLabel)"
  }

  private var caption: String {
    switch phase {
    case .downloading(_, let isRetry):
      return isRetry
        ? "The last download was incomplete. Your message is sent as soon as it's ready."
        : "One-time download, then it runs offline. Your message is sent as soon as it's ready."
    case .loading:
      return "Almost there — the reply starts once the model is loaded."
    }
  }
}

/// 3pt bar. `nil` is the loading phase: a segment sweeps across because there is no fraction to
/// show, and a frozen bar would be the hang this view exists to rule out.
private struct ThinProgressBar: View {
  let fraction: Double?

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(ChatTheme.primaryText.opacity(0.12))
        if let fraction {
          Capsule()
            .fill(Color.accentColor)
            .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            .animation(.easeOut(duration: 0.25), value: fraction)
        } else {
          TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let period = 1.4
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let segment = geo.size.width * 0.3
            Capsule()
              .fill(Color.accentColor)
              .frame(width: segment)
              .offset(x: -segment + (geo.size.width + segment) * t)
          }
          .clipShape(Capsule())
        }
      }
    }
    .frame(height: 3)
  }
}

/// Small ring beside the composer's model chip while the selected offline model is downloading or
/// loading — visible from the picker tap on, not only after a message is sent.
struct ComposerModelReadinessBadge: View {
  let model: LocalLLMModelType?
  @ObservedObject private var store = LocalLLMModelManager.shared

  var body: some View {
    if let model, let phase = store.readyPhase[model] {
      HStack(spacing: 4) {
        ProgressRing(fraction: { if case .downloading(let f, _) = phase { return f } else { return nil } }())
          .frame(width: 11, height: 11)
        Text(shortLabel(phase))
          .font(.caption2)
          .monospacedDigit()
          .foregroundStyle(ChatTheme.secondaryText)
      }
      .help(store.statusLine(phase, for: model))
      .transition(.opacity)
    }
  }

  private func shortLabel(_ phase: ReadyPhase) -> String {
    switch phase {
    case .downloading(let fraction, _): return "\(Int(fraction * 100))%"
    case .loading: return "Loading…"
    }
  }
}

/// Determinate ring for a fraction, a spinning arc for `nil`.
private struct ProgressRing: View {
  let fraction: Double?

  var body: some View {
    ZStack {
      Circle().stroke(ChatTheme.primaryText.opacity(0.18), lineWidth: 1.5)
      if let fraction {
        Circle()
          .trim(from: 0, to: min(max(fraction, 0.02), 1))
          .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.easeOut(duration: 0.25), value: fraction)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
          let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
          Circle()
            .trim(from: 0, to: 0.3)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(angle))
        }
      }
    }
  }
}
