import Foundation
import Testing

extension Tag {
  /// Hits a real network (provider APIs, Hugging Face downloads). The hermetic
  /// CI plan skips this tag so a checkout without `.env` still runs a meaningful suite.
  @Tag static var liveNetwork: Self
}

enum TestRun {
  /// Set by `scripts/run-tests.sh --hermetic` and the hermetic xctestplan.
  /// Live-network suites also honour it so a full-plan run with the flag still stays offline.
  static var isHermetic: Bool {
    ProcessInfo.processInfo.environment["HERMETIC"] == "1"
  }
}
