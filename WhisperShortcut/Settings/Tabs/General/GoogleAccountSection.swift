//
//  GoogleAccountSection.swift
//  WhisperShortcut
//

import SwiftUI

struct GoogleAccountSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var googleSignInEmail: String? = nil
  @State private var googleSignInRefresh: Int = 0
  @State private var googleSignInError: String? = nil
  @State private var isSigningIn = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Google Account",
        subtitle: "Sign in with Google to use Gemini without an API key"
      )
      .id(googleSignInRefresh)

      let authService = DefaultGoogleAuthService.shared
      let isSignedIn = authService.isSignedIn()

      if isSignedIn {
        HStack(alignment: .center, spacing: 16) {
          if let email = googleSignInEmail ?? authService.signedInUserEmail() {
            Text("Signed in as \(email)")
              .font(.callout)
              .foregroundColor(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Button("Sign out") {
            authService.signOut()
            googleSignInEmail = nil
            googleSignInRefresh += 1
          }
          .buttonStyle(.bordered)
        }
      } else {
        HStack(alignment: .center, spacing: 16) {
          Button("Sign in with Google") {
            isSigningIn = true
            googleSignInError = nil
            Task {
              do {
                try await authService.signIn()
                await MainActor.run {
                  googleSignInEmail = authService.signedInUserEmail()
                  googleSignInRefresh += 1
                  isSigningIn = false
                }
              } catch {
                await MainActor.run {
                  googleSignInError = SpeechErrorFormatter.formatForUser(error)
                  isSigningIn = false
                  googleSignInRefresh += 1
                }
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSigningIn)
          if isSigningIn {
            ProgressView()
              .scaleEffect(0.8)
          }
        }
        if let err = googleSignInError {
          Text(err)
            .font(.caption)
            .foregroundColor(.red)
        }
      }

      Text("When signed in, Gemini usage is billed to the app's Google Cloud project. You can also use an API key below instead.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear {
      googleSignInEmail = DefaultGoogleAuthService.shared.signedInUserEmail()
    }
  }
}
