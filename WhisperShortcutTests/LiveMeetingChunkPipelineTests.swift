import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// A chunk transcription can outlive the meeting it belongs to, and chunks finish out of speaking
/// order. These tests drive that pipeline without a microphone.
@MainActor
@Suite("Live meeting chunk pipeline", .serialized)
struct LiveMeetingChunkPipelineTests {

  @Test("A chunk that finishes after the next meeting starts stays in its own file")
  func lateChunkAfterFinishStaysInItsOwnFile() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let fileA = dir.appendingPathComponent("Meeting-b02-a-\(UUID().uuidString).txt")
      let fileB = dir.appendingPathComponent("Meeting-b02-b-\(UUID().uuidString).txt")
      FileManager.default.createFile(atPath: fileA.path, contents: Data())
      FileManager.default.createFile(atPath: fileB.path, contents: Data())

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: fileA)
      deliver(session, index: 0, start: 15)
      #expect(await waitUntil { transcripts.waiterCount == 1 })

      session.stop()
      session.stopSafetyNetForTesting?.perform()
      #expect(box.finished == 1)
      #expect(await waitUntil { box.postProcessed.count == 1 })

      let seed = [
        LiveMeetingChunk(startTime: 0, text: "opening"),
        LiveMeetingChunk(startTime: 40, text: "closing"),
      ]
      try MeetingAudioBacklog.transcriptText(seed).write(to: fileA, atomically: true, encoding: .utf8)
      session.beginSessionWithoutRecorder(transcriptFile: fileB)
      // The new meeting has a chunk of its own in flight; a stray decrement from meeting A's
      // chunk would drop its count to zero.
      deliver(session, index: 1, start: 3)
      #expect(await waitUntil { transcripts.waiterCount == 2 })
      transcripts.resume(at: 0, returning: "middle")

      let landed = await waitForChunkTexts(at: fileA, ["opening", "middle", "closing"])
      #expect(landed)
      #expect(!text(at: fileB).contains("middle"))
      #expect(!store.chunks.contains { $0.text == "middle" })
      // The text arrived after the summary was built without it, so the summary is redone.
      #expect(await waitUntil { box.postProcessedURLs == [fileA, fileA] })
      // A decrement for the old meeting would be visible within a few turns of the write.
      let miscounted = await waitUntil(timeout: 0.3) { session.pendingChunkCount != 1 }
      #expect(!miscounted)
    }
  }

  @Test("A chunk that finishes after the user discarded the meeting does not bring it back")
  func lateChunkDoesNotUndoDiscard() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      FileManager.default.createFile(atPath: file.path, contents: Data())

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 15)
      #expect(await waitUntil { transcripts.waiterCount == 1 })

      session.end(preferredName: nil, discard: true)
      session.stopSafetyNetForTesting?.perform()
      #expect(box.finished == 1)
      #expect(!FileManager.default.fileExists(atPath: file.path))

      transcripts.resume(at: 0, returning: "words of a deleted meeting")
      #expect(await waitUntil { box.cleaned == 1 })
      let reappeared = await waitUntil(timeout: 0.3) {
        FileManager.default.fileExists(atPath: file.path)
      }
      #expect(!reappeared)
      #expect(box.postProcessed.isEmpty)
      #expect(!store.chunks.contains { $0.text.contains("deleted meeting") })
    }
  }

  @Test("A chunk that finishes after the user named the meeting lands in the renamed file")
  func lateChunkFollowsRename() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      let stem = file.deletingPathExtension().lastPathComponent
      let renamed = dir.appendingPathComponent("\(stem)-Board.txt")
      FileManager.default.createFile(atPath: file.path, contents: Data())

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 15)
      #expect(await waitUntil { transcripts.waiterCount == 1 })

      session.end(preferredName: "Board", discard: false)
      session.stopSafetyNetForTesting?.perform()
      #expect(box.finished == 1)
      #expect(FileManager.default.fileExists(atPath: renamed.path))
      #expect(!FileManager.default.fileExists(atPath: file.path))
      // Let the store pick up the new stem, as it does before a user can end up here.
      #expect(await waitUntil { store.currentMeetingFilenameStem == "\(stem)-Board" })

      transcripts.resume(at: 0, returning: "named meeting words")
      #expect(await waitUntil { text(at: renamed).contains("named meeting words") })
      #expect(!FileManager.default.fileExists(atPath: file.path))
      #expect(await waitUntil { store.chunks.contains { $0.text == "named meeting words" } })
      #expect(await waitUntil { box.postProcessedURLs.last == renamed })
    }
  }

  @Test("A late chunk for a meeting resumed into the same file reaches the store")
  func lateChunkReachesStoreOfResumedMeeting() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      FileManager.default.createFile(atPath: file.path, contents: Data())

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 15)
      #expect(await waitUntil { transcripts.waiterCount == 1 })

      session.stop()
      session.stopSafetyNetForTesting?.perform()
      #expect(box.finished == 1)
      #expect(await waitUntil { box.postProcessed.count == 1 })

      // Resume into the same file: a new generation, the same meeting.
      session.beginSessionWithoutRecorder(transcriptFile: file)
      transcripts.resume(at: 0, returning: "resumed words")

      #expect(await waitUntil { text(at: file).contains("resumed words") })
      #expect(await waitUntil { store.chunks.contains { $0.text == "resumed words" } })
      // The resumed meeting summarises when it ends, not now.
      let extraPass = await waitUntil(timeout: 0.3) { box.postProcessed.count > 1 }
      #expect(!extraPass)
    }
  }

  @Test("A real pass overtaken by a resumed meeting's late chunk leaves the transcript alone")
  func overtakenPassKeepsLateText() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      try "[0:05] Speaker A: hello\n\n[0:20] Speaker B: hi\n\n".write(
        to: file, atomically: true, encoding: .utf8)

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      box.holdFirstConsolidation()
      box.consolidatedReply = "[0:05] Speaker A: CONSOLIDATED hello\n\n[0:20] Speaker B: CONSOLIDATED hi"
      let session = makeSession(transcripts: transcripts, box: box, realPass: true)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 40)
      #expect(await waitUntil { transcripts.waiterCount == 1 })
      session.stop()
      session.stopSafetyNetForTesting?.perform()
      // The pass `finish()` started is waiting on its consolidation request.
      #expect(await waitUntil { box.consolidationHeld() == true })

      // The user resumes the meeting; the late chunk lands in the resumed meeting.
      session.beginSessionWithoutRecorder(transcriptFile: file)
      transcripts.resume(at: 0, returning: "late words")
      #expect(await waitUntil { text(at: file).contains("late words") })

      // The old pass now gets its consolidated copy, which lacks the late words.
      box.releaseConsolidation()
      let summarised = await waitForSummary(box, timeout: 0.5)
      #expect(!summarised)
      #expect(text(at: file).contains("late words"))
      #expect(!text(at: file).contains("CONSOLIDATED"))
    }
  }

  @Test("A pass still running when the resumed meeting is discarded does not bring it back")
  func runningPassDoesNotUndoDiscard() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      try "[0:05] Speaker A: hello\n\n[0:20] Speaker B: hi\n\n".write(
        to: file, atomically: true, encoding: .utf8)

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      box.holdFirstConsolidation()
      box.consolidatedReply = "[0:05] Speaker A: CONSOLIDATED hello\n\n[0:20] Speaker B: CONSOLIDATED hi"
      let session = makeSession(transcripts: transcripts, box: box, realPass: true)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      session.stop()
      session.stopSafetyNetForTesting?.perform()
      #expect(await waitUntil { box.consolidationHeld() == true })

      // Resume, then throw the meeting away while the first pass is still consolidating.
      session.beginSessionWithoutRecorder(transcriptFile: file)
      session.end(preferredName: nil, discard: true)
      session.stopSafetyNetForTesting?.perform()
      #expect(!FileManager.default.fileExists(atPath: file.path))

      box.releaseConsolidation()
      let summarised = await waitForSummary(box, timeout: 0.5)
      #expect(!summarised)
      #expect(!FileManager.default.fileExists(atPath: file.path))
      #expect(!FileManager.default.fileExists(
        atPath: MeetingListService.summaryURL(transcriptFileURL: file).path))
    }
  }

  @Test("A pass still running when the resumed meeting is named does not leave an orphan")
  func runningPassDoesNotOrphanRenamedMeeting() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      let stem = file.deletingPathExtension().lastPathComponent
      let renamed = dir.appendingPathComponent("\(stem)-Board.txt")
      try "[0:05] Speaker A: hello\n\n[0:20] Speaker B: hi\n\n".write(
        to: file, atomically: true, encoding: .utf8)

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      box.holdFirstConsolidation()
      box.consolidatedReply = "[0:05] Speaker A: CONSOLIDATED hello\n\n[0:20] Speaker B: CONSOLIDATED hi"
      let session = makeSession(transcripts: transcripts, box: box, realPass: true)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      session.stop()
      session.stopSafetyNetForTesting?.perform()
      #expect(await waitUntil { box.consolidationHeld() == true })

      session.beginSessionWithoutRecorder(transcriptFile: file)
      session.end(preferredName: "Board", discard: false)
      session.stopSafetyNetForTesting?.perform()
      #expect(FileManager.default.fileExists(atPath: renamed.path))

      // The pass for the new name summarises once; the old pass must add nothing.
      #expect(await waitUntil { box.summaryCount == 1 })
      box.releaseConsolidation()
      let extra = await waitUntil(timeout: 0.5) { box.summaryCount > 1 }
      #expect(!extra)
      #expect(!FileManager.default.fileExists(atPath: file.path))
      #expect(!FileManager.default.fileExists(
        atPath: MeetingListService.summaryURL(transcriptFileURL: file).path))
    }
  }

  @Test("Chunks failing after the meeting ended raise one alert, not one each")
  func lateFailuresAlertOncePerMeeting() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      let stem = file.deletingPathExtension().lastPathComponent
      defer { MeetingAudioBacklog.remove(stem: stem) }
      FileManager.default.createFile(atPath: file.path, contents: Data())
      let audioA = dir.appendingPathComponent("a.wav")
      let audioB = dir.appendingPathComponent("b.wav")
      FileManager.default.createFile(atPath: audioA.path, contents: Data([0]))
      FileManager.default.createFile(atPath: audioB.path, contents: Data([0]))

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 15, audio: audioA)
      deliver(session, index: 1, start: 45, audio: audioB)
      #expect(await waitUntil { transcripts.waiterCount == 2 })
      session.stop()
      session.stopSafetyNetForTesting?.perform()

      transcripts.fail(at: 0)
      transcripts.fail(at: 1)
      #expect(await waitUntil { box.backlogChanged == 2 })
      #expect(box.alerts.count == 1)
    }
  }

  @Test("A meeting named at End still gets its summary")
  func namedMeetingGetsSummary() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      let stem = file.deletingPathExtension().lastPathComponent
      let renamed = dir.appendingPathComponent("\(stem)-Board.txt")
      FileManager.default.createFile(atPath: file.path, contents: Data())

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      let session = makeSession(transcripts: transcripts, box: box, realPass: true)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 5)
      #expect(await waitUntil { transcripts.waiterCount == 1 })
      transcripts.resume(at: 0, returning: "agenda for the board")
      #expect(await waitUntil { text(at: file).contains("agenda for the board") })

      session.end(preferredName: "Board", discard: false)
      deliver(session, index: 1, start: 30, silent: true, final: true)
      #expect(box.finished == 1)
      #expect(FileManager.default.fileExists(atPath: renamed.path))

      #expect(await waitUntil { box.summaryCount == 1 })
      #expect(box.lastSummaryInput.contains("agenda for the board"))
      #expect(await waitUntil {
        FileManager.default.fileExists(
          atPath: MeetingListService.summaryURL(transcriptFileURL: renamed).path)
      })
    }
  }

  @Test("Several late chunks cost one more pass, not one each")
  func lateChunksShareOnePass() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      FileManager.default.createFile(atPath: file.path, contents: Data())

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      box.holdFirstPass = true
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 5)
      deliver(session, index: 1, start: 20)
      deliver(session, index: 2, start: 35)
      #expect(await waitUntil { transcripts.waiterCount == 3 })

      session.stop()
      session.stopSafetyNetForTesting?.perform()
      // The pass `finish()` started is still running when the chunks land.
      #expect(await waitUntil { box.postProcessed.count == 1 && box.passIsHeld })

      transcripts.resume(at: 0, returning: "one")
      transcripts.resume(at: 1, returning: "two")
      transcripts.resume(at: 2, returning: "three")
      #expect(await waitUntil { LiveMeetingTranscriptStore.parseTranscript(text(at: file)).count == 3 })
      #expect(box.postProcessed.count == 1)

      box.releaseHeldPass()
      #expect(await waitUntil { box.postProcessed.count == 2 })
      let third = await waitUntil(timeout: 0.3) { box.postProcessed.count > 2 }
      #expect(!third)
    }
  }

  @Test("A late failure for a meeting resumed and then discarded keeps no audio")
  func lateFailureAfterResumeAndDiscardKeepsNoBacklog() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      let stem = file.deletingPathExtension().lastPathComponent
      defer { MeetingAudioBacklog.remove(stem: stem) }
      FileManager.default.createFile(atPath: file.path, contents: Data())
      let audio = dir.appendingPathComponent("chunk.wav")
      FileManager.default.createFile(atPath: audio.path, contents: Data([0]))

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 15, audio: audio)
      #expect(await waitUntil { transcripts.waiterCount == 1 })
      session.stop()
      session.stopSafetyNetForTesting?.perform()

      // Resume into the same file, then throw the meeting away.
      session.beginSessionWithoutRecorder(transcriptFile: file)
      session.end(preferredName: nil, discard: true)
      session.stopSafetyNetForTesting?.perform()
      #expect(box.finished == 2)
      #expect(!FileManager.default.fileExists(atPath: file.path))

      transcripts.fail(at: 0)
      #expect(await waitUntil { box.cleaned == 1 })
      #expect(MeetingAudioBacklog.items(stem: stem).isEmpty)
      #expect(!FileManager.default.fileExists(atPath: file.path))
    }
  }

  @Test("A late failure for a finished meeting leaves the pending count alone")
  func lateFailureDoesNotDriveCountNegative() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      let stem = file.deletingPathExtension().lastPathComponent
      defer { MeetingAudioBacklog.remove(stem: stem) }
      FileManager.default.createFile(atPath: file.path, contents: Data())
      let audio = dir.appendingPathComponent("chunk.wav")
      FileManager.default.createFile(atPath: audio.path, contents: Data([0]))

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 15, audio: audio)
      #expect(await waitUntil { transcripts.waiterCount == 1 })
      session.stop()
      session.stopSafetyNetForTesting?.perform()
      #expect(session.pendingChunkCount == 0)

      transcripts.fail(at: 0)
      // The transcript still exists, so the audio is kept for it; that is the failure having run.
      #expect(await waitUntil { !MeetingAudioBacklog.items(stem: stem).isEmpty })
      let negative = await waitUntil(timeout: 0.3) { session.pendingChunkCount != 0 }
      #expect(!negative)
    }
  }

  @Test("A late failure for an ended meeting tells the user the audio is kept")
  func lateFailureForEndedMeetingIsReported() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      let stem = file.deletingPathExtension().lastPathComponent
      defer { MeetingAudioBacklog.remove(stem: stem) }
      FileManager.default.createFile(atPath: file.path, contents: Data())
      let audio = dir.appendingPathComponent("chunk.wav")
      FileManager.default.createFile(atPath: audio.path, contents: Data([0]))

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 15, audio: audio)
      #expect(await waitUntil { transcripts.waiterCount == 1 })
      session.stop()
      session.stopSafetyNetForTesting?.perform()

      transcripts.fail(at: 0)
      #expect(await waitUntil { box.alerts.count == 1 })
      #expect(box.backlogChanged == 1)
      #expect(!box.alerts[0].contains("Recording continues"))
      #expect(box.alerts[0].contains("kept on this Mac"))
    }
  }

  @Test("A stale stop safety net does not finish the next meeting")
  func staleStopSafetyNetDoesNotFinishTheNextMeeting() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let fileA = dir.appendingPathComponent("Meeting-b02-a-\(UUID().uuidString).txt")
      let fileB = dir.appendingPathComponent("Meeting-b02-b-\(UUID().uuidString).txt")
      FileManager.default.createFile(atPath: fileA.path, contents: Data())
      FileManager.default.createFile(atPath: fileB.path, contents: Data())

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      box.transcriptURL = fileB
      let session = makeSession(transcripts: transcripts, box: box)

      session.beginSessionWithoutRecorder(transcriptFile: fileA)
      session.stop()
      let stale = session.stopSafetyNetForTesting
      #expect(stale != nil)
      session.liveMeetingRecorderDidEndWithoutFinalChunk()
      #expect(box.finished == 1)
      box.finished = 0

      session.beginSessionWithoutRecorder(transcriptFile: fileB)
      deliver(session, index: 0, start: 5)
      session.stop()
      deliver(session, index: 1, start: 20, silent: true, final: true)
      #expect(session.pendingChunkCount == 1)
      stale?.perform()
      #expect(box.finished == 0)
      #expect(session.pendingChunkCount == 1)

      #expect(await waitUntil { transcripts.waiterCount == 1 })
      transcripts.resume(at: 0, returning: "still here")
      #expect(await waitUntil { box.finished == 1 })
      #expect(box.transcriptAtFinish.contains("still here"))
    }
  }

  @Test("Out-of-order completions are stored and written in speaking order")
  func outOfOrderCompletionsStayInSpeakingOrder() async throws {
    let store = LiveMeetingTranscriptStore.shared
    store.clearForNewMeeting()
    defer { store.clearForNewMeeting() }

    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: file.path, contents: Data())

    let transcripts = ChunkTranscripts()
    defer { transcripts.resumeOutstanding(returning: "") }
    let session = makeSession(transcripts: transcripts, box: Counters())
    session.beginSessionWithoutRecorder(transcriptFile: file)
    deliver(session, index: 0, start: 0)
    deliver(session, index: 1, start: 90)
    #expect(await waitUntil { transcripts.waiterCount == 2 })

    transcripts.resume(at: 1, returning: "second sentence")
    transcripts.resume(at: 0, returning: "first sentence")

    let ordered = await waitForChunkTexts(at: file, ["first sentence", "second sentence"])
    #expect(ordered)
    #expect(store.chunks.map { $0.text } == ["first sentence", "second sentence"])
    #expect(store.chunks.last?.startTime == 90)
    #expect(store.elapsedSeconds == 90)
  }

  @Test("Stopping again while a meeting is finishing does not hang")
  func secondStopWhileFinishingDoesNotHang() async throws {
    try await withPreservedRecordingMarker {
      let store = LiveMeetingTranscriptStore.shared
      store.clearForNewMeeting()
      defer { store.clearForNewMeeting() }

      let dir = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let file = dir.appendingPathComponent("Meeting-b02-\(UUID().uuidString).txt")
      FileManager.default.createFile(atPath: file.path, contents: Data())
      let stem = file.deletingPathExtension().lastPathComponent

      let transcripts = ChunkTranscripts()
      defer { transcripts.resumeOutstanding(returning: "") }
      let box = Counters()
      box.transcriptURL = dir.appendingPathComponent("\(stem)-Board.txt")
      let session = makeSession(transcripts: transcripts, box: box)
      session.beginSessionWithoutRecorder(transcriptFile: file)
      deliver(session, index: 0, start: 0)
      #expect(await waitUntil { transcripts.waiterCount == 1 })

      session.stop()
      #expect(box.stopping == 1)
      deliver(session, index: 1, start: 30, silent: true, final: true)
      #expect(session.pendingChunkCount == 1)
      #expect(box.finished == 0)

      session.end(preferredName: "Board", discard: false)
      #expect(box.stopping == 1)

      transcripts.resume(at: 0, returning: "kept words")
      #expect(await waitUntil(timeout: 2) { box.finished == 1 })
      #expect(box.transcriptAtFinish.contains("kept words"))
    }
  }

  @Test("The transcript store keeps the latest start time last")
  func storedChunksStayInSpeakingOrder() {
    let store = LiveMeetingTranscriptStore.shared
    store.clearForNewMeeting()
    defer { store.clearForNewMeeting() }
    store.appendChunk(startTime: 90, text: "later")
    store.appendChunk(startTime: 5, text: "earlier")
    #expect(store.chunks.map { $0.text } == ["earlier", "later"])
    #expect(store.chunks.last?.startTime == 90)
    #expect(store.elapsedSeconds == 90)
  }
}

