import AppKit
import ApplicationServices
import CDockSwipe
import ServiceManagement

/// `--unregister-login-item` takes the app out of the login items, then exits. For an uninstall, or before
/// the app is renamed or moved. Only the app itself can do this, so it is a mode of the app.
if CommandLine.arguments.contains("--unregister-login-item") {
    do {
        try SMAppService.mainApp.unregister()
        print("login item removed")
    } catch {
        print("login item not removed: \(error.localizedDescription)")
    }
    exit(0)
}

/// `Interspace --diagnose` prints what the app can see, then exits. It shows no prompt and changes nothing.
private func diagnose() {
    let version = ProcessInfo.processInfo.operatingSystemVersionString
    print("macOS: \(version)")
    print("IOHID payload required (macOS 27+): \(ds_requires_event_augmentation())")
    print("Accessibility access: \(AXIsProcessTrusted())")
    print("Screen Recording access: \(CGPreflightScreenCaptureAccess())")

    let monitor = MultitouchMonitor.shared
    print("MultitouchSupport loaded: \(monitor.isAvailable)")
    print("Multitouch devices: \(monitor.start() ? monitor.deviceCount : 0)")
    monitor.stop()

    print("Space list API: \(Spaces.isAvailable)")
    for screen in NSScreen.screens {
        let size = "\(Int(screen.frame.width))x\(Int(screen.frame.height)) @\(screen.backingScaleFactor)x"
        if let layout = Spaces.layout(for: screen) {
            print("Screen \(screen.displayID) (\(size)): \(layout.spaceIDs.count) spaces, current index \(layout.currentIndex), ids \(layout.spaceIDs)")
        } else {
            print("Screen \(screen.displayID) (\(size)): no space information")
        }
    }
}

if CommandLine.arguments.contains("--diagnose") {
    diagnose()
    exit(0)
}

#if DEBUG
/// Only in a debug build, for a test of the update with no release and no window:
/// `Interspace --test-check` asks GitHub for the newest release.
/// `Interspace --test-install <dmg> <app> <version>` installs the app of the disk image over `<app>`,
/// as if `<app>` had `<version>`.
if CommandLine.arguments.contains("--test-check") {
    Task {
        do {
            let release = try await UpdateInstaller.latestRelease()
            print("release: \(release.map { "\($0.version) \($0.dmg)" } ?? "none"), this app: \(UpdateInstaller.currentVersion), a release build: \(UpdateInstaller.isReleaseBuild)")
        } catch {
            print("failed: \(error)")
        }
        exit(0)
    }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of: "--test-install"), CommandLine.arguments.count > index + 3 {
    let arguments = CommandLine.arguments
    do {
        try UpdateInstaller.install(
            dmg: URL(fileURLWithPath: arguments[index + 1]),
            over: URL(fileURLWithPath: arguments[index + 2]),
            newerThan: arguments[index + 3]
        )
        print("installed")
    } catch {
        print("refused: \(error)")
    }
    exit(0)
}
#endif

// Two instances would both post a swipe and switch two spaces.
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty, !CommandLine.arguments.contains("--replace") {
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
