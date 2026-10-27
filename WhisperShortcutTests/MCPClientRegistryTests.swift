import XCTest

@testable import WhisperShortcut_AppStore

final class MCPClientRegistryTests: XCTestCase {

  private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: UUID().uuidString)!
  }

  func testRecordAndReloadPersists() {
    let defaults = freshDefaults()
    let registry = MCPClientRegistry(defaults: defaults)
    registry.record(name: "claude-code", version: "1.2.3", access: .write)

    XCTAssertEqual(registry.clients.count, 1)
    XCTAssertEqual(registry.clients.first?.name, "claude-code")
    XCTAssertEqual(registry.clients.first?.version, "1.2.3")
    XCTAssertEqual(registry.clients.first?.access, "write")

    let reloaded = MCPClientRegistry(defaults: defaults)
    XCTAssertEqual(reloaded.clients.count, 1)
    XCTAssertEqual(reloaded.clients.first?.name, "claude-code")
    XCTAssertEqual(reloaded.clients.first?.version, "1.2.3")
    XCTAssertEqual(reloaded.clients.first?.access, "write")
  }

  func testUpsertUpdatesAccessAndVersionAndReordersNewestFirst() {
    let defaults = freshDefaults()
    let registry = MCPClientRegistry(defaults: defaults)
    let earlier = Date(timeIntervalSince1970: 1_000)
    let later = Date(timeIntervalSince1970: 2_000)

    registry.record(name: "claude-code", version: "1.0", access: .read, at: earlier)
    registry.record(name: "other-app", version: "0.1", access: .read, at: later)
    XCTAssertEqual(registry.clients.map(\.name), ["other-app", "claude-code"])

    // Re-recording "claude-code" with a newer date updates it in place and moves it to front.
    let newest = Date(timeIntervalSince1970: 3_000)
    registry.record(name: "claude-code", version: "2.0", access: .write, at: newest)

    XCTAssertEqual(registry.clients.count, 2)
    XCTAssertEqual(registry.clients.map(\.name), ["claude-code", "other-app"])
    XCTAssertEqual(registry.clients.first?.version, "2.0")
    XCTAssertEqual(registry.clients.first?.access, "write")
  }

  func testCapsAtTenClientsDroppingOldest() {
    let defaults = freshDefaults()
    let registry = MCPClientRegistry(defaults: defaults)

    for i in 0..<12 {
      registry.record(
        name: "client-\(i)", version: "1.0", access: .read,
        at: Date(timeIntervalSince1970: TimeInterval(i)))
    }

    XCTAssertEqual(registry.clients.count, MCPClientRegistry.maxClients)
    // Oldest two (client-0, client-1) were dropped; newest (client-11) kept first.
    XCTAssertEqual(registry.clients.first?.name, "client-11")
    XCTAssertFalse(registry.clients.contains { $0.name == "client-0" })
    XCTAssertFalse(registry.clients.contains { $0.name == "client-1" })
  }

  func testEmptyNameIsIgnored() {
    let defaults = freshDefaults()
    let registry = MCPClientRegistry(defaults: defaults)
    registry.record(name: "", version: "1.0", access: .read)
    registry.record(name: "   ", version: "1.0", access: .read)
    XCTAssertTrue(registry.clients.isEmpty)
  }

  func testClientMatchingPrefix() {
    let defaults = freshDefaults()
    let registry = MCPClientRegistry(defaults: defaults)
    registry.record(name: "Claude-Code", version: "1.0", access: .write)
    registry.record(name: "other-app", version: "1.0", access: .read)

    XCTAssertEqual(registry.client(matching: "claude-code")?.name, "Claude-Code")
    XCTAssertEqual(registry.client(matching: "claude")?.name, "Claude-Code")
    XCTAssertNil(registry.client(matching: "nonexistent"))
  }

  func testForgetAllClearsClients() {
    let defaults = freshDefaults()
    let registry = MCPClientRegistry(defaults: defaults)
    registry.record(name: "claude-code", version: "1.0", access: .write)
    XCTAssertFalse(registry.clients.isEmpty)
    registry.forgetAll()
    XCTAssertTrue(registry.clients.isEmpty)

    let reloaded = MCPClientRegistry(defaults: defaults)
    XCTAssertTrue(reloaded.clients.isEmpty)
  }

  // MARK: - Dispatcher hook

  func testDispatcherInitializeCallsOnInitializeWithClientInfoAndAccess() throws {
    let meetings = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-client-registry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
    var dispatcher = MCPDispatcher(
      meetingTools: MCPMeetingTools(meetingsDirectory: meetings, liveStem: { nil }),
      configTools: MCPTestEnv().tools())

    var capturedName: String?
    var capturedVersion: String?
    var capturedAccess: MCPAccess?
    dispatcher.onInitialize = { name, version, access in
      capturedName = name
      capturedVersion = version
      capturedAccess = access
    }

    let message: [String: Any] = [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": [
        "protocolVersion": "2025-06-18",
        "clientInfo": ["name": "claude-code", "version": "1.2.3"],
      ],
    ]
    _ = dispatcher.dispatch(message, access: .write)

    XCTAssertEqual(capturedName, "claude-code")
    XCTAssertEqual(capturedVersion, "1.2.3")
    XCTAssertEqual(capturedAccess, .write)
  }
}