private final class Counters: @unchecked Sendable {
  var stopping = 0
  var finished = 0
  var transcriptAtFinish = ""
  var transcriptURL: URL?
  /// Every end-of-meeting pass the session ran, with the chunks it was given.
  var postProcessed: [(URL, [LiveMeetingChunk])] = []
  var postProcessedURLs: [URL] { postProcessed.map { $0.0 } }
  var backlogChanged = 0
  var alerts: [String] = []
  // The injected LLM calls run off the main actor, so their state sits behind a lock.
  private let llmLock = NSLock()
  private var summaries: [String] = []
  private var consolidationGate: CheckedContinuation<Void, Never>?
  private var holdConsolidation = false
  func holdFirstConsolidation() { holdConsolidation = true }
  var consolidatedReply = ""
  var summaryCount: Int {
    llmLock.lock()
    defer { llmLock.unlock() }
    return summaries.count
  }
  var lastSummaryInput: String {
    llmLock.lock()
    defer { llmLock.unlock() }
    return summaries.last ?? ""
  }
  func hasSummary() -> Bool { summaryCount > 0 }
  func consolidationHeld() -> Bool {
    llmLock.lock()
    defer { llmLock.unlock() }
    return consolidationGate != nil
  }
  func consolidate(_ text: String) async -> String {
    llmLock.lock()
    let hold = holdConsolidation
    holdConsolidation = false  // only the first request waits
    llmLock.unlock()
    if hold {
      await withCheckedContinuation { continuation in
        llmLock.lock()
        consolidationGate = continuation
        llmLock.unlock()
      }
    }
    return consolidatedReply
  }
  func summarize(_ text: String) -> String {
    llmLock.lock()
    summaries.append(text)
    llmLock.unlock()
    return "summary"
  }
  func releaseConsolidation() {
    llmLock.lock()
    let gate = consolidationGate
    consolidationGate = nil
    llmLock.unlock()
    gate?.resume()
  }
  /// When set, the first pass does not return until `releaseHeldPass()`.
  var holdFirstPass = false
  private var heldPass: CheckedContinuation<Void, Never>?
  var passIsHeld: Bool { heldPass != nil }
  func holdIfRequested() async {
    guard holdFirstPass, postProcessed.count == 1 else { return }
    await withCheckedContinuation { heldPass = $0 }
  }
  func releaseHeldPass() {
    heldPass?.resume()
    heldPass = nil
  }
  private let lock = NSLock()
  private var cleanedCount = 0
  /// Audio files released. Called from the chunk's task, read from the test.
  var cleaned: Int {
    lock.lock()
    defer { lock.unlock() }
    return cleanedCount
  }
  func didCleanUp() {
    lock.lock()
    cleanedCount += 1
    lock.unlock()
  }
}

