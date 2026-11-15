import AppKit
import os
import Security

private let log = Logger(subsystem: "com.cnrad.interspace", category: "update")

/// A release on GitHub.
struct Release {
    let version: String
    let dmg: URL
    let page: URL
}

enum UpdateError: Error {
    /// GitHub gave no answer, or one that is not a release.
    case noAnswer(String)
    /// The release has no `Interspace.dmg`.
    case noDownload
    /// The app in the download does not have the signature of a release, or is not newer than this one.
    case notVerified
    /// The app is in a place that cannot be written to.
    case cannotReplace(String)
}

/// The steps of an update that show nothing. `Updater` calls them and talks to the user.
enum UpdateInstaller {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/cnrad/interspace/releases/latest")!
    private static let downloadName = "Interspace.dmg"

    /// What the signature of a release must be: the identity that scripts/dmg.sh signs with.
    /// The download is installed only if it satisfies this. So a release that someone else put on
    /// GitHub is refused, and a copy that was built from source (it has its own identity) does not
    /// replace itself with a release. scripts/dmg.sh reads the hash from this line.
    private static let releaseRequirementText =
        #"identifier "com.cnrad.interspace" and certificate leaf = H"0a3f91d73bf5d632ac8bdbd186fadaba35258f55""#

    private static let releaseRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        SecRequirementCreateWithString(releaseRequirementText as CFString, [], &requirement)
        return requirement
    }()

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when this running copy is a release, and not a copy that was built from source.
    static let isReleaseBuild: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code, let releaseRequirement else { return false }
        return SecCodeCheckValidity(code, [], releaseRequirement) == errSecSuccess
    }()

    static func isNewer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// The newest release. `nil` when the project has no release.
    static func latestRelease() async throws -> Release? {
        struct Answer: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }

        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.noAnswer(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200, let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw UpdateError.noAnswer("GitHub answered with status \(status).")
        }
        guard let asset = answer.assets.first(where: { $0.name == downloadName }),
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com"
        else { throw UpdateError.noDownload }

        let tag = answer.tag_name
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, dmg: asset.browser_download_url, page: answer.html_url)
    }

    /// Downloads the disk image of `release` into a new folder that only this user can read.
    /// The caller deletes the folder of the file.
    static func download(_ release: Release) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("interspace-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let (file, response) = try await session.download(from: release.dmg)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.noAnswer("The download did not start.")
            }
            let dmg = folder.appendingPathComponent(downloadName)
            try FileManager.default.moveItem(at: file, to: dmg)
            return dmg
        } catch let error as UpdateError {
            try? FileManager.default.removeItem(at: folder)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw UpdateError.noAnswer(error.localizedDescription)
        }
    }

    /// Puts the app from `dmg` in the place of `target`. Before that, the copy that will be installed
    /// must have the signature of a release and a version that is newer than `current`.
    /// It blocks, so do not call it on the main thread.
    static func install(dmg: URL, over target: URL, newerThan current: String) throws {
        let files = FileManager.default
        let mount = dmg.deletingLastPathComponent().appendingPathComponent("mount")
        do {
            try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        } catch {
            throw UpdateError.notVerified
        }
        defer { try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        let source = mount.appendingPathComponent(target.lastPathComponent)
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw UpdateError.notVerified }

        // A folder on the volume of the app, so the last step is a rename and not a copy.
        let staging: URL
        do {
            staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        } catch {
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
        defer { try? files.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent)
        do {
            try files.copyItem(at: source, to: staged)
        } catch {
            throw UpdateError.cannotReplace(error.localizedDescription)
        }

        // The copy is examined, not the disk image: it is the copy that will run.
        guard isRelease(staged) else {
            log.error("the download does not have the signature of a release")
            throw UpdateError.notVerified
        }
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard let version = info?["CFBundleShortVersionString"] as? String, isNewer(version, than: current) else {
            log.error("the download is not newer than this app")
            throw UpdateError.notVerified
        }

        do {
            _ = try files.replaceItemAt(target, withItemAt: staged)
        } catch {
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
        log.notice("installed \(version, privacy: .public)")
    }

    /// True when the app at `url` is complete, not changed, and has the signature of a release.
    static func isRelease(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code, let releaseRequirement
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, releaseRequirement) == errSecSuccess
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
    }
}

