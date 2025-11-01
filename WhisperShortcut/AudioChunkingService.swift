//
//  AudioChunkingService.swift
//  WhisperShortcut
//
//  Service for intelligent audio file splitting and analysis
//

import AVFoundation
import Foundation

// MARK: - Audio Chunking Service
class AudioChunkingService {
  
  // MARK: - Constants
  private enum Constants {
    static let maxChunkDuration: TimeInterval = 120.0  // 2 minutes per chunk
    static let maxChunkSize = 20 * 1024 * 1024  // 20MB per chunk - optimal  
    static let chunkOverlapDuration: TimeInterval = 3.0  // 3 seconds overlap
    static let minimumSilenceDuration: TimeInterval = 0.8  // 0.8 seconds minimum silence
    static let silenceThreshold: Float = -40.0  // dB threshold for silence detection
  }
  
  // MARK: - Audio Analysis
  func getAudioDuration(_ audioURL: URL) -> TimeInterval {
    let asset = AVURLAsset(url: audioURL)
    // Use synchronous access to duration for backward compatibility
    // The async version would require changing all callers to async
    let duration = asset.duration
    return CMTimeGetSeconds(duration)
  }
  
  func getAudioSize(_ audioURL: URL) -> Int64 {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
      return attributes[.size] as? Int64 ?? 0
    } catch {
      return 0
    }
  }
  
  // MARK: - Intelligent Splitting
  func splitAudioIntelligently(_ audioURL: URL, maxDuration: TimeInterval, maxSize: Int64) -> [URL] {
    let audioDuration = getAudioDuration(audioURL)
    let audioSize = getAudioSize(audioURL)
    
    // Check if chunking is needed
    if audioDuration <= maxDuration && audioSize <= maxSize {
      return [audioURL]
    }
    
    // 1. Try silence-based splitting first
    let silenceBreaks = detectSilencePauses(audioURL)
    if !silenceBreaks.isEmpty {
      return splitAudioAtSilence(audioURL, breaks: silenceBreaks, maxDuration: maxDuration)
    }
    
    // 2. Fallback: Time-based splitting
    if audioDuration > maxDuration {
      return splitAudioByTime(audioURL, maxDuration: maxDuration)
    }
    
    // 3. Fallback: Size-based splitting
    if audioSize > maxSize {
      return splitAudioBySize(audioURL, maxSize: maxSize)
    }
    
    // Should not reach here, but return original as fallback
    return [audioURL]
  }
  
  // MARK: - Silence Detection
  private func detectSilencePauses(_ audioURL: URL) -> [TimeInterval] {
    guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
      return []
    }
    
    let format = audioFile.processingFormat
    let frameCount = AVAudioFrameCount(audioFile.length)
    
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      return []
    }
    
    do {
      try audioFile.read(into: buffer)
    } catch {
      return []
    }
    
    guard let floatChannelData = buffer.floatChannelData else {
      return []
    }
    
    let channelData = floatChannelData[0]
    let frameLength = Int(buffer.frameLength)
    let sampleRate = format.sampleRate
    
    var silenceBreaks: [TimeInterval] = []
    var silenceStart: TimeInterval? = nil
    
    // Analyze audio in 0.1 second windows
    let windowSize = Int(sampleRate * 0.1)
    
    for i in stride(from: 0, to: frameLength, by: windowSize) {
      let endIndex = min(i + windowSize, frameLength)
      var rms: Float = 0.0
      
      // Calculate RMS for this window
      for j in i..<endIndex {
        let sample = channelData[j]
        rms += sample * sample
      }
      rms = sqrt(rms / Float(endIndex - i))
      
      // Convert to dB
      let dB = 20 * log10(rms + 1e-10)  // Add small value to avoid log(0)
      let currentTime = TimeInterval(i) / sampleRate
      
      if dB < Constants.silenceThreshold {
        // Silence detected
        if silenceStart == nil {
          silenceStart = currentTime
        }
      } else {
        // Sound detected
        if let start = silenceStart {
          let silenceDuration = currentTime - start
          if silenceDuration >= Constants.minimumSilenceDuration {
            // Found meaningful silence - use middle point as break
            silenceBreaks.append(start + silenceDuration / 2)
          }
          silenceStart = nil
        }
      }
    }
    
    return silenceBreaks
  }
  
  // MARK: - Splitting Methods
  private func splitAudioAtSilence(_ audioURL: URL, breaks: [TimeInterval], maxDuration: TimeInterval) -> [URL] {
    var chunkURLs: [URL] = []
    let audioDuration = getAudioDuration(audioURL)
    
    var startTime: TimeInterval = 0
    
    for breakTime in breaks {
      // Only create chunk if it's long enough and not too long
      let chunkDuration = breakTime - startTime
      if chunkDuration >= 10.0 && chunkDuration <= maxDuration {
        if let chunkURL = extractAudioSegment(audioURL, start: startTime, duration: chunkDuration) {
          chunkURLs.append(chunkURL)
          startTime = max(0, breakTime - Constants.chunkOverlapDuration)  // Add overlap
        }
      } else if chunkDuration > maxDuration {
        // Chunk too long, split by time
        let timeChunks = splitAudioByTimeRange(audioURL, start: startTime, end: breakTime, maxDuration: maxDuration)
        chunkURLs.append(contentsOf: timeChunks)
        startTime = max(0, breakTime - Constants.chunkOverlapDuration)
      }
    }
    
    // Handle remaining audio
    if startTime < audioDuration - 5.0 {  // At least 5 seconds remaining
      let remainingDuration = audioDuration - startTime
      if let finalChunk = extractAudioSegment(audioURL, start: startTime, duration: remainingDuration) {
        chunkURLs.append(finalChunk)
      }
    }
    
    return chunkURLs
  }
  
  private func splitAudioByTime(_ audioURL: URL, maxDuration: TimeInterval) -> [URL] {
    let audioDuration = getAudioDuration(audioURL)
    var chunkURLs: [URL] = []
    var startTime: TimeInterval = 0
    
    while startTime < audioDuration {
      let remainingDuration = audioDuration - startTime
      let chunkDuration = min(maxDuration, remainingDuration)
      
      if let chunkURL = extractAudioSegment(audioURL, start: startTime, duration: chunkDuration) {
        chunkURLs.append(chunkURL)
      }
      
      startTime += chunkDuration - Constants.chunkOverlapDuration  // Add overlap
      if startTime >= audioDuration - Constants.chunkOverlapDuration {
        break
      }
    }
    
    return chunkURLs
  }
  
  private func splitAudioByTimeRange(_ audioURL: URL, start: TimeInterval, end: TimeInterval, maxDuration: TimeInterval) -> [URL] {
    var chunkURLs: [URL] = []
    var currentStart = start
    
    while currentStart < end {
      let remainingDuration = end - currentStart
      let chunkDuration = min(maxDuration, remainingDuration)
      
      if let chunkURL = extractAudioSegment(audioURL, start: currentStart, duration: chunkDuration) {
        chunkURLs.append(chunkURL)
      }
      
      currentStart += chunkDuration - Constants.chunkOverlapDuration
      if currentStart >= end - Constants.chunkOverlapDuration {
        break
      }
    }
    
    return chunkURLs
  }
  
  private func splitAudioBySize(_ audioURL: URL, maxSize: Int64) -> [URL] {
    // For size-based splitting, we estimate based on duration
    // This is a simplified approach - in practice, audio compression varies
    let audioDuration = getAudioDuration(audioURL)
    let audioSize = getAudioSize(audioURL)
    let bytesPerSecond = Double(audioSize) / audioDuration
    let maxDurationForSize = Double(maxSize) / bytesPerSecond
    
    let effectiveMaxDuration = min(maxDurationForSize, Constants.maxChunkDuration)
    
    var chunkURLs: [URL] = []
    var startTime: TimeInterval = 0
    
    while startTime < audioDuration {
      let remainingDuration = audioDuration - startTime
      let chunkDuration = min(effectiveMaxDuration, remainingDuration)
      
      if let chunkURL = extractAudioSegment(audioURL, start: startTime, duration: chunkDuration) {
        chunkURLs.append(chunkURL)
      }
      
      startTime += chunkDuration - Constants.chunkOverlapDuration
      if startTime >= audioDuration - Constants.chunkOverlapDuration {
        break
      }
    }
    
    return chunkURLs
  }
  
  // MARK: - Audio Segment Extraction
  private func extractAudioSegment(_ audioURL: URL, start: TimeInterval, duration: TimeInterval) -> URL? {
    let tempDir = FileManager.default.temporaryDirectory
    let segmentURL = tempDir.appendingPathComponent("audio_chunk_\(UUID().uuidString).m4a")
    
    let asset = AVURLAsset(url: audioURL)
    
    // Use M4A preset for better compatibility with Whisper API
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      return nil
    }
    
    exportSession.outputURL = segmentURL
    exportSession.outputFileType = .m4a
    
    let startTime = CMTime(seconds: start, preferredTimescale: 1000)
    let endTime = CMTime(seconds: start + duration, preferredTimescale: 1000)
    exportSession.timeRange = CMTimeRange(start: startTime, end: endTime)
    
    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    
    Task {
      await exportSession.export()
      success = exportSession.status == .completed
      semaphore.signal()
    }
    
    semaphore.wait()
    
    return success ? segmentURL : nil
  }
}

