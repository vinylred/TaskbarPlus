import AppKit
import ApplicationServices

/// Accessibility / Screen Recording status, explained to the user and fixable in
/// one click.
///
/// The trap this exists for: TCC grants are keyed to the code signature, so after
/// installing a differently-signed build (e.g. an older ad-hoc release → a newer
/// one), System Settings still shows TaskbarPlus switched ON while the grant no
/// longer applies — and nothing tells the user. "Fix…" therefore RESETS our TCC
/// entry first (`tccutil reset`), re-registers the app, and opens the right pane, so
/// the user only has to switch it on.
final class Permissions {

    enum Kind: CaseIterable {
        case accessibility, screenRecording

        var title: String {
            switch self {
            case .accessibility:   return "Accessibility"
            case .screenRecording: return "Screen Recording"
            }
        }
        /// What breaks without it (shown in the menu and the launch alert).
        var consequence: String {
            switch self {
            case .accessibility:
                return "maximised windows aren't fitted above the bar, and clicking a window button can't raise or close that specific window"
            case .screenRecording:
                return "window buttons show app names instead of window titles"
            }
        }
        fileprivate var tccService: String {
            switch self {
            case .accessibility:   return "Accessibility"
            case .screenRecording: return "ScreenCapture"
            }
        }
        fileprivate var settingsURL: URL {
            let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        }
    }

    /// Called on the main thread when the set of missing permissions changes.
    var onChange: (() -> Void)?

    private(set) var missing: [Kind] = []
    private var poll: Timer?
    private static let suppressAlertKey = "SuppressPermissionAlert"

    func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility:   return AXIsProcessTrusted()
        // Only flips to true after a relaunch (macOS applies it to new processes).
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    /// Start tracking; shows the explanatory alert if anything is missing.
    func start() {
        refresh()
        // Cheap check; picks up a grant made in System Settings within ~2s.
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        if !missing.isEmpty { showLaunchAlertIfNeeded() }
    }

    private func refresh() {
        let now = Kind.allCases.filter { !isGranted($0) }
        guard now != missing else { return }
        missing = now
        onChange?()
    }

    /// Reset our (possibly stale) TCC entry, re-register so TaskbarPlus appears in the
    /// list, and open the matching System Settings pane — the user just switches it on.
    func fix(_ kind: Kind) {
        if let bundleID = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", kind.tccService, bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }
        switch kind {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(kind.settingsURL)
        refresh()
    }

    /// Relaunch the app (Screen Recording only takes effect in a new process).
    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func showLaunchAlertIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.suppressAlertKey) else { return }
        // Let launch settle (bars up) before showing a modal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let first = self.missing.first else { return }
            let alert = NSAlert()
            alert.messageText = "Taskbar Plus needs permission"
            alert.informativeText = self.missing.map { "• \($0.title): without it, \($0.consequence)." }
                .joined(separator: "\n\n")
                + "\n\nClick Fix, then switch Taskbar Plus ON in the System Settings page that opens. "
                + "(If it already looks ON there, that's left over from an older version — Fix clears it.)"
                + "\n\nYou can do this later from the Taskbar Plus menu-bar icon."
            alert.addButton(withTitle: "Fix \(first.title)…")
            alert.addButton(withTitle: "Later")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show this at launch"
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Self.suppressAlertKey)
            }
            if response == .alertFirstButtonReturn { self.fix(first) }
        }
    }
}