private final class ChunkTranscripts: @unchecked Sendable {
  private let lock = NSLock()
  private var waiters: [Int: CheckedContinuation<String, Error>] = [:]
  private var resumed = Set<Int>()
  /// Slot for an audio URL that does not encode a chunk index. Those tests fail or resume every
  /// waiter, so arrival order is enough. URLs named `b02-chunk-N` are keyed by N: the transcribe
  /// tasks start together and would otherwise register in whichever order they reach this lock,
  /// sending chunk 1's text to chunk 0.
  private var arrival = 0

  var waiterCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return waiters.count
  }

  func next(for url: URL) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      let parsed = Self.chunkIndex(in: url)
      let slot = parsed ?? arrival
      if parsed == nil { arrival += 1 }
      waiters[slot] = continuation
      lock.unlock()
    }
  }

  func resume(at index: Int, returning text: String) {
    lock.lock()
    guard let continuation = waiters[index], !resumed.contains(index) else {
      lock.unlock()
      return
    }
    resumed.insert(index)
    lock.unlock()
    continuation.resume(returning: text)
  }

  func fail(at index: Int) {
    lock.lock()
    guard let continuation = waiters[index], !resumed.contains(index) else {
      lock.unlock()
      return
    }
    resumed.insert(index)
    lock.unlock()
    continuation.resume(throwing: TranscriptionError.networkError("offline"))
  }

  func resumeOutstanding(returning text: String) {
    lock.lock()
    let pending = waiters.keys.filter { !resumed.contains($0) }
    for index in pending { resumed.insert(index) }
    let continuations = pending.map { waiters[$0]! }
    lock.unlock()
    continuations.forEach { $0.resume(returning: text) }
  }

  /// `deliver` names the stand-in file `b02-chunk-N.wav`. A custom audio URL has no index.
  private static func chunkIndex(in url: URL) -> Int? {
    let stem = url.deletingPathExtension().lastPathComponent
    let prefix = "b02-chunk-"
    guard stem.hasPrefix(prefix) else { return nil }
    return Int(stem.dropFirst(prefix.count))
  }
}

