//
//  View+Cursor.swift
//  WhisperShortcut
//

import SwiftUI
import AppKit

extension View {
  /// Shows the pointing-hand cursor when the user hovers over this view (e.g. buttons, links).
  func pointerCursorOnHover() -> some View {
    onHover { inside in
      if inside {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
  }
}
