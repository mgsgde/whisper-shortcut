//
//  BalanceSection.swift
//  WhisperShortcut
//
//  Balance display (from backend API), Dashboard URL setting, and "Top up balance" link.
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
        subtitle: "Balance is stored on the backend (same URL as Proxy API). Top up opens the Dashboard in your browser."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Dashboard URL:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        TextField("https://your-dashboard.run.app", text: $viewModel.data.dashboardBaseURL)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onChange(of: viewModel.data.dashboardBaseURL) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.dashboardBaseURL)
          }

        Spacer()
      }

      if DefaultGoogleAuthService.shared.isSignedIn(), !(viewModel.data.proxyAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
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

        let dashboardURL = viewModel.data.dashboardBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dashboardURL.isEmpty {
          Button("Top up balance") {
            viewModel.openDashboardForTopUp()
          }
          .buttonStyle(.borderedProminent)
        }
      }

      Text("Set the Proxy API base URL above to fetch balance. Sign in with Google and set Dashboard URL to open the top-up page in your browser.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear {
      if DefaultGoogleAuthService.shared.isSignedIn(), BackendAPIClient.baseURL() != nil {
        Task { await viewModel.refreshBalance() }
      }
    }
  }

  private func formatBalance(_ cent: Int) -> String {
    let euros = Double(cent) / 100.0
    return String(format: "€%.2f", euros)
  }
}
