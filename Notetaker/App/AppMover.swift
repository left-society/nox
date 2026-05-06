import AppKit

/// Relocate-to-/Applications helper. Modeled on the LetsMove pattern
/// (Andy Matuschak, Potion Factory) but written from scratch in Swift
/// without the deprecated `AuthorizationExecuteWithPrivileges` paths
/// the original used — those are Apple-deprecated, sandbox-incompatible,
/// and trip the notary's static analyzer in 2026.
///
/// Why this exists: the user feedback was "after I put [the app] in
/// the file manager, I have to open the app separately." A standard
/// drag-DMG flow lands the app in /Applications but doesn't auto-
/// open it; users have to navigate to /Applications and double-click.
/// And on the BAD path (where the user double-clicks straight from
/// the mounted DMG without dragging), macOS path-translocates the app
/// into a randomized read-only mount, breaking auto-update + TCC.
///
/// What this fixes:
///   • If we're running from /Volumes/<dmg>/, ~/Downloads/, ~/Desktop/,
///     or any path-translocated location → offer to move ourselves to
///     /Applications and relaunch.
///   • If we're already in /Applications → no-op.
///
/// The relaunched copy in /Applications is the SAME signed bundle —
/// codesign + notarization remain valid (TCC keys on bundle id +
/// Team ID + signing identifier, not on file path), and the user gets
/// a clean first launch from the canonical location.
///
/// Called from `applicationDidFinishLaunching` BEFORE
/// `onboardingManager.presentIfNeeded()` so the move (if it happens)
/// completes first. The move synchronously calls `NSApp.terminate`
/// and re-launches; onboarding will fire from the relaunched instance.
@MainActor
enum AppMover {

    /// Inspect the current launch path. If we're not in /Applications,
    /// offer to move + relaunch. Returns `true` IFF the move was
    /// performed (in which case the calling process is about to
    /// exit and the caller should bail out of further setup).
    @discardableResult
    static func relocateIfNeededAndRelaunch() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let bundlePath = bundleURL.path

