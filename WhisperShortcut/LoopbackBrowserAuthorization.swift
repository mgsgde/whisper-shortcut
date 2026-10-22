import AuthenticationServices
import Foundation

/// Loopback sign-in in the system browser. OpenRouter and ChatGPT had each grown the same ~50
/// lines: bind `127.0.0.1`, open `ASWebAuthenticationSession` with `callbackURLScheme: nil` (the
/// session cannot see a loopback redirect), and resume from the listener. The sheet's cancel and
/// the redirect race; whichever lands first wins. `nil` means the user closed the sheet. Each
/// service maps `Failure` onto its own error type.
///
/// The two copies did not differ in timeout, thread, or how cancellation maps. They differ in
/// callback path, the page's provider name, and the authorize URL built from the bound redirect
/// (the port is inside that URI). `logPrefix` tags the failure lines.
@MainActor
enum LoopbackBrowserAuthorization {
  enum Failure: Error {
    case invalidAuthorizeURL
    case startFailed
    case noCallback
  }

  static func run(
    callbackPath: String = LoopbackOAuthListener.defaultCallbackPath,
    providerName: String = LoopbackOAuthListener.defaultProviderName,
    logPrefix: String,
    authorizeURL: (_ redirectURI: String) -> URL?
  ) async throws -> URLComponents? {
    let attempt = Attempt(logPrefix: logPrefix)
    // The builder runs before the wait, so callers can record the bound redirect URI (the token
    // request has to repeat it) without the closure outliving this call.
    let listener = try LoopbackOAuthListener(
      callbackPath: callbackPath, providerName: providerName
    ) { [weak attempt] components in
      // The listener already hops to the main queue; this hop matches the services, which
      // finished the flow on the main actor.
      Task { @MainActor in
        attempt?.finish(.success(components ?? URLComponents()))
      }
    }
    attempt.listener = listener
    guard let url = authorizeURL(listener.callbackURL) else {
      DebugLogger.logError("\(logPrefix): Could not build the authorization URL")
      listener.stop()
      attempt.listener = nil
      throw Failure.invalidAuthorizeURL
    }
    return try await withCheckedThrowingContinuation { continuation in
      attempt.begin(url: url, continuation: continuation)
    }
  }

  /// Retained by `run` for the wait. The listener callback holds it weakly so a sheet that never
  /// finishes does not keep the port open after `run` has returned.
  @MainActor
  private final class Attempt {
    private var continuation: CheckedContinuation<URLComponents?, Error>?
    /// A redirect that arrives before `begin` stores the continuation (the listener is already up).
    private var pending: Result<URLComponents?, Error>?
    private var session: ASWebAuthenticationSession?
    var listener: LoopbackOAuthListener?
    private let logPrefix: String
    private var finished = false

    init(logPrefix: String) { self.logPrefix = logPrefix }

    func begin(url: URL, continuation: CheckedContinuation<URLComponents?, Error>) {
      if let pending {
        self.pending = nil
        self.continuation = continuation
        finish(pending)
        return
      }
      self.continuation = continuation
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
        Task { @MainActor in
          guard let self else { return }
          if let error {
            if let canceled = error as? ASWebAuthenticationSessionError, canceled.code == .canceledLogin {
              self.finish(.success(nil))
              return
            }
            self.finish(.failure(error))
            return
          }
          self.finish(.failure(Failure.noCallback))
        }
      }
      // Reuse the browser's existing login. An ephemeral session would force a fresh one every time.
      session.prefersEphemeralWebBrowserSession = false
      session.presentationContextProvider = OAuthPresentationAnchorProvider.shared
      self.session = session
      if !session.start() {
        DebugLogger.logError("\(logPrefix): Authorization window failed to open")
        finish(.failure(Failure.startFailed))
      }
    }

    /// Idempotent. Clears the continuation before cancelling the sheet, so a cancel callback
    /// caused by our own `cancel()` cannot resume it a second time.
    func finish(_ result: Result<URLComponents?, Error>) {
      guard !finished else { return }
      guard let continuation else {
        pending = result
        return
      }
      finished = true
      self.continuation = nil
      let session = self.session
      self.session = nil
      listener?.stop()
      listener = nil
      session?.cancel()
      switch result {
      case .success(let value): continuation.resume(returning: value)
      case .failure(let error): continuation.resume(throwing: error)
      }
    }
  }
}
