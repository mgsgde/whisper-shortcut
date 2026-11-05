import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Thread-safe bag the two chunk pipelines share. Lost `add` calls drop a transcribed
/// window; lost `addError` calls hide a failed chunk from the merge step.
@Suite("ChunkResultAccumulator")
struct ChunkResultAccumulatorTests {

  @Test("Values, errors and the completed count are recorded independently")
  func recordsValuesErrorsAndCount() async {
    let accumulator = ChunkResultAccumulator<String>()
    await accumulator.add("a")
    await accumulator.add("b")
    await accumulator.addError(index: 2, error: TranscriptionError.noSpeechDetected)
    #expect(await accumulator.incrementCompleted() == 1)
    #expect(await accumulator.incrementCompleted() == 2)
    #expect(await accumulator.incrementCompleted() == 3)

    let values = await accumulator.allValues()
    #expect(values == ["a", "b"])
    let errors = await accumulator.allErrors()
    #expect(errors.count == 1)
    #expect(errors[0].index == 2)
    #expect(errors[0].error as? TranscriptionError == .noSpeechDetected)
  }

  @Test("Concurrent adds from a task group all land")
  func concurrentAdds() async {
    let accumulator = ChunkResultAccumulator<Int>()
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<20 {
        group.addTask {
          await accumulator.add(i)
          _ = await accumulator.incrementCompleted()
        }
      }
    }
    let values = await accumulator.allValues()
    #expect(Set(values) == Set(0..<20))
    #expect(values.count == 20)
    #expect(await accumulator.incrementCompleted() == 21)
  }
}
