import Foundation

/// Handles formatting of speech errors for display in the UI
struct SpeechErrorFormatter {

  // MARK: - Constants
  private enum Constants {
    static let slowDownWaitTime = "15 minutes"
  }

  /// Format a TranscriptionError into a user-friendly message
  static func format(_ error: TranscriptionError) -> String {
    switch error {
    case .noGoogleAPIKey:
      return """
        ⚠️ No Google API Key Configured

        You have selected a Gemini model, but no Google API key is configured.
        Please open Settings and add your Google API key in the "Google API Key" section.
        Without a valid Google API key, Gemini transcription cannot be performed.
        """

    case .invalidAPIKey:
      return """
        ❌ Authentication Error

        Your API key is invalid or has expired.
        Please check your Google API key in Settings.
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
        Please see Google's documentation for supported regions.
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

    case .modelDeprecated:
      return """
        ❌ Model No Longer Available

        The requested resource was not found. This can happen if the selected model is deprecated and no longer available for your account (e.g. Gemini 2.0 Flash).

        Choose a newer model in Settings → Speech-to-Text (e.g. Gemini 2.5 Flash).
        """

    case .rateLimited(let retryAfter):
      let waitMessage = retryAfter.map { "Please wait \(Int($0)) seconds and try again." } ?? "Please wait a moment and try again after setting up billing."
      return """
        ⏳ Rate Limit Exceeded

        You have exceeded the rate limit for this API.

        Common causes for new users:
        • No billing method configured - Google requires payment setup
        • Account has no credits or usage quota reached
        • Too many requests in a short time period

        To resolve:
        1. Visit Google Cloud Console
        2. Go to Billing settings
        3. Add a payment method
        4. Enable the Gemini API

        \(waitMessage)
        """

    case .quotaExceeded(let retryAfter):
      let waitMessage = retryAfter.map { "Please wait \(Int($0)) seconds and try again." } ?? "Please try again after adding more credits."
      return """
        ⏳ Quota Exceeded

        You have exceeded your current quota. Please check your plan and billing details.

        Check your current usage and quotas:
        https://console.cloud.google.com/apis/api/generativelanguage.googleapis.com/quotas

        To resolve:
        1. Visit the link above to see your quota and usage
        2. Go to Billing settings in Google Cloud Console
        3. Add more credits or upgrade your plan

        \(waitMessage)
        """

    case .serverError(let code):
      return """
        ❌ Server Error (\(code))

        An error occurred on Google's servers.
        Please try again later.
        """

    case .serviceUnavailable:
      return """
        🔄 Service Unavailable

        Google's service is temporarily unavailable.
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
        • Google servers are overloaded
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
        • Google processing is taking unusually long

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
      // Check if this is actually a model-related error
      let lowercasedDetails = details.lowercased()
      if lowercasedDetails.contains("model") && (lowercasedDetails.contains("not found") || lowercasedDetails.contains("download") || lowercasedDetails.contains("missing")) {
        // This is likely a model availability issue that wasn't caught properly
        return """
          📥 Model Not Downloaded

          The offline model could not be loaded.

          \(details)

          To download the model:
          1. Open Settings (click the menu bar icon and select "Settings")
          2. Go to the "Offline Models" tab
          3. Click "Download" next to your selected model
          4. Wait for the download to complete
          5. Try transcribing again

          Note: If the model was already downloaded, it may be incomplete or corrupted. Try deleting and re-downloading it.
          """
      }
      
      return """
        ❌ File Error

        Error: \(details)

        Please try again with a different audio file.
        """

    case .fileTooLarge:
      return """
        ❌ File Too Large

        The audio file is larger than \(AppConstants.maxFileSizeDisplay) and cannot be transcribed.
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
    case .textTooShort:
      return """
        🎤 Very Short Text Detected

        Only very little text was recognized. This could mean:
        • You spoke too quietly or monotonously
        • The microphone didn't pick up clear audio
        • You spoke very briefly

        Try recording again and speak louder and more clearly.
        """
    case .promptLeakDetected:
      return """
        ⚠️ API Response Issue

        The transcription service returned an unexpected response.
        This is typically a temporary API issue.

        Please record again. If the problem persists, the audio might be unclear.
        """
    case .modelNotAvailable(let modelType):
      let sizeText: String
      if let size = ModelManager.shared.getModelSize(modelType) {
        sizeText = ModelManager.shared.formatSize(size)
      } else {
        sizeText = "~\(modelType.estimatedSizeMB) MB"
      }
      
      return """
        📥 Model Not Downloaded

        The offline model "\(modelType.displayName)" is not yet downloaded.

        Estimated size: \(sizeText)

        To download the model:
        1. Open Settings (click the menu bar icon and select "Settings")
        2. Go to the "Offline Models" tab
        3. Click "Download" next to \(modelType.displayName)
        4. Wait for the download to complete (this may take several minutes)
        5. Try transcribing again

        Note: Models are downloaded from HuggingFace and stored locally on your Mac. Once downloaded, they work completely offline.
        """
    }
  }

  /// Get a short status message for menu bar display
  static func shortStatus(_ error: TranscriptionError) -> String {
    switch error {
    case .noGoogleAPIKey:
      return "⚠️ No Google API Key"
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
    case .textTooShort:
      return "🎤 Text Too Short"
    case .promptLeakDetected:
      return "⚠️ API Issue"
    case .modelNotAvailable:
      return "📥 Model Not Downloaded"
    case .modelDeprecated:
      return "❌ Model no longer available"
    default:
      return "❌ Error"
    }
  }

}
