//
//  BalanceSection.swift
//  WhisperShortcut
//
//  Balance display (from backend API) and "Top up balance" link. Dashboard URL is fixed by the app.
//

import SwiftUI
import AppKit

struct BalanceSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var isRefreshing = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Balance & top-up",
        subtitle: "Balance is stored on the WhisperShortcut backend. Top up opens the Dashboard in your browser."
      )

      if DefaultGoogleAuthService.shared.isSignedIn() {
        HStack(alignment: .center, spacing: 16) {
          Text("Balance:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: SettingsConstants.labelWidth, alignment: .leading)

          if let cent = viewModel.data.balanceCent {
            Text(formatBalance(cent))
              .font(.body.monospacedDigit())
          } else if let msg = viewModel.data.balanceLoadErrorMessage {
            Text(msg)
              .font(.caption)
              .foregroundColor(.secondary)
          } else {
            Text("—")
              .foregroundColor(.secondary)
          }

          Button("Refresh") {
            isRefreshing = true
            Task {
              await viewModel.refreshBalance()
              await MainActor.run { isRefreshing = false }
            }
          }
          .buttonStyle(.bordered)
          .disabled(isRefreshing)

          if isRefreshing {
            ProgressView()
              .scaleEffect(0.8)
          }

          Spacer()
        }

        Button("Top up balance") {
          viewModel.openDashboardForTopUp()
        }
        .buttonStyle(.borderedProminent)
      }

      Text("Sign in with Google to see balance and top up.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear {
      if DefaultGoogleAuthService.shared.isSignedIn() {
        Task { await viewModel.refreshBalance() }
      }
    }
  }

  private func formatBalance(_ cent: Int) -> String {
    let euros = Double(cent) / 100.0
    return String(format: "€%.2f", euros)
  }
}
