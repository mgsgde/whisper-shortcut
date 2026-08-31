//
//  OfflineMode.swift
//  WhisperShortcut
//
//  One switch that turns the app into a device-local dictation tool: no cloud model, no
//  cloud integration, no usage log on disk. Built for settings where the *content* of a
//  dictation is regulated — a medical practice dictating findings, a lawyer dictating case
//  notes — and where "the audio never leaves this Mac" has to be a property of the app, not
//  a promise about which model the user remembered to pick.
//

import Foundation

// MARK: - Offline Mode

enum OfflineMode {

  /// Whether device-local-only operation is switched on. Off unless the user turns it on;
  /// `bool(forKey:)` answers `false` for an unset key, so no seeding is needed.
  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: UserDefaultsKeys.offlineModeEnabled)
  }

  static func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.offlineModeEnabled)
  }

  /// Message shown when a request was stopped because Offline Mode is on.
  static func blockedMessage(for url: URL?) -> String {
    let host = url?.host ?? "a remote server"
    return
      "Offline Mode is on, so nothing may leave this Mac — the request to \(host) was blocked. "
      + "Pick an on-device Whisper model for dictation, or turn Offline Mode off in Settings → Privacy & Permissions."
  }

  // MARK: - What counts as "does not leave this Mac"

  /// Whether a request must be stopped, given whether the mode is on. Split from `isEnabled` so
  /// the guard's whole decision can be tested without switching the real mode on inside a test
  /// process that is also making live network calls.
  static func shouldBlock(_ url: URL?, offlineMode: Bool) -> Bool {
    offlineMode && !allows(url)
  }

  /// Whether a request may proceed while Offline Mode is on.
  ///
  /// The rule is about where the bytes go, not which feature sends them: loopback and the
  /// local network are allowed (a Whisper server or an Ollama instance in the practice is
  /// still under the practice's control), everything routable on the internet is not.
  /// Non-HTTP schemes are not network egress and pass through untouched.
  static func allows(_ url: URL?) -> Bool {
    guard let url else { return false }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return true
    }
    return isLocalHost(url.host)
  }

  /// True for hosts that cannot be reached from outside the user's own machine or network:
  /// loopback, `.local` (Bonjour), link-local, and the three RFC 1918 private IPv4 ranges.
  ///
  /// Pure and host-only on purpose — it is the one rule the whole mode rests on, so it is
  /// unit-tested rather than inferred from behaviour.
  static func isLocalHost(_ host: String?) -> Bool {
    guard var host = host?.lowercased(), !host.isEmpty else { return false }
    // Strip an IPv6 literal's brackets and a fully-qualified name's trailing dot.
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host.hasSuffix(".") { host.removeLast() }

    if host == "localhost" || host.hasSuffix(".localhost") { return true }
    if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
    // Bonjour names (`praxis-server.local`) resolve only inside the local network.
    if host.hasSuffix(".local") { return true }

    guard let octets = ipv4Octets(host) else { return false }
    switch (octets[0], octets[1]) {
    case (127, _): return true  // loopback
    case (10, _): return true  // RFC 1918
    case (192, 168): return true  // RFC 1918
    case (172, 16...31): return true  // RFC 1918
    case (169, 254): return true  // link-local
    default: return false
    }
  }

  /// Parses a dotted-quad IPv4 literal. Returns nil for anything that is not one — including
  /// hostnames, which is what makes the caller's default "block" rather than "allow".
  private static func ipv4Octets(_ host: String) -> [Int]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else {
        return nil
      }
      octets.append(value)
    }
    return octets
  }
}

// MARK: - Network guard

/// Fails any request to a host outside this Mac while Offline Mode is on.
///
/// A `URLProtocol` rather than a check at each call site: the app reaches the network from
/// transcription, TTS, five chat providers, the Google and Trello integrations and the
/// OpenRouter catalog, and a guard that has to be remembered at each of those is a guard
/// that will be missing from the next one. Installed on every session the app builds
/// (`LLMHTTPSession.shared`, `LLMHTTPSession.integrations`, the meeting-chunk session), so
/// the mode holds even where the UI-level filtering below is bypassed.
final class OfflineModeURLProtocol: URLProtocol {

  override class func canInit(with request: URLRequest) -> Bool {
    OfflineMode.shouldBlock(request.url, offlineMode: OfflineMode.isEnabled)
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let message = OfflineMode.blockedMessage(for: request.url)
    DebugLogger.logWarning("OFFLINE-MODE: blocked \(request.url?.host ?? "request")")
    // An NSURLError rather than a `TranscriptionError`: every call site already maps transport
    // errors into its own error type and surfaces `localizedDescription`, so the explanation
    // reaches the user through paths that never learn this type exists.
    let error = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCannotConnectToHost,
      userInfo: [NSLocalizedDescriptionKey: message])
    client?.urlProtocol(self, didFailWithError: error)
  }

  override func stopLoading() {}

  /// Puts the guard in front of the system protocols for a session being configured.
  static func install(on configuration: URLSessionConfiguration) {
    configuration.protocolClasses =
      [OfflineModeURLProtocol.self] + (configuration.protocolClasses ?? [])
  }
}

// MARK: - Context logging

/// Whether interactions (transcripts, prompts, replies, retained audio samples) may be written
/// to disk.
///
/// The stored flag was read as the same three-line ternary in five places; Offline Mode adds a
/// second condition to it, and five copies of a two-part rule is four too many. Offline Mode
/// wins over the stored flag: in a practice the transcript *is* the regulated content, and a
/// log of it at rest is the thing the mode exists to prevent.
enum ContextLoggingPreference {

  static var isEnabled: Bool {
    guard !OfflineMode.isEnabled else { return false }
    return storedFlag
  }

  /// The user's own preference, ignoring Offline Mode — for settings UI that has to show what
  /// the toggle is set to, not what the app is currently doing.
  static var storedFlag: Bool {
    // Absent key means "on": the setting predates this type and defaulted to on.
    UserDefaults.standard.object(forKey: UserDefaultsKeys.contextLoggingEnabled) == nil
      ? true
      : UserDefaults.standard.bool(forKey: UserDefaultsKeys.contextLoggingEnabled)
  }
}
