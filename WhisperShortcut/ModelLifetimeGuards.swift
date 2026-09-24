import Foundation

/// Memory-pressure source and idle-unload task shared by the on-device model owners.
///
/// Each owner keeps its own instance, its own reason string, and its own idle interval.
/// The event handler and the idle action are the only things that differ.
final class ModelLifetimeGuards {
  private var memoryPressureSource: DispatchSourceMemoryPressure?
  private var idleUnloadTask: Task<Void, Never>?

  func installMemoryPressureHandler(_ handler: @escaping () -> Void) {
    guard memoryPressureSource == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .global(qos: .utility))
    source.setEventHandler(handler: handler)
    source.resume()
    memoryPressureSource = source
  }

  func scheduleIdleUnload(after seconds: TimeInterval, _ action: @escaping @Sendable () async -> Void) {
    idleUnloadTask?.cancel()
    idleUnloadTask = Task {
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      await action()
    }
  }

  func cancelIdleUnload() {
    idleUnloadTask?.cancel()
    idleUnloadTask = nil
  }
}
