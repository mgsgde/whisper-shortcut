import Foundation
import HotKey

/// How a status-menu row's title is written. Shortcuts that AppKit can show itself (single
/// character keys) go into `keyEquivalent`; the rest (function keys, arrows, …) are appended to
/// the title, padded to a fixed column. Every title write goes through `render`, so a row that is
/// retitled later ("Stop Dictate") keeps its shortcut visible instead of losing it.
enum StatusMenuTitle {
  /// Width the base title is padded to so shortcut glyphs align down the menu.
  static let columnWidth = 26

  /// The `keyEquivalent` for keys AppKit can render natively; empty for function and special keys.
  static func keyEquivalentCharacter(for key: Key) -> String {
    let keyMap: [Key: String] = [
      .one: "1", .two: "2", .three: "3", .four: "4", .five: "5",
      .six: "6", .seven: "7", .eight: "8", .nine: "9", .zero: "0",
      .a: "a", .b: "b", .c: "c", .d: "d", .e: "e", .f: "f",
      .g: "g", .h: "h", .i: "i", .j: "j", .k: "k", .l: "l",
      .m: "m", .n: "n", .o: "o", .p: "p", .q: "q", .r: "r",
      .s: "s", .t: "t", .u: "u", .v: "v", .w: "w", .x: "x",
      .y: "y", .z: "z",
      .space: " ",
    ]
    return keyMap[key] ?? ""
  }

  /// `base` alone when the shortcut is off or the row carries a native `keyEquivalent`; otherwise
  /// `base` padded to `columnWidth` (or followed by two spaces when already longer) + `display`.
  static func render(base: String, isEnabled: Bool, keyEquivalent: String, display: String)
    -> String
  {
    guard isEnabled, keyEquivalent.isEmpty else { return base }
    let padded =
      base.count < columnWidth
      ? base.padding(toLength: columnWidth, withPad: " ", startingAt: 0)
      : base + "  "
    return "\(padded)\(display)"
  }
}
