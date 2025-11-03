//
//  OpenAIModels.swift
//  WhisperShortcut
//
//  Data models for OpenAI API interactions
//

import Foundation

// MARK: - Transcription Model Enum
enum TranscriptionModel: String, CaseIterable {
  case gpt4oTranscribe = "gpt-4o-transcribe"
  case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

  var displayName: String {
    switch self {
    case .gpt4oTranscribe:
      return "GPT-4o Transcribe"
    case .gpt4oMiniTranscribe:
      return "GPT-4o Mini Transcribe"
    }
  }

  var apiEndpoint: String {
    return "https://api.openai.com/v1/audio/transcriptions"
  }

  var isRecommended: Bool {
    switch self {
    case .gpt4oMiniTranscribe:
      return true
    case .gpt4oTranscribe:
      return false
    }
  }

  var costLevel: String {
    switch self {
    case .gpt4oMiniTranscribe:
      return "Low"
    case .gpt4oTranscribe:
      return "High"
    }
  }

  var description: String {
    switch self {
    case .gpt4oTranscribe:
      return "Highest accuracy and quality • Best for critical applications"
    case .gpt4oMiniTranscribe:
      return "Recommended • Great quality at lower cost • Best for everyday use"
    }
  }
}

// MARK: - Transcription Response
struct WhisperResponse: Codable {
  let text: String
}

// MARK: - GPT-Audio Chat Completion Request
struct GPTAudioChatRequest: Codable {
  let model: String
  let messages: [GPTAudioMessage]
  let modalities: [String]?
  let audio: AudioConfig?
  
  struct AudioConfig: Codable {
    let voice: String
    let format: String
  }
  
  struct GPTAudioMessage: Codable {
    let role: String
    let content: MessageContent
    
    enum MessageContent: Codable {
      case text(String)
      case multiContent([ContentPart])
      
      func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
          try container.encode(string)
        case .multiContent(let parts):
          try container.encode(parts)
        }
      }
      
      init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
          self = .text(string)
        } else if let parts = try? container.decode([ContentPart].self) {
          self = .multiContent(parts)
        } else {
          throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid message content"
          )
        }
      }
    }
    
    struct ContentPart: Codable {
      let type: String
      let text: String?
      let input_audio: InputAudio?
      
      struct InputAudio: Codable {
        let data: String
        let format: String
      }
    }
  }
}

// MARK: - GPT-Audio Chat Completion Response
struct GPTAudioChatResponse: Codable {
  let choices: [GPTAudioChoice]
  
  struct GPTAudioChoice: Codable {
    let message: GPTAudioResponseMessage
    
    struct GPTAudioResponseMessage: Codable {
      let content: ResponseContent?
      let audio: AudioOutput?
    }
    
    enum ResponseContent: Codable {
      case text(String)
      case multiContent([ResponseContentPart])
      
      func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
          try container.encode(string)
        case .multiContent(let parts):
          try container.encode(parts)
        }
      }
      
      init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
          self = .text(string)
        } else if let parts = try? container.decode([ResponseContentPart].self) {
          self = .multiContent(parts)
        } else {
          throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid response content"
          )
        }
      }
    }
    
    struct ResponseContentPart: Codable {
      let type: String
      let text: String?
      let audio: AudioContentPart?
    }
    
    struct AudioContentPart: Codable {
      let data: String
      let transcript: String?
    }
    
    struct AudioOutput: Codable {
      let id: String
      let data: String
      let transcript: String?
      let expires_at: Int?
    }
  }
}

// MARK: - Chat Completions API Models
struct ChatCompletionResponse: Codable {
  let id: String?
  let choices: [ChatChoice]
  let usage: Usage?
}

struct ChatChoice: Codable {
  let message: ChatMessage
  let finish_reason: String?
}

struct ChatMessage: Codable {
  let role: String
  let content: String
}

struct Usage: Codable {
  let prompt_tokens: Int?
  let completion_tokens: Int?
  let total_tokens: Int?
}

// MARK: - Error Response Models
struct OpenAIErrorResponse: Codable {
  let error: OpenAIError?
}

struct OpenAIError: Codable {
  let message: String?
  let type: String?
  let code: String?
}

// MARK: - Transcription Error
enum TranscriptionError: Error, Equatable {
  case noAPIKey
  case invalidAPIKey
  case incorrectAPIKey
  case countryNotSupported
  case invalidRequest
  case permissionDenied
  case notFound
  case rateLimited
  case quotaExceeded
  case serverError(Int)
  case serviceUnavailable
  case slowDown
  case networkError(String)
  case requestTimeout
  case resourceTimeout
  case fileError(String)
  case fileTooLarge
  case emptyFile
  case noSpeechDetected
  case textTooShort
  case promptLeakDetected
  case ttsError(TTSError)

  var title: String {
    switch self {
    case .noAPIKey: return "No API Key"
    case .invalidAPIKey: return "Invalid Authentication"
    case .incorrectAPIKey: return "Incorrect API Key"
    case .countryNotSupported: return "Country Not Supported"
    case .invalidRequest: return "Invalid Request"
    case .permissionDenied: return "Permission Denied"
    case .notFound: return "Not Found"
    case .rateLimited: return "Rate Limited"
    case .quotaExceeded: return "Quota Exceeded"
    case .serverError: return "Server Error"
    case .serviceUnavailable: return "Service Unavailable"
    case .slowDown: return "Slow Down"
    case .networkError: return "Network Error"
    case .requestTimeout: return "Request Timeout"
    case .resourceTimeout: return "Resource Timeout"
    case .fileError: return "File Error"
    case .fileTooLarge: return "File Too Large"
    case .emptyFile: return "Empty File"
    case .noSpeechDetected: return "No Speech Detected"
    case .textTooShort: return "Text Too Short"
    case .promptLeakDetected: return "API Response Issue"
    case .ttsError: return "Text-to-Speech Error"
    }
  }
}
