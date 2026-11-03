import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// The pure half of `ExtraModelFolder`: which paths inside the user's folder are tried, and in
/// which order. The bookmark half is deliberately not tested here — creating and resolving a
/// security-scoped bookmark needs a real `NSOpenPanel` selection and a signed, sandboxed app, so
/// it can only be checked by hand (see the manual steps in the change report).
@Suite("Extra model folder — candidate layouts")
struct ExtraModelFolderTests {

  private let folder = URL(fileURLWithPath: "/Users/me/testmodels")

  @Test("Whisper tries flat names first, then a WhisperKit tree, then a Hugging Face cache")
  func whisperCandidateOrder() {
    let paths = ExtraModelFolder.whisperCandidates(in: folder, variant: "large-v3-v20240930_turbo")
      .map(\.path)
    #expect(paths == [
      "/Users/me/testmodels/openai_whisper-large-v3-v20240930_turbo",
      "/Users/me/testmodels/large-v3-v20240930_turbo",
      "/Users/me/testmodels/whisper-large-v3-v20240930_turbo",
      "/Users/me/testmodels/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo",
      "/Users/me/testmodels/models/openai/whisper-large-v3-v20240930_turbo",
    ])
  }

  @Test("A short variant name keeps the same shape")
  func whisperCandidateOrderShortVariant() {
    let paths = ExtraModelFolder.whisperCandidates(in: folder, variant: "base").map(\.path)
    #expect(paths.first == "/Users/me/testmodels/openai_whisper-base")
    #expect(paths.last == "/Users/me/testmodels/models/openai/whisper-base")
    #expect(paths.count == 5)
  }

  @Test("MLX tries the repo id flat, then under models/ — the org/repo split is the same path")
  func mlxCandidateOrder() {
    let paths = ExtraModelFolder.mlxRepoCandidates(
      in: folder, huggingFaceID: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    ).map(\.path)
    #expect(paths == [
      "/Users/me/testmodels/mlx-community/Qwen3-4B-Instruct-2507-4bit",
      "/Users/me/testmodels/models/mlx-community/Qwen3-4B-Instruct-2507-4bit",
    ])
  }

  @Test("An id without an org keeps two candidates and never duplicates one")
  func mlxCandidateWithoutOrg() {
    let paths = ExtraModelFolder.mlxRepoCandidates(in: folder, huggingFaceID: "Qwen3-4B")
      .map(\.path)
    #expect(paths == [
      "/Users/me/testmodels/Qwen3-4B",
      "/Users/me/testmodels/models/Qwen3-4B",
    ])
  }

  @Test("Delete only ever reaches inside the app's own model folder")
  func deleteStaysInsideTheAppsOwnFolder() {
    let root = URL(fileURLWithPath: "/Users/me/Library/WhisperKit")
    #expect(ModelStore<OfflineModelType>.isInside(
      URL(fileURLWithPath: "/Users/me/Library/WhisperKit/models/x"), root))
    #expect(!ModelStore<OfflineModelType>.isInside(
      URL(fileURLWithPath: "/Users/me/testmodels/openai_whisper-base"), root))
    // A sibling whose name merely starts with the root's name is not inside it.
    #expect(!ModelStore<OfflineModelType>.isInside(
      URL(fileURLWithPath: "/Users/me/Library/WhisperKitBackup/x"), root))
  }
}
