import Testing

@testable import WhisperShortcut_AppStore

@Suite("MCP server port fallback")
struct MCPServerPortTests {

  private static var defaultWindow: [UInt16] {
    Array(MCPServer.defaultPort...MCPServer.defaultPort + MCPServer.fallbackPortCount)
  }

  @Test("An explicit port override is the only candidate")
  func overrideWinsAlone() {
    #expect(MCPServer.candidatePorts(override: 47999, sticky: 47830, fallbackEnabled: true) == [47999])
    #expect(MCPServer.candidatePorts(override: 1, sticky: 0, fallbackEnabled: false) == [1])
  }

  @Test("Fallback disabled binds only the default port")
  func fallbackDisabled() {
    #expect(MCPServer.candidatePorts(override: 0, sticky: 47830, fallbackEnabled: false) == [47823])
    #expect(MCPServer.defaultPort == 47823)
  }

  @Test("The default list is the default port plus the next 16")
  func defaultList() {
    let ports = MCPServer.candidatePorts(override: 0, sticky: 0, fallbackEnabled: true)
    #expect(ports.count == 17)
    #expect(ports.first == 47823)
    #expect(ports == Self.defaultWindow)
  }

  @Test("A sticky port in range is tried first and not repeated")
  func stickyFirst() {
    let ports = MCPServer.candidatePorts(override: 0, sticky: 47830, fallbackEnabled: true)
    #expect(ports.first == 47830)
    #expect(ports.dropFirst().first == 47823)
    #expect(ports.filter { $0 == 47830 }.count == 1)
    #expect(ports.count == 17)
    var expected: [UInt16] = [47830]
    expected.append(contentsOf: Self.defaultWindow.filter { $0 != 47830 })
    #expect(ports == expected)
  }

  @Test("A sticky port outside the fallback range is ignored")
  func stickyOutOfRange() {
    let ports = MCPServer.candidatePorts(override: 0, sticky: 5000, fallbackEnabled: true)
    #expect(ports == Self.defaultWindow)
  }
}
