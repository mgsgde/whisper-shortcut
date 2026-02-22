//
//  ChunkError.swift
//  WhisperShortcut
//
//  Shared wrapper to track which chunk failed in chunked processing (transcription or TTS).
//

import Foundation

/// Wrapper error to track which chunk failed.
struct ChunkError: Error {
  let index: Int
  let error: Error
}
