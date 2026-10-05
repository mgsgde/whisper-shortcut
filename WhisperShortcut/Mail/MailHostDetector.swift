import Foundation
import dnssd

enum MailProviderGuess: Equatable, Sendable {
  case imapHost(String)
  case google
  case microsoft
}

enum MailHostDetector {
  /// MX hostnames for `domain` via DNSServiceQueryRecord (kDNSServiceType_MX), lowercased, without
  /// trailing dot, sorted by preference. Empty on any failure or after `timeout`.
  static func mxHosts(domain: String, timeout: Duration = .seconds(3)) async -> [String] {
    let name = normalizedName(domain)
    guard !name.isEmpty else { return [] }
    let seconds = max(0, Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
    return await withCheckedContinuation { continuation in
      MXQuery.start(domain: name, timeout: seconds, continuation: continuation)
    }
  }

  /// Pure mapping, unit-testable. First MX host that matches wins.
  static func guess(mxHosts: [String]) -> MailProviderGuess? {
    for host in mxHosts {
      let normalized = normalizedName(host)
      guard !normalized.isEmpty else { continue }
      for rule in rules where normalized == rule.suffix || normalized.hasSuffix("." + rule.suffix) {
        return rule.guess
      }
    }
    return nil
  }

  /// mxHosts + guess.
  static func detect(domain: String) async -> MailProviderGuess? {
    guess(mxHosts: await mxHosts(domain: domain))
  }

  private static func normalizedName(_ value: String) -> String {
    var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while name.hasSuffix(".") {
      name.removeLast()
    }
    return name
  }

  private static let rules: [(suffix: String, guess: MailProviderGuess)] = [
    ("ionos.de", .imapHost("imap.ionos.de")),
    ("ionos.com", .imapHost("imap.ionos.de")),
    ("ionos.co.uk", .imapHost("imap.ionos.de")),
    ("kundenserver.de", .imapHost("imap.ionos.de")),
    ("1and1.com", .imapHost("imap.ionos.de")),
    ("rzone.de", .imapHost("imap.strato.de")),
    ("your-server.de", .imapHost("mail.your-server.de")),
    ("mail.icloud.com", .imapHost("imap.mail.me.com")),
    ("mailbox.org", .imapHost("imap.mailbox.org")),
    ("messagingengine.com", .imapHost("imap.fastmail.com")),
    ("zoho.eu", .imapHost("imap.zoho.eu")),
    ("zoho.com", .imapHost("imap.zoho.com")),
    ("hostinger.com", .imapHost("imap.hostinger.com")),
    ("gmx.net", .imapHost("imap.gmx.net")),
    ("web.de", .imapHost("imap.web.de")),
    ("posteo.de", .imapHost("posteo.de")),
    ("google.com", .google),
    ("googlemail.com", .google),
    ("outlook.com", .microsoft),
  ]
}

/// One in-flight MX query. The dnssd callback holds an unretained pointer at this box;
/// `passRetained` is balanced by a single `release` after `DNSServiceRefDeallocate`.
private final class MXQuery: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.whispershortcut.mail.mx")
  private var records: [(preference: UInt16, host: String)] = []
  private var continuation: CheckedContinuation<[String], Never>?
  private var service: DNSServiceRef?
  private var context: UnsafeMutableRawPointer?
  private var finished = false

  static func start(domain: String, timeout: Double, continuation: CheckedContinuation<[String], Never>) {
    let query = MXQuery()
    let context = Unmanaged.passRetained(query).toOpaque()
    query.context = context
    query.continuation = continuation

    var service: DNSServiceRef?
    let error = domain.withCString { name in
      DNSServiceQueryRecord(
        &service,
        0,
        0,
        name,
        UInt16(kDNSServiceType_MX),
        UInt16(kDNSServiceClass_IN),
        mxQueryRecordCallback,
        context
      )
    }
    guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let service else {
      query.finish(deliver: false, deallocateOnQueue: false)
      return
    }
    query.service = service
    let scheduled = DNSServiceSetDispatchQueue(service, query.queue)
    guard scheduled == DNSServiceErrorType(kDNSServiceErr_NoError) else {
      query.finish(deliver: false, deallocateOnQueue: false)
      return
    }
    query.queue.asyncAfter(deadline: .now() + timeout) {
      query.finish(deliver: false, deallocateOnQueue: true)
    }
  }