/// "Check for Updates…" in the menu. The app speaks to GitHub only when the user chooses it.
/// All of it runs on the main thread.
final class Updater {
    private enum Activity {
        case idle, checking, downloading, installing
    }

    private static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/cnrad/interspace/main/scripts/install.sh | bash"

    private var activity = Activity.idle
    /// Opens the app again. After an install, the app that opens is the new one.
    var relaunch: (() -> Void)?

    var isBusy: Bool {
        activity != .idle
    }

    var menuTitle: String {
        switch activity {
        case .idle: return "Check for Updates…"
        case .checking: return "Checking for Updates…"
        case .downloading: return "Downloading Update…"
        case .installing: return "Installing Update…"
        }
    }

    func check() {
        guard !isBusy else { return }
        activity = .checking
        Task { @MainActor in
            defer { activity = .idle }
            let current = UpdateInstaller.currentVersion
            let release: Release?
            do {
                release = try await UpdateInstaller.latestRelease()
            } catch {
                show(error, page: nil)
                return
            }
            guard let release, UpdateInstaller.isNewer(release.version, than: current) else {
                inform("Interspace is up to date", "Version \(current) is the newest version.")
                return
            }
            guard UpdateInstaller.isReleaseBuild else {
                offerInstallCommand(for: release)
                return
            }
            guard ask(
                "Interspace \(release.version) is available",
                "You have version \(current). Interspace downloads the update, installs it, and opens again.",
                confirm: "Install Update", cancel: "Not Now"
            ) else { return }

            // The app is replaced where it is. A copy that runs from the disk image or from a folder
            // that macOS keeps read-only cannot be replaced.
            let target = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                show(UpdateError.cannotReplace("Move Interspace to the Applications folder, open it from there, and try again."), page: release.page)
                return
            }

            do {
                activity = .downloading
                let dmg = try await UpdateInstaller.download(release)
                defer { try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent()) }
                activity = .installing
                try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.install(dmg: dmg, over: target, newerThan: current)
                }.value
            } catch {
                show(error, page: release.page)
                return
            }
            relaunch?()
        }
    }

    /// A copy that was built from source has the signature of its own Mac. The two permissions are
    /// tied to that signature, so a release cannot take its place. The install command builds the new one.
    private func offerInstallCommand(for release: Release) {
        let copy = ask(
            "Interspace \(release.version) is available",
            "This copy of Interspace was built on this Mac, so it updates with the install command. "
                + "Run it in Terminal:\n\n\(Self.installCommand)",
            confirm: "Copy Command", cancel: "Not Now"
        )
        guard copy else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }

    private func show(_ error: Error, page: URL?) {
        log.error("\(String(describing: error), privacy: .public)")
        let title: String
        let text: String
        switch error {
        case UpdateError.noAnswer(let reason):
            title = "Interspace couldn’t check for updates"
            text = reason
        case UpdateError.noDownload:
            title = "Interspace couldn’t check for updates"
            text = "The newest release has no download for this app."
        case UpdateError.notVerified:
            title = "The update was not installed"
            text = "The download is not a release of Interspace that this app can trust. Nothing was changed."
        case UpdateError.cannotReplace(let reason):
            title = "The update was not installed"
            text = reason
        default:
            title = "The update was not installed"
            text = error.localizedDescription
        }
        guard let page else {
            inform(title, text)
            return
        }
        if ask(title, text, confirm: "Open Download Page", cancel: "OK") {
            NSWorkspace.shared.open(page)
        }
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func ask(_ title: String, _ text: String, confirm: String, cancel: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
