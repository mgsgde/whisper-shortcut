import AppKit
import HotKey
import Testing

@testable import WhisperShortcut_AppStore

/// Covers how a stored binding renders in the menu bar and Settings. The failure mode is silent
/// and cosmetic-looking but disorienting: a shortcut that shows up as "Key", as an empty box, or
/// as nothing at all leaves the user unable to tell what they bound.
@Suite("Shortcut display")
struct ShortcutDisplayTests {

  /// Rendering a shortcut used to kill the test host, twice over, for different reasons.
  ///
  /// `layoutAwareCharacter` reaches `TISGetInputSourceProperty`, and HIToolbox both refuses
  /// concurrent access *and* calls `dispatch_assert_queue` — it has to be on the main queue.
  /// v8.09 serialized the calls with a lock, which removed the `abort()` but not the trap: the
  /// CI host kept dying with `EXC_BREAKPOINT` on a `com.apple.root.user-initiated-qos.cooperative`
  /// thread. The fix is a main-thread-refreshed cache, so this test has to prove two things at
  /// once, which is why it renders on the main actor first.
  ///
  /// Note the failure signature: a regression kills the host rather than failing cleanly, and
  /// xcodebuild then blames whichever test last *completed* — it named
  /// `SettingsSlotRoundTripTests` for four releases while that suite was passing.
  @Test("Rendering from many threads at once does not abort the process")
  func concurrentRenderingIsSafe() async {
    let keys: [Key] = [.f17, .f13, .f20, .f1, .a, .space, .comma, .period]

    // Warm the layout cache the way the app does — the first render of any shortcut happens on
    // the main thread. Without this the concurrent renders below would all take the cold-cache
    // path, return early, and the test would pass without ever reaching HIToolbox.
    await MainActor.run {
      _ = ShortcutDefinition(key: .a, modifiers: []).displayString
    }

    await withTaskGroup(of: Void.self) { group in
      for i in 0..<500 {
        group.addTask {
          let definition = ShortcutDefinition(key: keys[i % keys.count], modifiers: [])
          _ = definition.displayString
          _ = definition.displayStringWithSeparator
        }
      }
    }
  }

  /// The off-main path must stay non-fatal even when nothing has warmed the cache, which is the
  /// state a freshly launched process is in. Falling back to `Key.displayString` is allowed;
  /// trapping is not.
  @Test("Rendering off the main thread with a cold cache falls back instead of trapping")
  func offMainRenderingIsNonFatal() async {
    await Task.detached {
      #expect(ShortcutDefinition(key: .f17, modifiers: []).displayString == "F17")
      _ = ShortcutDefinition(key: .a, modifiers: []).displayString
    }.value
  }

  @Test("Bare function keys render as their name")
  func bareFunctionKey() {
    // F13–F20 are what programmable keyboards send for a dedicated key, and they are bindable
    // without a modifier. Before they had `displayString` cases they rendered as "Key".
    #expect(ShortcutDefinition(key: .f17, modifiers: []).displayString == "F17")
    #expect(ShortcutDefinition(key: .f13, modifiers: []).displayString == "F13")
    #expect(ShortcutDefinition(key: .f20, modifiers: []).displayString == "F20")
    #expect(ShortcutDefinition(key: .f1, modifiers: []).displayString == "F1")
  }

  @Test("A function key's private-use character is not used as the label")
  func functionKeyDisplayCharacterIsIgnored() {
    // The recorder stores `charactersIgnoringModifiers`, which for F17 is AppKit's
    // NSF17FunctionKey (U+F712) — rendering it shows an empty glyph box.
    let recorded = ShortcutDefinition(
      key: .f17, modifiers: [], isEnabled: true, displayCharacter: "\u{F712}")
    #expect(recorded.displayString == "F17")
  }

  @Test("Space renders as its name, not as a blank")
  func spaceIsNamed() {
    let recorded = ShortcutDefinition(
      key: .space, modifiers: [.option], isEnabled: true, displayCharacter: " ")
    #expect(recorded.displayString == "⌥Space")
  }

  @Test("Printable characters still win over the layout-independent name")
  func printableCharacterIsKept() {
    // German layout: the keycode that is "Y" on US-QWERTY prints "Z".
    let recorded = ShortcutDefinition(
      key: .y, modifiers: [.command], isEnabled: true, displayCharacter: "z")
    #expect(recorded.displayString == "⌘Z")
    #expect(ShortcutDefinition(key: .one, modifiers: [.command]).displayString == "⌘1")
  }

  @Test("A disabled binding reads as Disabled regardless of key")
  func disabledBinding() {
    #expect(ShortcutDefinition(key: .f17, modifiers: [], isEnabled: false).displayString == "Disabled")
  }
}