  func handle(
    flags: DNSServiceFlags,
    errorCode: DNSServiceErrorType,
    rrtype: UInt16,
    rdlen: UInt16,
    rdata: UnsafeRawPointer?
  ) {
    if errorCode != DNSServiceErrorType(kDNSServiceErr_NoError) {
      finish(deliver: false, deallocateOnQueue: true)
      return
    }
    if rrtype == UInt16(kDNSServiceType_MX),
       (flags & kDNSServiceFlagsAdd) != 0,
       let parsed = Self.parseMX(rdata: rdata, length: Int(rdlen)) {
      lock.lock()
      if !finished {
        records.append(parsed)
      }
      lock.unlock()
    }
    if (flags & kDNSServiceFlagsMoreComing) == 0 {
      finish(deliver: true, deallocateOnQueue: true)
    }
  }

  /// Ends the query. Deallocate runs on `queue` once the ref has been scheduled there
  /// (never synchronously inside the dnssd callback — that deadlocks).
  private func finish(deliver: Bool, deallocateOnQueue: Bool) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    let service = self.service
    self.service = nil
    let continuation = self.continuation
    self.continuation = nil
    let context = self.context
    self.context = nil
    let hosts = deliver ? Self.ordered(records) : []
    lock.unlock()

    let release = {
      if let service {
        DNSServiceRefDeallocate(service)
      }
      if let context {
        Unmanaged<MXQuery>.fromOpaque(context).release()
      }
    }
    if deallocateOnQueue, service != nil {
      queue.async(execute: release)
    } else {
      release()
    }
    continuation?.resume(returning: hosts)
  }

  private static func ordered(_ records: [(preference: UInt16, host: String)]) -> [String] {
    var best: [String: UInt16] = [:]
    for record in records {
      if let existing = best[record.host] {
        if record.preference < existing {
          best[record.host] = record.preference
        }
      } else {
        best[record.host] = record.preference
      }
    }
    return best.sorted { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value < rhs.value }
      return lhs.key < rhs.key
    }.map(\.key)
  }

  /// Preference is a big-endian UInt16, then a sequence of length-prefixed labels.
  /// A compression pointer (top bits `11`) ends the parse without following it.
  private static func parseMX(rdata: UnsafeRawPointer?, length: Int) -> (preference: UInt16, host: String)? {
    guard let rdata, length >= 3 else { return nil }
    let bytes = UnsafeRawBufferPointer(start: rdata, count: length)
    let preference = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    var index = 2
    var labels: [String] = []
    while index < bytes.count {
      let labelLength = Int(bytes[index])
      if labelLength == 0 {
        break
      }
      if labelLength & 0xC0 == 0xC0 {
        return nil
      }
      if labelLength > 63 {
        return nil
      }
      index += 1
      guard index + labelLength <= bytes.count else { return nil }
      var label = ""
      label.reserveCapacity(labelLength)
      for byte in bytes[index..<(index + labelLength)] {
        guard let scalar = UnicodeScalar(UInt32(byte)) else { return nil }
        label.append(Character(scalar))
      }
      labels.append(label.lowercased())
      index += labelLength
    }
    guard !labels.isEmpty else { return nil }
    return (preference, labels.joined(separator: "."))
  }
}

private func mxQueryRecordCallback(
  _ sdRef: DNSServiceRef?,
  _ flags: DNSServiceFlags,
  _ interfaceIndex: UInt32,
  _ errorCode: DNSServiceErrorType,
  _ fullname: UnsafePointer<CChar>?,
  _ rrtype: UInt16,
  _ rrclass: UInt16,
  _ rdlen: UInt16,
  _ rdata: UnsafeRawPointer?,
  _ ttl: UInt32,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let query = Unmanaged<MXQuery>.fromOpaque(context).takeUnretainedValue()
  query.handle(flags: flags, errorCode: errorCode, rrtype: rrtype, rdlen: rdlen, rdata: rdata)
}
