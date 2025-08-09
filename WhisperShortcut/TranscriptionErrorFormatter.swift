import Foundation

/// Handles formatting of transcription errors for display in the UI
struct TranscriptionErrorFormatter {

  /// Format a TranscriptionError into a user-friendly message
  static func format(_ error: TranscriptionError) -> String {
    switch error {
    case .noAPIKey:
      return """
        ⚠️ No API Key Configured

        Please open Settings and add your OpenAI API key.
        Without a valid API key, transcription cannot be performed.
        """

    case .invalidAPIKey:
      return """
        ❌ Authentication Error

        Your API key is invalid or has expired.
        Please check your OpenAI API key in Settings.
        """

    case .invalidRequest:
      return """
        ❌ Invalid Request

        The request was malformed or contained invalid parameters.
        Please check your audio file format and try again.
        """

    case .permissionDenied:
      return """
        ❌ Permission Denied

        You don't have permission to access this resource.
        Please check your API key permissions.
        """

    case .notFound:
      return """
        ❌ Resource Not Found

        The requested resource was not found.
        Please try again.
        """

    case .rateLimited:
      return """
        ⏳ Rate Limit Exceeded

        You have exceeded the rate limit for this API.

        Common causes for new users:
        • No billing method configured - OpenAI requires payment setup
        • Account has no credits or usage quota reached
        • Too many requests in a short time period

        To resolve:
        1. Visit platform.openai.com
        2. Go to Settings → Billing
        3. Add a payment method
        4. Purchase prepaid credits

        Note: OpenAI no longer provides free trial credits.
        You must add billing information to use the API.

        Please wait a moment and try again after setting up billing.
        """

    case .serverError(let code):
      return """
        ❌ Server Error (\(code))

        An error occurred on OpenAI's servers.
        Please try again later.
        """

    case .serviceUnavailable:
      return """
        🔄 Service Unavailable

        OpenAI's service is temporarily unavailable.
        Please try again in a few moments.
        """

    case .networkError(let details):
      if details.lowercased().contains("timeout") {
        return """
          ⏰ Request Timeout

          The request took too long and was cancelled.

          Possible causes:
          • Slow internet connection
          • Large audio file
          • OpenAI servers overloaded

          Tips:
          • Try again
          • Use shorter recordings
          • Check your internet connection
          """
      } else {
        return """
          ❌ Network Error

          Error: \(details)

          Please check your internet connection and try again.
          """
      }

    case .fileError(let details):
      return """
        ❌ File Error

        Error: \(details)

        Please try again with a different audio file.
        """

    case .fileTooLarge:
      return """
        ❌ File Too Large

        The audio file is larger than 25MB and cannot be transcribed.
        Please use a shorter recording.
        """

    case .emptyFile:
      return """
        ❌ Empty Audio File

        The recording contains no audio data.
        Please try again.
        """
    }
  }

  /// Get a short status message for menu bar display
  static func shortStatus(_ error: TranscriptionError) -> String {
    switch error {
    case .noAPIKey:
      return "⚠️ No API Key"
    case .invalidAPIKey:
      return "❌ Invalid Key"
    case .rateLimited:
      return "⏳ Rate Limited"
    case .networkError:
      return "⏰ Network Error"
    case .serverError:
      return "❌ Server Error"
    case .serviceUnavailable:
      return "🔄 Service Down"
    case .fileTooLarge:
      return "❌ File Too Large"
    case .emptyFile:
      return "❌ Empty File"
    default:
      return "❌ Error"
    }
  }
}
