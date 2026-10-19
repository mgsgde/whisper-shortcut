import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Pins the download/readiness skeleton `ModelManager` (WhisperKit) and `LocalLLMModelManager`
/// (MLX) share. Before `ModelStore` the two were hand-copies that had already drifted: MLX
/// cancelled a running download before deleting, checked cancellation after the fetch and was
/// isolated to one actor; Whisper did none of that. These tests are the equivalence lock that
/// keeps the next family from drifting the same way.
@Suite("Model store", .serialized)
@MainActor
struct ModelStoreTests {

  enum FakeModel: String, CaseIterable, DownloadableModel {
    case small, large
    var displayName: String { rawValue }
    var estimatedSizeMB: Int { 1 }
  }

  /// A store whose "download" and "load" are scripted, and whose disk is a temp directory.
  final class FakeStore: ModelStore<FakeModel> {
    let root: URL
    var fetchCalls = 0
    var loadCalls = 0
    var unloadCalls: [FakeModel] = []
    /// What `fetch` does: create the marker file (success), throw, or wait until cancelled.
    var fetchBehaviour: (FakeModel) async throws -> Void = { _ in }
    var loadBehaviour: (FakeModel) async throws -> Void = { _ in }
    var heals = false
    var canRedownload = true

    init(root: URL) {
      self.root = root
      super.init(logPrefix: "FAKE")
    }

    override nonisolated var rootDirectory: URL { root }
    override nonisolated func resolveModelPath(for model: FakeModel) -> URL? {
      let path = root.appendingPathComponent(model.rawValue)
      return fileManager.fileExists(atPath: path.path) ? path : nil
    }
    override var healsCorruptDownloadOnLoadFailure: Bool { heals }
    override var canRedownloadNow: Bool { canRedownload }
    override func fetch(_ model: FakeModel, onProgress: @escaping (Double) -> Void) async throws {
      fetchCalls += 1
      try await fetchBehaviour(model)
    }
    override func load(_ model: FakeModel) async throws {
      loadCalls += 1
      try await loadBehaviour(model)
    }
    override func unload(_ model: FakeModel) async { unloadCalls.append(model) }

    func writeMarker(_ model: FakeModel) {
      try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      fileManager.createFile(atPath: root.appendingPathComponent(model.rawValue).path, contents: Data("x".utf8))
    }
  }

