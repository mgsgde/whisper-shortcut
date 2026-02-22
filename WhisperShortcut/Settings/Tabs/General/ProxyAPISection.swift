//
//  ProxyAPISection.swift
//  WhisperShortcut
//
//  Info only: when signed in, Gemini and balance use the app’s backend. URL is set by the app.
//

import SwiftUI
import AppKit

struct ProxyAPISection: View {
  var body: some View {
    SectionHeader(
      title: "Backend",
      subtitle: "When signed in with Google, Gemini and balance use the WhisperShortcut backend. No setup required."
    )
  }
}
