import Foundation

/// Handles formatting of speech errors for display in the UI
struct SpeechErrorFormatter {

  // MARK: - Constants
  private enum Constants {
    static let maxFileSize = "25MB"
    static let openAIPlatformURL = "platform.openai.com"
    static let billingPath = "Settings → Billing"
    static let slowDownWaitTime = "15 minutes"
  }

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

    case .incorrectAPIKey:
      return """
        ❌ Incorrect API Key

        The API key provided is not correct.
        Please ensure the API key is correct and that you have added your payment details and activated the API key.
        """

    case .countryNotSupported:
      return """
        ❌ Country Not Supported

        You are accessing the API from an unsupported country, region, or territory.
        Please see OpenAI's documentation for supported regions.
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
        1. Visit \(Constants.openAIPlatformURL)
        2. Go to \(Constants.billingPath)
        3. Add a payment method
        4. Purchase prepaid credits

        Note: OpenAI no longer provides free trial credits.
        You must add billing information to use the API.

        Please wait a moment and try again after setting up billing.
        """

    case .quotaExceeded:
      return """
        ⏳ Quota Exceeded

        You have exceeded your current quota. Please check your plan and billing details.

        To resolve:
        1. Visit \(Constants.openAIPlatformURL)
        2. Go to \(Constants.billingPath)
        3. Check your current usage and limits
        4. Add more credits or upgrade your plan

        Please try again after adding more credits.
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

    case .slowDown:
      return """
        🔄 Slow Down

        A sudden increase in your request rate is impacting service reliability.
        Please reduce your request rate to its original level, maintain a consistent rate for at least \(Constants.slowDownWaitTime), and then gradually increase it.
        """

    case .requestTimeout:
      return """
        ⏰ Request Timeout

        The server took too long to start responding (over 60 seconds).

        This usually means:
        • OpenAI servers are overloaded
        • Your internet connection is very slow
        • The API endpoint is temporarily unavailable

        Solutions:
        • Wait a moment and try again
        • Check your internet connection
        • Try with a shorter recording
        """
        
    case .resourceTimeout:
      return """
        ⏰ Resource Timeout

        The entire request took too long to complete (over 5 minutes).

        This usually means:
        • Very large audio file (close to 20MB limit)
        • Slow internet connection during upload/download
        • OpenAI processing is taking unusually long

        Solutions:
        • Try with a shorter recording
        • Check your internet connection speed
        • The app will automatically retry (up to 2 attempts)
        """
        
    case .networkError(let details):
      if details.lowercased().contains("timeout") {
        return """
          ⏰ Generic Timeout

          The request timed out for an unknown reason.

          Error: \(details)

          Please try again or use a shorter recording.
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

        The audio file is larger than \(Constants.maxFileSize) and cannot be transcribed.
        Please use a shorter recording.
        """

    case .emptyFile:
      return """
        ❌ Empty Audio File

        The recording contains no audio data.
        Please try again.
        """
    case .noSpeechDetected:
      return """
        🎤 No Speech Detected

        No speech was detected in your recording. Please make sure to:
        • Speak clearly into your microphone
        • Wait for the recording indicator before speaking
        • Speak your prompt or instruction before stopping the recording

        Try recording again with clear speech.
        """
    case .ttsError(let ttsError):
      return formatTTSError(ttsError)
    }
  }

  /// Get a short status message for menu bar display
  static func shortStatus(_ error: TranscriptionError) -> String {
    switch error {
    case .noAPIKey:
      return "⚠️ No API Key"
    case .invalidAPIKey:
      return "❌ Invalid Authentication"
    case .incorrectAPIKey:
      return "❌ Incorrect API Key"
    case .countryNotSupported:
      return "❌ Country Not Supported"
    case .rateLimited:
      return "⏳ Rate Limited"
    case .quotaExceeded:
      return "⏳ Quota Exceeded"
    case .networkError:
      return "⏰ Network Error"
    case .requestTimeout:
      return "⏰ Request Timeout"
    case .resourceTimeout:
      return "⏰ Resource Timeout"
    case .serverError:
      return "❌ Server Error"
    case .serviceUnavailable:
      return "🔄 Service Unavailable"
    case .slowDown:
      return "🔄 Slow Down"
    case .fileTooLarge:
      return "❌ File Too Large"
    case .emptyFile:
      return "❌ Empty File"
    case .noSpeechDetected:
      return "🎤 No Speech"
    case .ttsError:
      return "❌ TTS Error"
    default:
      return "❌ Error"
    }
  }

  // MARK: - TTS Error Formatting
  static func formatTTSError(_ ttsError: TTSError) -> String {
    switch ttsError {
    case .textTooLong(let characterCount, let maxLength):
      return """
        📏 Text Too Long for Speech

        The selected text is too long to be read aloud.
        
        Current length: \(characterCount) characters
        Maximum allowed: \(maxLength) characters
        
        Please select a shorter text or break it into smaller parts.
        """
    case .noAPIKey:
      return """
        ⚠️ No API Key for Speech

        Please configure your OpenAI API key in Settings to use text-to-speech.
        """
    case .invalidInput:
      return """
        ❌ Invalid Text for Speech

        The text cannot be converted to speech.
        Please try with different text.
        """
    case .authenticationError:
      return """
        ❌ Speech Authentication Error

        Your API key is invalid or has expired.
        Please check your OpenAI API key in Settings.
        """
    case .networkError(let message):
      return """
        🌐 Speech Network Error

        Error: \(message)
        
        Please check your internet connection and try again.
        """
    case .audioGenerationFailed:
      return """
        🔊 Speech Generation Failed

        Unable to generate audio from the text.
        Please try again or select different text.
        """
    }
  }
}
