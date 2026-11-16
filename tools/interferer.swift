import AppKit
import CoreGraphics

// interferer: one trait of another app at a time, to find which one makes a space switch land wrong.
// Run it, then `space-probe loop` in another shell, then quit it (Ctrl-C).
//   interferer key-tap       an active (default) keyDown tap at the session, head insert, passing everything
//   interferer key-listen    the same tap, listen-only
//   interferer panel         a floating panel on every desktop (canJoinAllSpaces), not activating
//   interferer panel-front   the same panel, and this app activated so it is the front app
//   interferer front         a normal window, this app activated, no panel

let mode = CommandLine.arguments.dropFirst().first ?? "panel"
let app = NSApplication.shared
app.setActivationPolicy(["front", "panel-front", "app-mini"].contains(mode) ? .regular : .accessory)

var tapPort: CFMachPort?

func installKeyTap(listenOnly: Bool) {
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let callback: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
    guard let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: listenOnly ? .listenOnly : .defaultTap,
        eventsOfInterest: mask, callback: callback, userInfo: nil
    ) else {
        print("tapCreate failed (Accessibility / Input Monitoring?)")
        exit(1)
    }
    tapPort = port
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
}

var keep: [NSWindow] = []

func showPanel() {
    let panel = NSPanel(
        contentRect: NSRect(x: 80, y: 80, width: 220, height: 60),
        styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false
    )
    panel.title = "interferer"
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.orderFrontRegardless()
    keep.append(panel)
}

func showWindow() {
    let window = NSWindow(
        contentRect: NSRect(x: 320, y: 80, width: 220, height: 60),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.title = "interferer"
    window.makeKeyAndOrderFront(nil)
    keep.append(window)
}

switch mode {
case "key-tap": installKeyTap(listenOnly: false)
case "key-listen": installKeyTap(listenOnly: true)
case "panel": showPanel()
case "panel-front":
    showPanel()
    app.activate(ignoringOtherApps: true)
case "front":
    showWindow()
    app.activate(ignoringOtherApps: true)
case "app-mini":
    // An app's normal window on this desktop, and its small floating panel on every desktop.
    showWindow()
    showPanel()
    app.activate(ignoringOtherApps: true)
default:
    print("unknown mode \(mode)")
    exit(64)
}
print("interferer \(mode) running, pid \(getpid())")
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
app.run()
