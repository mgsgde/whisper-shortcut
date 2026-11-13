// ax-walk <pid> dump | click-button <n, negative from the end> | click-role <AXRole> | set-field <text>
// Walks the first window of the process with the given pid through the Accessibility API.
// Used instead of AppleScript/System Events, which address a process by NAME and so resolve a
// test-profile copy ("WhisperShortcut Dev") against the user's daily app of the same name.
import ApplicationServices
import Foundation

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? (v as AnyObject?) : nil
}
func str(_ el: AXUIElement, _ name: String) -> String {
  if let s = attr(el, name) as? String { return s }
  return ""
}

let argv = CommandLine.arguments
guard argv.count >= 3, let pid = Int32(argv[1]) else {
  FileHandle.standardError.write(Data("usage: ax-walk <pid> dump|click-button <n>|click-role <role>|set-field <text>\n".utf8))
  exit(2)
}
let act = argv[2]
let arg = argv.count > 3 ? argv[3] : ""
let app = AXUIElementCreateApplication(pid)
guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let win = windows.first else {
  print("missing")
  exit(0)
}
var theRole = "AXButton"
if act == "click-role" { theRole = arg }
if act == "set-field" { theRole = "AXTextField" }

var hits: [AXUIElement] = []
var dumped: [String] = []
let titleBarSubroles: Set<String> = ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton"]

func collect(_ el: AXUIElement, _ depth: Int) {
  if depth > 16 { return }
  let kids = (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  for c in kids {
    let r = str(c, kAXRoleAttribute)
    var n = str(c, kAXTitleAttribute)
    if n.isEmpty { n = str(c, kAXDescriptionAttribute) }
    if n.isEmpty { n = str(c, kAXValueAttribute) }  // static text carries its text as value
    dumped.append("\(r) | \(n)")
    let sr = str(c, kAXSubroleAttribute)
    if r == theRole && !titleBarSubroles.contains(sr) { hits.append(c) }
    collect(c, depth + 1)
  }
}
collect(win, 0)

if act == "dump" {
  print(dumped.joined(separator: "\n"))
  exit(0)
}
if hits.isEmpty { print("missing"); exit(0) }
var idx = 1
if act == "click-button" { idx = Int(arg) ?? 1 }
if idx < 0 { idx = hits.count + idx + 1 }
if idx < 1 || idx > hits.count { print("missing"); exit(0) }
let el = hits[idx - 1]
if act == "set-field" {
  AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, arg as CFString)
} else {
  AXUIElementPerformAction(el, kAXPressAction as CFString)
}
print("ok")