@MainActor
private func makeSession(
  transcripts: ChunkTranscripts, box: Counters, realPass: Bool = false
) -> LiveMeetingSession {
  var override: (@MainActor (URL, [LiveMeetingChunk]) async -> Void)?
  var calls: LiveMeetingSession.PostProcessingCalls?
  if realPass {
    calls = LiveMeetingSession.PostProcessingCalls(
      consolidate: { await box.consolidate($0) }, summarize: { box.summarize($0) })
  } else {
    override = { url, chunks in
      box.postProcessed.append((url, chunks))
      await box.holdIfRequested()
    }
  }
  return LiveMeetingSession(
    transcribeChunk: { url in try await transcripts.next(for: url) },
    cleanUpAudioFile: { _ in box.didCleanUp() },
    appStateIsRecordingMeeting: { false },
    onStopping: { box.stopping += 1 },
    onFinished: {
      box.finished += 1
      if let url = box.transcriptURL {
        box.transcriptAtFinish = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      }
    },
    onBacklogChanged: { box.backlogChanged += 1 },
    stopSafetyNetDelay: 3600,
    // The real pass calls an LLM; the host may have a key configured. Tests either replace the
    // whole pass body (scheduling tests) or inject just its two requests (`realPass`).
    postProcessingOverride: override,
    postProcessingCalls: calls,
    presentEndedMeetingAlert: { box.alerts.append($0) }
  )
}