  private func makeStore() -> FakeStore {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)")
    let store = FakeStore(root: root)
    // Default: a successful fetch writes the marker so the post-download check passes.
    store.fetchBehaviour = { [weak store] model in store?.writeMarker(model) }
    return store
  }

  // MARK: - Download

  @Test("A download that leaves no files behind is reported as failed, not as done")
  func downloadWithoutFilesFails() async {
    let store = makeStore()
    store.fetchBehaviour = { _ in }
    await #expect(throws: ModelStoreError.self) {
      try await store.downloadModel(.small)
    }
    #expect(!store.isModelAvailable(.small))
    #expect(store.downloadingModels.isEmpty, "progress state must be cleared on failure")
  }

  @Test("Two callers of the same download join one fetch")
  func concurrentDownloadsJoin() async throws {
    let store = makeStore()
    store.fetchBehaviour = { [weak store] model in
      try await Task.sleep(for: .milliseconds(50))
      store?.writeMarker(model)
    }
    async let a: Void = store.downloadModel(.small)
    async let b: Void = store.downloadModel(.small)
    _ = try await (a, b)
    #expect(store.fetchCalls == 1)
    #expect(store.isModelAvailable(.small))
  }

  @Test("Cancel stops a running download and clears the progress state")
  func cancelDownload() async {
    let store = makeStore()
    store.fetchBehaviour = { _ in
      try await Task.sleep(for: .seconds(5))
    }
    let task = Task { try await store.downloadModel(.large) }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(store.downloadingModels.contains(.large))
    store.cancelDownload(.large)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!store.downloadingModels.contains(.large))
    #expect(store.downloadProgress[.large] == nil)
  }

  // MARK: - Ready

  @Test("ensureReady downloads a missing model, then loads it")
  func ensureReadyDownloadsThenLoads() async throws {
    let store = makeStore()
    var statuses: [String] = []
    try await store.ensureReady(.small) { statuses.append($0) }
    #expect(store.fetchCalls == 1)
    #expect(store.loadCalls == 1)
    #expect(statuses.last == "Loading small into memory…")
  }

  @Test("A caller that joins an in-flight ensureReady still sees its progress")
  func joinerSeesProgress() async throws {
    // The 2026-10-18 bug: picking Qwen3.5 9B started a silent background prepare, and the Chat
    // message sent next joined that task and lost its `onProgress` — typing dots for minutes.
    let store = makeStore()
    store.fetchBehaviour = { [weak store] model in
      try await Task.sleep(for: .milliseconds(150))
      store?.writeMarker(model)
    }
    // FakeStore's fetch never reports a fraction itself; drive one through the real path.
    let starter = Task { try await store.ensureReady(.small) }   // silent, like the picker
    try await Task.sleep(for: .milliseconds(30))
    #expect(store.readyPhase[.small] == .downloading(fraction: 0, isRetry: false))

    var statuses: [String] = []
    try await store.ensureReady(.small) { statuses.append($0) }
    try await starter.value

    #expect(statuses.first == "Downloading small — 0% of ~1 MB", "the joiner sees the phase it joined")
    #expect(statuses.last == "Loading small into memory…")
    #expect(store.fetchCalls == 1, "joining must not start a second download")
    #expect(store.readyPhase[.small] == nil, "the phase is cleared once the model is ready")
  }

  @Test("ensureReady skips the download when the files are already there")
  func ensureReadySkipsDownload() async throws {
    let store = makeStore()
    store.writeMarker(.small)
    try await store.ensureReady(.small)
    #expect(store.fetchCalls == 0)
    #expect(store.loadCalls == 1)
  }

  @Test("Self-heal: a load failure re-fetches once only for families that opt in")
  func selfHealIsOptIn() async throws {
    // Opted in (WhisperKit): delete, fetch again, load again.
    let healing = makeStore()
    healing.heals = true
    healing.writeMarker(.small)
    var loadAttempts = 0
    healing.loadBehaviour = { _ in
      loadAttempts += 1
      if loadAttempts == 1 { throw ModelStoreError.fileError("corrupt") }
    }
    try await healing.ensureReady(.small)
    #expect(healing.fetchCalls == 1, "the corrupt folder is fetched once more")
    #expect(healing.loadCalls == 2)
    #expect(healing.unloadCalls == [.small])

    // Not opted in (MLX): the load error surfaces as-is.
    let plain = makeStore()
    plain.writeMarker(.small)
    plain.loadBehaviour = { _ in throw ModelStoreError.fileError("corrupt") }
    await #expect(throws: ModelStoreError.self) { try await plain.ensureReady(.small) }
    #expect(plain.fetchCalls == 0)
  }

  @Test("Self-heal never deletes the files when a re-download cannot succeed (Offline Mode)")
  func noHealWhenRedownloadImpossible() async {
    let store = makeStore()
    store.heals = true
    store.canRedownload = false
    store.writeMarker(.small)
    store.loadBehaviour = { _ in throw ModelStoreError.fileError("corrupt") }
    await #expect(throws: ModelStoreError.self) { try await store.ensureReady(.small) }
    #expect(store.fetchCalls == 0, "no re-download attempt")
    #expect(store.unloadCalls.isEmpty)
    #expect(store.isModelAvailable(.small), "the model files must survive the failed load")
  }

  @Test("ModelManager ties the heal to Offline Mode")
  func managerHealFollowsOfflineMode() {
    #expect(ModelManager.canRedownload(offlineMode: false))
    #expect(!ModelManager.canRedownload(offlineMode: true))
  }

  @Test("Whisper readiness requires a tokenizer WhisperKit can find offline")
  func whisperTokenizerCompleteness() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("TokenizerTests-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let model = root.appendingPathComponent("model")
    let docs = root.appendingPathComponent("docs")
    try fm.createDirectory(at: model, withIntermediateDirectories: true)
    try fm.createDirectory(at: docs, withIntermediateDirectories: true)

    #expect(!ModelManager.hasTokenizer(for: .whisperLargeTurbo, modelFolder: model, documentsDirectory: docs))
    #expect(ModelManager.hasTokenizer(for: .parakeetUltra, modelFolder: model, documentsDirectory: docs),
            "Parakeet has no WhisperKit tokenizer")

    // Bundled in the model folder (what the download step writes).
    let bundled = try #require(ModelManager.bundledTokenizerFolder(for: .whisperLargeTurbo, modelFolder: model))
    #expect(bundled.path.hasSuffix("models/openai/whisper-large-v3"))
    try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
    fm.createFile(atPath: bundled.appendingPathComponent("tokenizer.json").path, contents: Data("{}".utf8))
    #expect(ModelManager.hasTokenizer(for: .whisperLargeTurbo, modelFolder: model, documentsDirectory: docs))
    #expect(!ModelManager.hasTokenizer(for: .whisperSmall, modelFolder: model, documentsDirectory: docs))

    // Legacy: a pre-fix online first load cached it in Documents/huggingface.
    let legacy = docs.appendingPathComponent("huggingface/models/openai/whisper-small")
    try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    fm.createFile(atPath: legacy.appendingPathComponent("tokenizer.json").path, contents: Data("{}".utf8))
    #expect(ModelManager.hasTokenizer(for: .whisperSmall, modelFolder: model, documentsDirectory: docs))
  }

  @Test("A load that timed out or was cancelled is not treated as corrupt")
  func timedOutOrCancelledLoadIsNotCorrupt() async {
    let timedOut = makeStore()
    timedOut.heals = true
    timedOut.writeMarker(.small)
    timedOut.loadBehaviour = { _ in throw TranscriptionError.requestTimeout }
    await #expect(throws: TranscriptionError.requestTimeout) {
      try await timedOut.ensureReady(.small)
    }
    #expect(timedOut.fetchCalls == 0)
    #expect(timedOut.loadCalls == 1)
    #expect(timedOut.unloadCalls.isEmpty)
    #expect(timedOut.isModelAvailable(.small))

    let cancelled = makeStore()
    cancelled.heals = true
    cancelled.writeMarker(.small)
    cancelled.loadBehaviour = { _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) {
      try await cancelled.ensureReady(.small)
    }
    #expect(cancelled.fetchCalls == 0)
    #expect(cancelled.loadCalls == 1)
    #expect(cancelled.unloadCalls.isEmpty)
    #expect(cancelled.isModelAvailable(.small))
  }

  // MARK: - Delete

  @Test("Delete cancels a running download first, so the download cannot re-create the files")
  func deleteCancelsRunningDownload() async {
    let store = makeStore()
    store.fetchBehaviour = { [weak store] model in
      try await Task.sleep(for: .seconds(5))
      store?.writeMarker(model)   // would land after Delete if not cancelled
    }
    let task = Task { try await store.downloadModel(.large) }
    try? await Task.sleep(for: .milliseconds(50))
    // Nothing on disk yet, so the delete itself reports "not found" — the cancel is the point.
    #expect(throws: ModelStoreError.self) { try store.deleteModel(.large) }
    await #expect(throws: CancellationError.self) { try await task.value }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!store.isModelAvailable(.large))
  }

  @Test("Delete removes the files and unloads the model")
  func deleteRemovesAndUnloads() async throws {
    let store = makeStore()
    store.writeMarker(.small)
    try store.deleteModel(.small)
    #expect(!store.isModelAvailable(.small))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(store.unloadCalls == [.small])
  }

  // MARK: - Cancellation classification

  @Test("URLSession's cancel and Swift's CancellationError both count as cancellation")
  func cancellationClassification() {
    #expect(FakeStore.isCancellation(CancellationError()))
    #expect(FakeStore.isCancellation(URLError(.cancelled)))
    #expect(FakeStore.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
    #expect(!FakeStore.isCancellation(URLError(.timedOut)))
  }
}
