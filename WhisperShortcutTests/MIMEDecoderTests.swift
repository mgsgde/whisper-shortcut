import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("MIME decoder")
struct MIMEDecoderTests {
  @Test func quotedPrintableISO88591WithSoftBreaks() {
    let raw = mail("""
    From: a@b.test
    Subject: Hallo
    Content-Type: text/plain; charset=ISO-8859-1
    Content-Transfer-Encoding: quoted-printable

    Gr=FC=DFe=
     aus M=FCnchen
    """)
    let decoded = MIMEDecoder.decode(raw)
    #expect(decoded.body.contains("Grüße aus München"))
    #expect(!decoded.body.contains("="))
  }

  @Test func encodedWordSubjects() {
    let base64 = Data("Grüße".utf8).base64EncodedString()
    let utf8 = MIMEDecoder.decode(mail("""
    Subject: =?UTF-8?B?\(base64)?=
    Content-Type: text/plain; charset=utf-8

    x
    """))
    #expect(utf8.subject == "Grüße")

    let latin = MIMEDecoder.decode(mail("""
    Subject: =?ISO-8859-1?Q?Gr=FC=DFe?=
    Content-Type: text/plain; charset=utf-8

    x
    """))
    #expect(latin.subject == "Grüße")
  }

  @Test func nestedAlternativePrefersPlain() {
    let decoded = MIMEDecoder.decode(mail("""
    From: Ann <ann@example.com>
    To: Bo <bo@example.com>
    Cc: Cy <cy@example.com>
    Subject: Nest
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="outer"

    --outer
    Content-Type: multipart/alternative; boundary="inner"

    --inner
    Content-Type: text/plain; charset=utf-8

    PLAINTEXT
    --inner
    Content-Type: text/html; charset=utf-8

    <p>HTMLTEXT</p>
    --inner--
    --outer
    Content-Type: text/plain; charset=utf-8
    Content-Disposition: attachment; filename="note.txt"

    abc
    --outer--
    """))
    #expect(decoded.body == "PLAINTEXT")
    #expect(!decoded.body.contains("HTMLTEXT"))
    #expect(decoded.from == "Ann <ann@example.com>")
    #expect(decoded.to == "Bo <bo@example.com>")
    #expect(decoded.cc == "Cy <cy@example.com>")
    #expect(decoded.attachments.count == 1)
    #expect(decoded.attachments[0].name == "note.txt")
    #expect(decoded.attachments[0].bytes == 3)
  }

  @Test func htmlOnlyFallbackStripsTags() {
    let decoded = MIMEDecoder.decode(mail("""
    Content-Type: text/html; charset=utf-8

    <html><head><style>p { color: red; }</style></head><body><p>Hello<br>World</p><script>alert(1)</script>A &amp; B</body></html>
    """))
    #expect(decoded.body.contains("Hello"))
    #expect(decoded.body.contains("World"))
    #expect(decoded.body.contains("\n"))
    #expect(decoded.body.contains("A & B"))
    #expect(!decoded.body.lowercased().contains("alert"))
    #expect(!decoded.body.contains("color"))
    #expect(!decoded.body.contains("<"))
  }

  @Test func attachmentNameAndDecodedSize() {
    let decoded = MIMEDecoder.decode(mail("""
    Content-Type: multipart/mixed; boundary="b"

    --b
    Content-Type: text/plain; charset=utf-8

    hello
    --b
    Content-Type: application/pdf
    Content-Transfer-Encoding: base64
    Content-Disposition: attachment; filename*=UTF-8''Gr%C3%BC%C3%9Fe.txt

    YWJj
    --b--
    """))
    #expect(decoded.body == "hello")
    #expect(decoded.attachments.count == 1)
    #expect(decoded.attachments[0].name == "Grüße.txt")
    #expect(decoded.attachments[0].bytes == 3)
  }

  @Test func bodyTruncatesAtTwentyThousand() {
    let payload = String(repeating: "a", count: 20_001)
    let raw = Data("Content-Type: text/plain; charset=utf-8\r\n\r\n".utf8) + Data(payload.utf8)
    let decoded = MIMEDecoder.decode(raw)
    #expect(decoded.body.hasPrefix(String(repeating: "a", count: 20_000)))
    #expect(decoded.body.hasSuffix("…[truncated]"))
    #expect(decoded.body.count == 20_000 + "…[truncated]".count)
  }
}

private func mail(_ text: String) -> Data {
  Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
}