@MainActor
private func deliver(
  _ session: LiveMeetingSession, index: Int, start: TimeInterval, silent: Bool = false,
  final: Bool = false, audio: URL? = nil
) {
  session.liveMeetingRecorder(
    didFinishChunk: audio ?? URL(fileURLWithPath: "/tmp/b02-chunk-\(index).wav"),
    chunkIndex: index,
    startTime: start,
    isSilent: silent,
    isFinal: final
  )
}

private func makeDirectory() throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("b02-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

@MainActor
private func waitForSummary(_ box: Counters, timeout: TimeInterval) async -> Bool {
  await waitUntil(timeout: timeout) { box.hasSummary() }
}

@MainActor
private func waitForChunkTexts(at url: URL, _ expected: [String]) async -> Bool {
  await waitUntil { chunkTexts(at: url) == expected }
}

private func chunkTexts(at url: URL) -> [String] {
  LiveMeetingTranscriptStore.parseTranscript(text(at: url)).map { $0.text }
}

private func chunkTexts(in url: URL) -> [String] {
  LiveMeetingTranscriptStore.parseTranscript(text(at: url)).map { $0.text }
}

private func text(at url: URL) -> String {
  (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

@MainActor
private func waitUntil(
  timeout: TimeInterval = 2, _ predicate: () -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if predicate() { return true }
    try? await Task.sleep(nanoseconds: 20_000_000)
  }
  return predicate()
}

/// `stop()` deletes the recording marker. Put back whatever was there unless a live app rewrote it.
@MainActor
private func withPreservedRecordingMarker(_ body: () async throws -> Void) async throws {
  let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
    .appendingPathComponent("live-meeting-recording.json")
  let before = try? Data(contentsOf: url)
  defer {
    if (try? Data(contentsOf: url)) == nil, let before {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? before.write(to: url, options: .atomic)
    }
  }
  try await body()
}
