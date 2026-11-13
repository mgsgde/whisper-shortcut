//
//  TestProfileLiveDictation.swift
//  WhisperShortcut
//
//  Test profile only (`--live-audio-file`): run Dictate Live from a WAV into a text view in this
//  process. No microphone, no pasteboard, no CGEvent, no Accessibility. The direct build only —
//  Dictate Live does not exist in the App Store build.
//

#if !APP_STORE

import AVFoundation
import Cocoa
import Foundation

enum TestProfileLiveDictation {

  private static var windowHost: WindowHost?

  /// Schedules the run about a second after launch, once the status item exists. No-op unless
  /// this process is a test profile launched with an absolute `--live-audio-file`.
  @MainActor
  static func startIfRequested() {
    guard TestProfileOverrides.current.liveAudioFile != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      Task { @MainActor in
        await run()
      }
    }
  }

  @MainActor
  private static func run() async {
    guard let path = TestProfileOverrides.current.liveAudioFile else { return }
    let textView = openWindow()
    let source = URL(fileURLWithPath: path)
    // `--fresh` wipes the container, so the catalogue copies the WAV in after launch.
    guard await waitForStableFile(source) else { return }
    do {
      prepareFreshProfileForOfflineGerman()
      let sampleRate = try fileSampleRate(source)
      let (_, samples) = try AudioFileMonoLoader.loadMonoSamples(from: source, targetRate: sampleRate)
      let rate = Double(sampleRate)
      let pieces = LiveFileChunker.chunks(samples: samples, sampleRate: rate, policy: .live)
      DebugLogger.log("LIVE-FILE: started chunks=\(pieces.count) samples=\(samples.count) rate=\(sampleRate)")

      var urls: [(url: URL, isSilent: Bool, seconds: Double)] = []
      for (index, piece) in pieces.enumerated() {
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("live-chunk-\(index)-\(UUID().uuidString).wav")
        try writeWAV(samples: samples[piece.range], sampleRate: rate, to: url)
        urls.append((url, piece.isSilent, Double(piece.range.count) / rate))
      }

      let whole = FileManager.default.temporaryDirectory
        .appendingPathComponent("live-whole-\(UUID().uuidString).wav")
      try FileManager.default.copyItem(at: source, to: whole)

      let punctuationMode = PunctuationMode.effective(
        stored: .current, isOffline: true, duringMeeting: false)
      let speechService = SpeechService()
      let session = LiveDictationSession(
        decode: { url in
          // `transcribe` deletes the file it is given. The chunk on disk stays for the tail.
          let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-decode-\(UUID().uuidString).wav")
          try FileManager.default.copyItem(at: url, to: copy)
          // Second copy: Parakeet's own text, before spoken-mark layout. Also consumed.
          let copy2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-raw-\(UUID().uuidString).wav")
          try FileManager.default.copyItem(at: url, to: copy2)
          let raw: String
          do {
            raw = try await speechService.transcribe(
              audioURL: copy2, cancellable: false, reportsProgress: false,
              punctuationMode: punctuationMode)
          } catch TranscriptionError.noSpeechDetected {
            raw = ""
          }
          DebugLogger.log("LIVE-FILE: raw piece=\(url.lastPathComponent) «\(raw)»")
          return try await MenuBarController.decodeLivePiece(
            copy, speechService: speechService, punctuationMode: punctuationMode)
        },
        insert: { text in
          textView.insertText(text, replacementRange: textView.selectedRange())
          DebugLogger.log("LIVE-FILE: inserted \(text)")
          return true
        },
        holdsPeriods: punctuationMode != .spokenOnly,
        caret: .unknown)

      for piece in urls {
        if piece.seconds > 0 {
          try await Task.sleep(nanoseconds: UInt64(piece.seconds * 1_000_000_000))
        }
        session.add(piece.url, isSilent: piece.isSilent)
      }
      let outcome = try await session.finish(deliveredAudio: whole)
      let resultURL = FileManager.default.temporaryDirectory.appendingPathComponent("live-result.txt")
      try outcome.text.write(to: resultURL, atomically: true, encoding: .utf8)
      DebugLogger.log(
        "LIVE-FILE: pieces=\(outcome.pieces) failed=\(outcome.failedPieces) text=\(outcome.text)")
      DebugLogger.log("LIVE-FILE: done")
    } catch {
      DebugLogger.log("LIVE-FILE: failed \(error.logDescription)")
    }
  }

  /// Exists, non-empty, and the same size across two checks half a second apart. At most 30 s.
  /// `Task.sleep` suspends, so the main actor stays free while the catalogue finishes the copy.
  private static func waitForStableFile(_ url: URL) async -> Bool {
    DebugLogger.log("LIVE-FILE: waiting for \(url.lastPathComponent)")
    var previous = byteSize(url)
    for _ in 0..<60 {
      do {
        try await Task.sleep(nanoseconds: 500_000_000)
      } catch {
        return false
      }
      let size = byteSize(url)
      if size > 0, size == previous {
        return true
      }
      previous = size
    }
    DebugLogger.log("LIVE-FILE: failed no audio file")
    return false
  }

  private static func byteSize(_ url: URL) -> Int64 {
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attrs[.size] as? NSNumber
    else { return 0 }
    return size.int64Value
  }

  /// A fresh profile stores the cloud default and has an empty keychain, so the offline path
  /// would never run. This harness is the German spoken-mark fixture ("Komma", "Punkt"): Parakeet,
  /// German, "Only when spoken". The session below reads those the same way `startLiveDictation`
  /// reads the stored punctuation mode.
  @MainActor
  private static func prepareFreshProfileForOfflineGerman() {
    let defaults = UserDefaults.standard
    defaults.set(TranscriptionModel.parakeetUltra.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel)
    defaults.set(WhisperLanguage.de.rawValue, forKey: UserDefaultsKeys.whisperLanguage)
    defaults.set(PunctuationMode.spokenOnly.rawValue, forKey: UserDefaultsKeys.punctuationMode)
  }

  @MainActor
  private static func openWindow() -> NSTextView {
    let host = WindowHost()
    windowHost = host
    host.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    host.window.makeFirstResponder(host.textView)
    return host.textView
  }

  private static func fileSampleRate(_ url: URL) throws -> Int {
    let file = try AVAudioFile(forReading: url)
    return Int(file.processingFormat.sampleRate.rounded())
  }

  /// 16-bit mono PCM. `AVAudioFile` converts the float samples on write.
  private static func writeWAV(samples: ArraySlice<Float>, sampleRate: Double, to url: URL) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else {
      throw AudioFileMonoLoaderError.cannotCreateBuffer
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    if let channel = buffer.floatChannelData {
      var index = 0
      for sample in samples {
        channel[0][index] = sample
        index += 1
      }
    }
    try file.write(from: buffer)
    file.close()
  }

  /// Keeps the window alive for the process. A local window would close when `run` returns.
  private final class WindowHost: NSObject {
    let window: NSWindow
    let textView: NSTextView

    override init() {
      let scroll = NSTextView.scrollableTextView()
      let textView = scroll.documentView as? NSTextView ?? NSTextView()
      textView.isEditable = true
      textView.isSelectable = true
      textView.isRichText = false
      textView.font = NSFont.systemFont(ofSize: 16)
      textView.textContainerInset = NSSize(width: 8, height: 8)
      self.textView = textView

      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
      window.title = String(localized: "Live dictation test")
      window.contentView = scroll
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
      super.init()
    }
  }
}

#endif
