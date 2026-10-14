import AppKit
import Security

/// Self-update from GitHub Releases.
///
/// Checks `releases/latest` on launch and every 24h. When it's newer, downloads the
/// release zip, verifies the new app is signed by the SAME identity as the running
/// one (our own designated requirement — rejects tampered / foreign builds, and
/// guarantees TCC grants carry over, since they're keyed to the signature), then
/// swaps the bundle in place and relaunches.
///
/// Only self-updates when running from an Applications folder, so a development
/// build (e.g. ./TaskbarPlus.app in the repo) is never overwritten.
final class Updater {

    private static let latestURL = URL(string: "https://api.github.com/repos/vinylred/TaskbarPlus/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Whether updates install without asking (Preferences → "Install updates
    /// automatically"). Read on each check.
    var automatic: () -> Bool = { true }

    private var timer: Timer?
    private var busy = false

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Installed where self-update is allowed (not a dev build).
    static var canSelfUpdate: Bool {
        let path = Bundle.main.bundlePath
        let dir = (path as NSString).deletingLastPathComponent
        return dir.hasSuffix("/Applications") && FileManager.default.isWritableFile(atPath: dir)
    }

    func start() {
        // Shortly after launch (don't compete with startup), then daily.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    /// `userInitiated`: from "Check for Updates…" — always reports the outcome and
    /// installs even if automatic updates are off.
    func check(userInitiated: Bool) {
        guard !busy else { return }
        guard Self.canSelfUpdate else {
            if userInitiated {
                report("Updates can only be installed when Taskbar Plus runs from your Applications folder.\n\n"
                       + "This copy is at \(Bundle.main.bundlePath).")
            }
            return
        }
        busy = true
        var req = URLRequest(url: Self.latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async { self?.handleLatest(data: data, error: error, userInitiated: userInitiated) }
        }.resume()
    }

    private func handleLatest(data: Data?, error: Error?, userInitiated: Bool) {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            busy = false
            if userInitiated { report("Couldn't reach GitHub to check for updates.\n\n\(error?.localizedDescription ?? "")") }
            return
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(latest, than: Self.currentVersion) else {
            busy = false
            if userInitiated { report("Taskbar Plus \(Self.currentVersion) is the latest version.") }
            return
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String) == "TaskbarPlus-\(latest).zip" }),
              let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString) else {
            busy = false
            if userInitiated { report("Version \(latest) is out, but its download isn't attached yet. Try again later.") }
            return
        }
        guard userInitiated || automatic() else { busy = false; return }
        download(url, version: latest, userInitiated: userInitiated)
    }

    private func download(_ url: URL, version: String, userInitiated: Bool) {
        URLSession.shared.downloadTask(with: url) { [weak self] file, _, error in
            // The temp file is deleted when this handler returns — move it first.
            let zip = FileManager.default.temporaryDirectory
                .appendingPathComponent("TaskbarPlus-update-\(UUID().uuidString).zip")
            let moved = file.flatMap { try? FileManager.default.moveItem(at: $0, to: zip) } != nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard moved else {
                    self.busy = false
                    if userInitiated { self.report("Downloading \(version) failed.\n\n\(error?.localizedDescription ?? "")") }
                    return
                }
                self.install(zip: zip, version: version, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func install(zip: URL, version: String, userInitiated: Bool) {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("TaskbarPlus-update-\(UUID().uuidString)")
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        // ditto preserves the signature and bundle structure (as release.sh packs it).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, staging.path]
        try? unzip.run()
        unzip.waitUntilExit()
        try? fm.removeItem(at: zip)
        let newApp = staging.appendingPathComponent("TaskbarPlus.app")
        guard unzip.terminationStatus == 0, fm.fileExists(atPath: newApp.path),
              Self.signedLikeMe(newApp),
              Bundle(url: newApp)?.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
            busy = false
            try? fm.removeItem(at: staging)
            if userInitiated {
                report("The \(version) download didn't pass verification (signature or version mismatch), "
                       + "so it wasn't installed. Download it manually from the GitHub Releases page.")
            }
            NSLog("TaskbarPlus: update \(version) rejected (signature/version check)")
            return
        }
        // Swap after we exit (can't replace a running bundle's files safely), then
        // relaunch. The old copy goes to the staging dir, cleaned up by the OS.
        let current = Bundle.main.bundlePath
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        /bin/mv "$1" "$2/Old.app" && /bin/mv "$3" "$1" || /bin/mv "$2/Old.app" "$1"
        /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
        /usr/bin/open "$1"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "swap", current, staging.path, newApp.path]
        do { try swap.run() } catch {
            busy = false
            if userInitiated { report("Couldn't start the installer: \(error.localizedDescription)") }
            return
        }
        NSLog("TaskbarPlus: installing \(version), relaunching")
        NSApp.terminate(nil)
    }

    /// The bundle at `url` satisfies the running app's own designated requirement
    /// (same identifier + same signing certificate).
    static func signedLikeMe(_ url: URL) -> Bool {
        var me: SecCode?
        var requirement: SecRequirement?
        var staticMe: SecStaticCode?
        var other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &other) == errSecSuccess, let other else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(other, flags, requirement) == errSecSuccess
    }

    /// "1.10.0" > "1.9.3" (numeric, component-wise; missing components are 0).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func report(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Taskbar Plus Updates"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
