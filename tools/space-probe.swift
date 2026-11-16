import AppKit
import CoreGraphics

// space-probe: a measurable loop for "the space switch lands on the wrong desktop".
//   space-probe state          the desktops, the current one, the front app, windows on every desktop
//   space-probe loop [N] [ms]  N steps right then N left with ctrl+arrow, ms apart; one line per step,
//                              then "wrong X of Y". Exit 1 when any step landed wrong.

typealias MainConnectionFn = @convention(c) () -> Int32
typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?
typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
let mainConnection = unsafeBitCast(dlsym(rtldDefault, "CGSMainConnectionID")!, to: MainConnectionFn.self)
let copyManaged = unsafeBitCast(dlsym(rtldDefault, "CGSCopyManagedDisplaySpaces")!, to: CopyManagedDisplaySpacesFn.self)
let copySpacesForWindows = unsafeBitCast(dlsym(rtldDefault, "CGSCopySpacesForWindows")!, to: CopySpacesForWindowsFn.self)

struct Layout {
    let ids: [UInt64]
    let kinds: [Int]
    let current: Int
}

/// The display under the cursor's spaces (the first display when only one list exists).
func layout() -> Layout? {
    guard let displays = copyManaged(mainConnection(), nil)?.takeRetainedValue() as? [[String: Any]],
          let entry = displays.first,
          let spaces = entry["Spaces"] as? [[String: Any]] else { return nil }
    let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
    let kinds = spaces.map { ($0["type"] as? NSNumber)?.intValue ?? -1 }
    guard let currentID = ((entry["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value,
          let index = ids.firstIndex(of: currentID) else { return nil }
    return Layout(ids: ids, kinds: kinds, current: index)
}

func frontApp() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
}

/// Windows that are on more than one desktop, or on none of the normal ones: the suspects.
func stickyWindows(desktops: Int) -> [String] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    var out: [String] = []
    for info in list {
        guard let number = info[kCGWindowNumber as String] as? Int,
              let layer = info[kCGWindowLayer as String] as? Int,
              let owner = info[kCGWindowOwnerName as String] as? String,
              owner != "Window Server", owner != "Dock" else { continue }
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        guard (bounds["Width"] ?? 0) > 1, (bounds["Height"] ?? 0) > 1 else { continue }
        let spaces = copySpacesForWindows(mainConnection(), 7, [NSNumber(value: number)] as CFArray)?
            .takeRetainedValue() as? [NSNumber] ?? []
        if spaces.count > 1 || (spaces.count == 1 && spaces[0].uint64Value == 0) {
            let name = info[kCGWindowName as String] as? String ?? ""
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            out.append("\(owner) #\(number) layer \(layer) spaces \(spaces.count) onscreen \(onScreen) \"\(name)\"")
        }
    }
    return out
}

func post(arrowRight: Bool) {
    let key: CGKeyCode = arrowRight ? 124 : 123
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
        event.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        event.post(tap: .cghidEventTap)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "state" {
case "state":
    guard let current = layout() else { print("no space list"); exit(2) }
    print("desktops \(current.ids.count) kinds \(current.kinds) current \(current.current) front \(frontApp())")
    print("trusted for posting: \(AXIsProcessTrusted())")
    for line in stickyWindows(desktops: current.ids.count) { print("  sticky: \(line)") }
case "loop":
    let steps = arguments.count > 1 ? Int(arguments[1]) ?? 3 : 3
    let gap = arguments.count > 2 ? Double(arguments[2]) ?? 900 : 900
    guard let start = layout() else { print("no space list"); exit(2) }
    let last = start.ids.count - 1
    var expected = start.current
    var wrong = 0
    var total = 0
    let plan = Array(repeating: true, count: steps) + Array(repeating: false, count: steps)
    for right in plan {
        let before = layout()?.current ?? -1
        expected = right ? min(expected + 1, last) : max(expected - 1, 0)
        post(arrowRight: right)
        Thread.sleep(forTimeInterval: gap / 1000)
        let after = layout()?.current ?? -1
        total += 1
        let ok = after == expected
        if !ok {
            wrong += 1
            expected = after
        }
        print("\(right ? "→" : "←") \(before) → \(after) expected \(ok ? "ok" : "WRONG") front \(frontApp())")
    }
    print("wrong \(wrong) of \(total)")
    exit(wrong == 0 ? 0 : 1)
default:
    print("usage: space-probe state | loop [N] [ms]")
    exit(64)
}
