import SwiftUI

/// Connection status of an API key, including live-validation states.
enum APIKeyStatus {
  case notSet        // no key entered
  case checking      // validation request in flight
  case connected     // provider accepted the key
  case invalid       // provider rejected the key
  case unverified    // key present but couldn't be verified (offline / unexpected error)
}

/// Small status badge shown next to an API-key section header. Reflects whether a key is set
/// and, once validated against the provider, whether it actually works.
struct APIKeyStatusChip: View {
  let status: APIKeyStatus

  var body: some View {
    HStack(spacing: 4) {
      if status == .checking {
        ProgressView()
          .controlSize(.small)
          .scaleEffect(0.7)
      } else {
        Image(systemName: symbol)
          .font(.caption)
      }
      Text(label)
        .font(.caption)
        .fontWeight(.medium)
    }
    .foregroundColor(color)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(color.opacity(0.12)))
    .help(helpText)
    .accessibilityLabel(label)
  }

  private var symbol: String {
    switch status {
    case .notSet: return "circle"
    case .checking: return "circle"
    case .connected: return "checkmark.circle.fill"
    case .invalid: return "xmark.circle.fill"
    case .unverified: return "questionmark.circle.fill"
    }
  }

  private var label: String {
    switch status {
    case .notSet: return "Not set"
    case .checking: return "Checking…"
    case .connected: return "Connected"
    case .invalid: return "Invalid key"
    case .unverified: return "Unverified"
    }
  }

  private var color: Color {
    switch status {
    case .notSet, .checking, .unverified: return .secondary
    case .connected: return .green
    case .invalid: return .red
    }
  }

  private var helpText: String {
    switch status {
    case .notSet: return "No API key entered"
    case .checking: return "Checking the key with the provider…"
    case .connected: return "The provider accepted this key"
    case .invalid: return "The provider rejected this key — check for typos or an expired key"
    case .unverified: return "Couldn't verify the key (offline or provider unreachable)"
    }
  }
}

/// Self-contained badge that validates an API key against its provider and shows the result.
/// Drop it next to a key field, passing the current key string; it debounces edits, runs a
/// lightweight validation request, and updates the chip. Network errors show "Unverified",
/// never "Invalid", so being offline never falsely flags a good key.
struct APIKeyStatusBadge: View {
  let provider: APIKeyProvider
  let key: String

  @State private var status: APIKeyStatus = .notSet
  @State private var validation: Task<Void, Never>?

  var body: some View {
    APIKeyStatusChip(status: status)
      .onAppear { schedule(debounced: false) }
      .onChange(of: key) { _, _ in schedule(debounced: true) }
      .onDisappear { validation?.cancel() }
  }

  private func schedule(debounced: Bool) {
    validation?.cancel()
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { status = .notSet; return }
    status = .checking
    validation = Task {
      // Debounce keystrokes so we don't hit the provider on every character.
      if debounced {
        try? await Task.sleep(nanoseconds: 800_000_000)
        if Task.isCancelled { return }
      }
      let result = await APIKeyValidator.validate(provider, key: trimmed)
      if Task.isCancelled { return }
      await MainActor.run {
        switch result {
        case .valid: status = .connected
        case .invalid: status = .invalid
        case .unverified: status = .unverified
        }
      }
    }
  }
}
