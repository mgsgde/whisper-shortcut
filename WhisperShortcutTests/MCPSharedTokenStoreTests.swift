import Foundation
import Security
import Testing
@testable import WhisperShortcut_AppStore

@Suite("MCP shared token store")
struct MCPSharedTokenStoreTests {

  private let account = "mcp-server-token"
  private let group = "team.com.magnusgoedde.whispershortcut.shared"

  // MARK: resolver

  @Test("Rule a: no shared group uses a local token and writes nothing")
  func ruleAUsesLocal() {
    let (resolution, generated) = resolve(shared: nil, local: .found("local-token"))
    #expect(generated == 0)
    #expect(resolution == MCPTokenResolution(
      token: "local-token", writeShared: nil, writeLocal: nil, source: .localOnly))
  }

  @Test("Rule a: missing or empty local token is generated into the local group only")
  func ruleAGenerates() {
    let missing: [MCPTokenRead] = [.notFound, .found("")]
    for local in missing {
      let (resolution, generated) = resolve(shared: nil, local: local, generated: "minted")
      #expect(generated == 1)
      #expect(resolution == MCPTokenResolution(
        token: "minted", writeShared: nil, writeLocal: "minted", source: .generated))
    }
  }

  @Test("Rule a: a failed local read does not mint a token")
  func ruleAReadFailed() {
    let (resolution, generated) = resolve(shared: nil, local: .failed(errSecInteractionNotAllowed))
    #expect(generated == 0)
    #expect(resolution == MCPTokenResolution(
      token: nil, writeShared: nil, writeLocal: nil, source: .failed))
  }

  @Test("Rule a: a refused RNG is a failure")
  func ruleAGenerateFailed() {
    let (resolution, generated) = resolve(shared: nil, local: .notFound, generated: nil)
    #expect(generated == 1)
    #expect(resolution.source == .failed)
    #expect(resolution.token == nil)
    #expect(resolution.writeLocal == nil)
  }

  @Test("Rule b: a shared token is used, and copied locally only when the local item differs")
  func ruleBSharedWins() {
    let same = resolve(shared: .found("shared-token"), local: .found("shared-token"))
    #expect(same.1 == 0)
    #expect(same.0 == MCPTokenResolution(
      token: "shared-token", writeShared: nil, writeLocal: nil, source: .shared))

    let different = resolve(shared: .found("shared-token"), local: .found("local-token"))
    #expect(different.0 == MCPTokenResolution(
      token: "shared-token", writeShared: nil, writeLocal: "shared-token", source: .shared))

    let missing = resolve(shared: .found("shared-token"), local: .notFound)
    #expect(missing.0.writeLocal == "shared-token")
    #expect(missing.0.source == .shared)

    let empty = resolve(shared: .found("shared-token"), local: .found(""))
    #expect(empty.0.writeLocal == "shared-token")

    let unread = resolve(shared: .found("shared-token"), local: .failed(errSecInteractionNotAllowed))
    #expect(unread.1 == 0)
    #expect(unread.0 == MCPTokenResolution(
      token: "shared-token", writeShared: nil, writeLocal: nil, source: .shared))
  }

  @Test("Rule c: an empty shared item promotes a local token, or generates into both")
  func ruleCPromoteOrGenerate() {
    let empty: [MCPTokenRead] = [.notFound, .found("")]
    for shared in empty {
      let promoted = resolve(shared: shared, local: .found("local-token"))
      #expect(promoted.1 == 0)
      #expect(promoted.0 == MCPTokenResolution(
        token: "local-token", writeShared: "local-token", writeLocal: nil, source: .localPromoted))
    }

    let minted = resolve(shared: .notFound, local: .notFound, generated: "minted")
    #expect(minted.1 == 1)
    #expect(minted.0 == MCPTokenResolution(
      token: "minted", writeShared: "minted", writeLocal: "minted", source: .generated))

    let emptyLocal = resolve(shared: .found(""), local: .found(""), generated: "minted")
    #expect(emptyLocal.0.source == .generated)
    #expect(emptyLocal.0.writeShared == "minted")
    #expect(emptyLocal.0.writeLocal == "minted")
  }

  @Test("Rule c: a failed local read does not mint over an item we could not see")
  func ruleCLocalReadFailed() {
    let (resolution, generated) = resolve(
      shared: .notFound, local: .failed(errSecInteractionNotAllowed))
    #expect(generated == 0)
    #expect(resolution.source == .failed)
    #expect(resolution.token == nil)
  }

  @Test("Rule d: a failed shared read falls back to the local token")
  func ruleDLocalFallback() {
    let (resolution, generated) = resolve(
      shared: .failed(errSecInteractionNotAllowed), local: .found("local-token"))
    #expect(generated == 0)
    #expect(resolution == MCPTokenResolution(
      token: "local-token", writeShared: nil, writeLocal: nil, source: .localOnly))
  }

  @Test("Rule d: a failed shared read with no local token generates locally only")
  func ruleDGeneratesLocally() {
    let (resolution, generated) = resolve(
      shared: .failed(errSecAuthFailed), local: .notFound, generated: "minted")
    #expect(generated == 1)
    #expect(resolution == MCPTokenResolution(
      token: "minted", writeShared: nil, writeLocal: "minted", source: .generated))
  }

  @Test("Rule d: both reads failing returns no token")
  func ruleDBothFailed() {
    let (resolution, generated) = resolve(
      shared: .failed(errSecAuthFailed), local: .failed(errSecInteractionNotAllowed))
    #expect(generated == 0)
    #expect(resolution.source == .failed)
    #expect(resolution.token == nil)
    #expect(resolution.writeShared == nil)
    #expect(resolution.writeLocal == nil)
  }

  // MARK: load and store

  @Test("load returns the shared token and makes the local item match it")
  func loadSharedReplacesDifferentLocal() {
    let keychain = MemoryMCPTokenKeychain()
    keychain.values[.init(group: group, account: account)] = "shared-token"
    keychain.values[.init(group: "", account: account)] = "local-token"
    let store = MCPSharedTokenStore(keychain: keychain, sharedGroup: group)

    #expect(store.load(account: account) == "shared-token")
    #expect(keychain.value(group: group, account: account) == "shared-token")
    #expect(keychain.value(group: nil, account: account) == "shared-token")
    #expect(store.adoptedSharedToken)
  }

  @Test("load copies a local token into an empty shared item")
  func loadPromotesLocal() {
    let keychain = MemoryMCPTokenKeychain()
    keychain.values[.init(group: group, account: account)] = ""
    keychain.values[.init(group: "", account: account)] = "local-token"
    let store = MCPSharedTokenStore(keychain: keychain, sharedGroup: group)

    #expect(store.load(account: account) == "local-token")
    #expect(keychain.value(group: group, account: account) == "local-token")
    #expect(keychain.value(group: nil, account: account) == "local-token")
    #expect(!store.adoptedSharedToken)
  }

  @Test("load mints one 64-hex token and stores it in both groups")
  func loadGeneratesIntoBoth() throws {
    let keychain = MemoryMCPTokenKeychain()
    let store = MCPSharedTokenStore(keychain: keychain, sharedGroup: group)
    let token = try #require(store.load(account: account))
    #expect(token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    #expect(keychain.value(group: group, account: account) == token)
    #expect(keychain.value(group: nil, account: account) == token)
  }

  @Test("load with no shared group never reads or writes one")
  func loadWithoutSharedGroup() throws {
    let keychain = MemoryMCPTokenKeychain()
    let store = MCPSharedTokenStore(keychain: keychain, sharedGroup: nil)
    let token = try #require(store.load(account: account))
    #expect(token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    #expect(keychain.value(group: nil, account: account) == token)
    #expect(!keychain.calls.contains { $0.group != nil })
  }

  @Test("load adopts the shared item when its own add loses the race")
  func loadDuplicateRereadsShared() {
    let keychain = MemoryMCPTokenKeychain()
    keychain.readQueue[group] = [.notFound, .found("from-the-other-build")]
    keychain.forcedWriteStatus[group] = errSecDuplicateItem
    let store = MCPSharedTokenStore(keychain: keychain, sharedGroup: group)

    #expect(store.load(account: account) == "from-the-other-build")
    #expect(keychain.value(group: nil, account: account) == "from-the-other-build")
    #expect(keychain.calls.filter { $0.op == "write" && $0.group == group }.count == 1)
  }

  @Test("store writes the token into the shared group and the local group")
  func storeWritesBoth() {
    let keychain = MemoryMCPTokenKeychain()
    let store = MCPSharedTokenStore(keychain: keychain, sharedGroup: group)
    #expect(store.store("regenerated", account: account))
    #expect(keychain.value(group: group, account: account) == "regenerated")
    #expect(keychain.value(group: nil, account: account) == "regenerated")
  }

  private func resolve(
    shared: MCPTokenRead?, local: MCPTokenRead, generated: String? = "unused"
  ) -> (MCPTokenResolution, Int) {
    var calls = 0
    let resolution = MCPSharedTokenStore.resolve(shared: shared, local: local) {
      calls += 1
      return generated
    }
    return (resolution, calls)
  }
}

private final class MemoryMCPTokenKeychain: MCPTokenKeychain {
  struct Key: Hashable {
    var group: String
    var account: String
  }

  var values: [Key: String] = [:]
  var calls: [(op: String, account: String, group: String?)] = []
  var forcedWriteStatus: [String: OSStatus] = [:]
  var readQueue: [String: [MCPTokenRead]] = [:]

  func read(account: String, accessGroup: String?) -> MCPTokenRead {
    calls.append(("read", account, accessGroup))
    if let group = accessGroup, var queued = readQueue[group], !queued.isEmpty {
      let next = queued.removeFirst()
      readQueue[group] = queued
      return next
    }
    if let value = values[Key(group: accessGroup ?? "", account: account)] {
      return .found(value)
    }
    return .notFound
  }

  func write(_ value: String, account: String, accessGroup: String?) -> OSStatus {
    calls.append(("write", account, accessGroup))
    if let group = accessGroup, let status = forcedWriteStatus[group], status != errSecSuccess {
      return status
    }
    values[Key(group: accessGroup ?? "", account: account)] = value
    return errSecSuccess
  }

  func value(group: String?, account: String) -> String? {
    values[Key(group: group ?? "", account: account)]
  }
}
