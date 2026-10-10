import CoreGraphics
import XCTest
@testable import WhisperShortcut_AppStore

final class FullPageCaptureTests: XCTestCase {

  /// 100-row viewport: 10 header rows (9000+) + page[s..<s+85] + 5 footer rows (8000+).
  /// A scroll of 60 shares 25 middle rows and must come back as shift 60.
  func testScrollOfSixtyFindsHeaderFooterAndShift() {
    let page = (0..<500).map { UInt64($0) }
    let header = (0..<10).map { UInt64(9000 + $0) }
    let footer = (0..<5).map { UInt64(8000 + $0) }
    func frame(at offset: Int) -> [UInt64] {
      header + Array(page[offset..<(offset + 85)]) + footer
    }
    let overlap = FullPageCapture.findOverlap(previous: frame(at: 0), next: frame(at: 60))
    XCTAssertEqual(overlap?.header, 10)
    XCTAssertEqual(overlap?.footer, 5)
    XCTAssertEqual(overlap?.shift, 60)
  }

  func testIdenticalFramesReturnNil() {
    let frame = (0..<100).map { UInt64($0) }
    XCTAssertNil(FullPageCapture.findOverlap(previous: frame, next: frame))
  }

  func testUnrelatedFramesAppendTheWholeMiddle() {
    var state: UInt64 = 0x1234_5678_9ABC_DEF0
    func next() -> UInt64 {
      state &*= 6_364_136_223_846_793_005
      state &+= 1
      return state
    }
    let height = 100
    let previous = (0..<height).map { _ in next() }
    let nextFrame = (0..<height).map { _ in next() }
    let overlap = FullPageCapture.findOverlap(previous: previous, next: nextFrame)
    XCTAssertNotNil(overlap)
    let middle = height - (overlap?.header ?? 0) - (overlap?.footer ?? 0)
    XCTAssertEqual(overlap?.shift, middle)
  }

  func testStitchThreeFramesMatchesPageRows() throws {
    let headerCount = 10
    let footerCount = 5
    let middleCount = 85
    let shifts = [60, 60]
    let pageLength = middleCount + shifts.reduce(0, +)
    func color(_ value: Int) -> (UInt8, UInt8, UInt8) {
      (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }
    func frameRows(at offset: Int) -> [(UInt8, UInt8, UInt8)] {
      (0..<headerCount).map { color(9000 + $0) }
        + (0..<middleCount).map { color(offset + $0) }
        + (0..<footerCount).map { color(8000 + $0) }
    }
    let frames = [0, 60, 120].map { image(from: frameRows(at: $0)) }
    var pageRows: [(UInt8, UInt8, UInt8)] = []
    pageRows += (0..<headerCount).map { color(9000 + $0) }
    pageRows += (0..<pageLength).map { color($0) }
    pageRows += (0..<footerCount).map { color(8000 + $0) }
    let expectedHeight = (frames[0].height - footerCount) + shifts.reduce(0, +) + footerCount

    let stitched = try XCTUnwrap(FullPageCapture.stitch(frames))
    XCTAssertEqual(stitched.width, 4)
    XCTAssertEqual(stitched.height, expectedHeight)
    XCTAssertEqual(pageRows.count, expectedHeight)

    let got = FullPageCapture.rowSignatures(stitched)
    let want = FullPageCapture.rowSignatures(image(from: pageRows))
    XCTAssertEqual(got.count, want.count)
    for index in 0..<min(got.count, want.count) {
      XCTAssertEqual(got[index], want[index], "row \(index)")
      if got[index] != want[index] { return }
    }
  }

  /// Memory row 0 is the top row, so the first stored color is the top of the image.
  private func image(from rows: [(UInt8, UInt8, UInt8)], width: Int = 4) -> CGImage {
    let height = rows.count
    guard let ctx = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      fatalError("bitmap context")
    }
    let pixels = ctx.data!.bindMemory(to: UInt8.self, capacity: height * width * 4)
    for (y, rgb) in rows.enumerated() {
      for x in 0..<width {
        let index = (y * width + x) * 4
        pixels[index] = rgb.0
        pixels[index + 1] = rgb.1
        pixels[index + 2] = rgb.2
        pixels[index + 3] = 255
      }
    }
    guard let image = ctx.makeImage() else { fatalError("makeImage") }
    return image
  }
}
