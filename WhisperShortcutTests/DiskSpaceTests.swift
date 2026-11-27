import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Disk space")
struct DiskSpaceTests {
  private let needed: Int64 = 100_000_000

  @Test("Large important-usage capacity passes")
  func importantUsageLarge() throws {
    try DiskSpace.check(neededBytes: needed, importantUsage: 10_000_000_000, plain: nil)
  }

  @Test("Small important-usage capacity throws")
  func importantUsageSmall() {
    #expect(throws: DiskSpaceError.self) {
      try DiskSpace.check(neededBytes: needed, importantUsage: 1_000_000, plain: 10_000_000_000)
    }
  }

  @Test("Important usage of 0 falls back to a large plain capacity")
  func zeroFallsBackLarge() throws {
    try DiskSpace.check(neededBytes: needed, importantUsage: 0, plain: 10_000_000_000)
  }

  @Test("Important usage of 0 falls back to a small plain capacity and throws")
  func zeroFallsBackSmall() {
    #expect(throws: DiskSpaceError.self) {
      try DiskSpace.check(neededBytes: needed, importantUsage: 0, plain: 1_000_000)
    }
  }

  @Test("Unknown capacity proceeds")
  func bothNil() throws {
    try DiskSpace.check(neededBytes: needed, importantUsage: nil, plain: nil)
  }
}