        // Already in /Applications (system-wide) or ~/Applications
        // (per-user). Either is a "real install" location — no
        // relocation needed. We DON'T move from ~/Applications to
        // /Applications because the user may have intentionally
        // installed per-user (e.g. without admin privileges).
        if bundlePath.hasPrefix("/Applications/") {
            NSLog("nox: AppMover — already in /Applications, no relocation needed")
            return false
        }
        if bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/") {
            NSLog("nox: AppMover — already in ~/Applications, no relocation needed")
            return false
        }

        // Path-translocation detection. macOS 10.12+ randomizes the
        // path of apps run directly from a quarantined source (e.g.
        // double-clicking inside a mounted DMG without dragging
        // first). The translocated path looks like
        // /private/var/folders/.../AppTranslocation/XYZ/d/nox.app.
        // The bundle is read-only and CAN'T move itself by name —
        // but we can resolve the ORIGINAL path via
        // URL(fileURLWithFileSystemRepresentation:isDirectory:relativeTo:)
        // tricks, or just bail and tell the user to drag manually.
        //
        // Simpler: detect translocation, show a dialog explaining
        // the user needs to drag the app to /Applications first,
        // then quit. They re-mount and drag, our relocation code
        // doesn't run that path again.
        let translocated = bundlePath.contains("/AppTranslocation/")

        // Source-of-launch heuristics. Anything that's NOT in a
        // canonical install location AND NOT translocated is
        // candidate for our "move me" offer:
        //   • /Volumes/...           — running from a mounted DMG
        //   • ~/Downloads/...        — user dragged it out
        //   • ~/Desktop/...          — user dropped it on the desktop
        //   • /tmp, /private/tmp     — copy-pasted into staging
        let home = NSHomeDirectory()
        let candidatePrefixes = [
            "/Volumes/",
            "\(home)/Downloads/",
            "\(home)/Desktop/",
            "/tmp/",
            "/private/tmp/",
            "/private/var/folders/"   // covers AppTranslocation too
        ]
        let isCandidate = translocated || candidatePrefixes.contains { bundlePath.hasPrefix($0) }
        guard isCandidate else {
            // Some other location (e.g. the user keeps apps in
            // ~/Apps or /opt). Leave them alone — they know what
            // they're doing.
            NSLog("nox: AppMover — running from \(bundlePath); not a known temp location, skipping relocation prompt")
            return false
        }

        // Translocated path: we can't copy ourselves out of a
        // randomized read-only mount cleanly. Best path is to ask
        // the user to drag the .app to /Applications themselves.
        if translocated {
            return showTranslocationGuidance(bundleURL: bundleURL)
        }

        // Surface the move dialog. Default = Move; secondary = "Not
        // now" so the user can dismiss without committing if they're
        // testing. NSAlert.Style.informational because this isn't an
        // error — it's a one-time setup step.
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move nox to your Applications folder?"
        alert.informativeText = """
        nox is currently running from \(humanReadableSourceLocation(for: bundlePath)). Moving it to /Applications gives you:

          • A real install location so auto-update works.
          • A clean Spotlight + Launchpad entry.
          • The system permissions you grant will stick across updates.

        nox will move itself and relaunch automatically.
        """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not now")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            NSLog("nox: AppMover — user declined relocation")
            return false
        }

        // Perform the move. If anything fails, tell the user but
        // KEEP RUNNING — a half-failed move that aborts the launch
        // would leave them with no app running and a partially
        // copied bundle in /Applications.
        do {
            try performMoveAndRelaunch(from: bundleURL)
            return true
        } catch {
            NSLog("nox: AppMover — move failed: \(error)")
            let failureAlert = NSAlert()
            failureAlert.alertStyle = .warning
            failureAlert.messageText = "Couldn't move nox to Applications"
            failureAlert.informativeText = """
            \(error.localizedDescription)

            You can drag nox.app to /Applications manually instead. nox will keep running from its current location for now.
            """
            failureAlert.addButton(withTitle: "OK")
            failureAlert.runModal()
            return false
        }
    }

    /// Copy the bundle to /Applications and re-launch from there,
    /// then terminate this process.
    private static func performMoveAndRelaunch(from sourceURL: URL) throws {
        let fm = FileManager.default
        let destinationURL = URL(fileURLWithPath: "/Applications/\(sourceURL.lastPathComponent)")

        // If a previous version is at the destination (e.g. the user
        // had nox installed before and just downloaded a new DMG),
        // remove it. We've already verified we're running from a
        // non-/Applications path so we're not removing ourselves.
        if fm.fileExists(atPath: destinationURL.path) {
            // Try moveToTrash first — gives the user a recovery
            // path if something goes wrong. Falls back to
            // removeItem if Trash is unavailable (e.g. volume
            // doesn't support it).
            do {
                var trashedURL: NSURL?
                try fm.trashItem(at: destinationURL, resultingItemURL: &trashedURL)
                NSLog("nox: AppMover — moved old /Applications/nox.app to Trash")
            } catch {
                NSLog("nox: AppMover — trashItem failed (\(error)); falling back to removeItem")
                try fm.removeItem(at: destinationURL)
            }
        }

        // Copy the bundle. Don't use FileManager.copyItem with a
        // .bundle URL containing symlinks (Sparkle.framework, the
        // Updater.app inside it) — copyItem follows symlinks by
        // default which can corrupt nested signatures. We use
        // /usr/bin/cp -R which preserves them.
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-R", sourceURL.path, "/Applications/"]
        try cp.run()
        cp.waitUntilExit()

        guard cp.terminationStatus == 0 else {
            throw NSError(
                domain: "AppMover", code: Int(cp.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "cp exited with status \(cp.terminationStatus)"]
            )
        }

        // Sanity check the destination exists.
        guard fm.fileExists(atPath: destinationURL.path) else {
            throw NSError(
                domain: "AppMover", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Copy completed but \(destinationURL.path) is missing"]
            )
        }

        NSLog("nox: AppMover — bundle copied to \(destinationURL.path)")

        // Best-effort cleanup of the source. If it's on /Volumes/
        // (DMG mount) we DON'T touch it — the user will eject the
        // disk image themselves. For ~/Downloads/ and similar
        // user-writable locations, move the source to Trash so
        // the user doesn't end up with two copies.
        let sourcePath = sourceURL.path
        let onVolumes = sourcePath.hasPrefix("/Volumes/")
        if !onVolumes {
            do {
                var trashedURL: NSURL?
                try fm.trashItem(at: sourceURL, resultingItemURL: &trashedURL)
                NSLog("nox: AppMover — moved source bundle to Trash")
            } catch {
                NSLog("nox: AppMover — couldn't trash source (\(error)); leaving in place")
            }
        }

        // Relaunch from /Applications. NSWorkspace.openApplication is
        // the modern API; pre-macOS 13 we'd use the old launch APIs
        // but our minimum is macOS 13.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destinationURL, configuration: config) { _, error in
            if let error = error {
                NSLog("nox: AppMover — relaunch failed: \(error)")
            }
            // Whether or not the relaunch succeeded, terminate this
            // instance — leaving two copies of nox running would be
            // worse than no copies. Dispatch async so the
            // openApplication callback gets to log first.
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }

        // Sleep briefly so openApplication has a chance to fire
        // before terminate races it. 250ms is enough for the
        // CFRunLoop to dispatch the launch.
        Thread.sleep(forTimeInterval: 0.25)
    }

    /// Path-translocation case. Show an alert explaining the user
    /// needs to drag the .app from the DMG to /Applications
    /// themselves, then quit so they can do it.
    private static func showTranslocationGuidance(bundleURL: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Drag nox to Applications first"
        alert.informativeText = """
        macOS opened nox in a sandboxed location, which means auto-update and saved permissions won't work.

        Please:
          1. Quit nox.
          2. Open the nox disk image again.
          3. Drag nox.app into the Applications folder.
          4. Open it from /Applications.

        nox will quit now so you can do this.
        """
        alert.addButton(withTitle: "Quit nox")
        alert.runModal()
        NSApp.terminate(nil)
        return true
    }

    /// Pretty-print the current launch source for the move dialog so
    /// the user can see WHERE they're moving FROM. "/Volumes/nox 1.9.4/"
    /// reads better than the full bundle path.
    private static func humanReadableSourceLocation(for path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix("/Volumes/") {
            // Extract the volume name (path component immediately
            // after /Volumes/).
            let trimmed = String(path.dropFirst("/Volumes/".count))
            let volume = trimmed.split(separator: "/").first.map(String.init) ?? "the disk image"
            return "the disk image “\(volume)”"
        }
        if path.hasPrefix("\(home)/Downloads/") {
            return "your Downloads folder"
        }
        if path.hasPrefix("\(home)/Desktop/") {
            return "your Desktop"
        }
        return path
    }
}
