import AppKit

/// Pulls the active-tab URL out of the frontmost browser by simulating
/// ⌘L (focus address bar) + ⌘C (copy) — then reads the clipboard.
///
/// This deliberately avoids AppleScript / Apple Events because modern macOS
/// silently denies cross-app automation (TCC error -1743) when the user
/// hasn't explicitly enabled the app under Privacy & Security > Automation.
/// The keystroke approach only needs Accessibility permission, which is a
/// single toggle any user can flip.
///
/// Works with every browser that has an address bar — no per-browser
/// AppleScript dictionary required.
enum BrowserURLService {
    /// Browsers whose frontmost address bar reliably holds the current tab
    /// URL as a selectable, copyable string. We refuse to drive keystrokes
    /// into non-browser apps to avoid clobbering the user's input.
    private static let browserBundleIDs: Set<String> = [
        // Chromium family
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "ru.yandex.desktop.yandex-browser",
        "com.naver.Whale",

        // WebKit family
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.kagi.kagimacOS",
        "com.kagi.Orion",
        "com.kagi.OrionRC",

        // Arc & friends
        "company.thebrowser.Browser",

        // Gecko family
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "io.gitlab.librewolf-community",
        "org.mozilla.tor",
        "com.zen-browser.zen"
    ]

    /// Per BUG-018 fix: this function is now `async`. It used to
    /// block the main thread for up to 400ms in a `usleep`-driven
    /// poll loop while waiting for the browser to copy the URL
    /// to the clipboard — visible UI freeze and beach-ball when
    /// the user hit ⌥⌘V, and a contributing factor to the
    /// "Notetaker is laggy" reports. Replacing the inner busy-
    /// wait with `Task.sleep` lets the UI paint during the
    /// 400ms window. Callers must `await` the result; the only
    /// caller (AppDelegate.grabCurrentBrowserTab) wraps the
    /// invocation in `Task { @MainActor in ... }`.
    static func currentTabURL() async -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else {
            NSLog("Notetaker: currentTabURL no frontmost app")
            return nil
        }
        guard browserBundleIDs.contains(bundleID) else {
            NSLog("Notetaker: frontmost not a browser, bundleID=\(bundleID)")
            return nil
        }

        // Make sure we can actually post keystrokes & read the AX tree.
        // First call prompts the user and returns false until they toggle
        // us on under Privacy & Security > Accessibility.
        if !AXIsProcessTrusted() {
            NSLog("Notetaker: not AX-trusted — requesting prompt")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return nil
        }

        // First try: the link under the mouse cursor. On Instagram feeds,
        // TikTok "For You", YouTube thumbnails, X timelines, etc. each
        // video is wrapped in an <a> tag pointing at its dedicated public
        // URL — exactly what yt-dlp needs. The URL bar, by contrast, only
        // holds the feed URL and can't tell us which video is being
        // watched. Checking the AX element under the cursor is the only
        // way to disambiguate.
        if let hovered = urlUnderMouse() {
            NSLog("Notetaker: got URL from mouse hover=\(hovered)")
            return hovered
        }

        let pb = NSPasteboard.general

        // Snapshot the clipboard so we can put it back the way we found it.
        // Users would be furious if grabbing a tab URL silently erased the
        // code snippet they had on their clipboard.
        let snapshot: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
        let startCount = pb.changeCount

        // ⌘L focuses the URL bar and auto-selects its contents in every
        // major browser; ⌘C copies the selection.
        postCmd(keyCode: kVK_ANSI_L)
        // Browsers need a tick to finish the selection before ⌘C.
        // 30ms via Task.sleep, NOT usleep — usleep blocked the main
        // thread, which the user reported as a visible freeze.
        try? await Task.sleep(nanoseconds: 30_000_000)
        postCmd(keyCode: kVK_ANSI_C)

        // Wait for the pasteboard changeCount to tick — that means ⌘C has
        // landed and written a new item. Cap at 400ms so a stuck browser
        // doesn't hang the hotkey. `Task.sleep` yields the main thread
        // back to the runloop between polls instead of blocking it.
        let deadline = Date().addingTimeInterval(0.4)
        while pb.changeCount == startCount && Date() < deadline {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }

        let raw = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Put the user's original clipboard back.
        pb.clearContents()
        if !snapshot.isEmpty {
            let items: [NSPasteboardItem] = snapshot.map { dict in
                let item = NSPasteboardItem()
                for (type, data) in dict {
                    item.setData(data, forType: type)
                }
                return item
            }
            pb.writeObjects(items)
        }

        guard let raw = raw, !raw.isEmpty else {
            NSLog("Notetaker: pasteboard empty after ⌘L⌘C")
            return nil
        }
        guard let url = URL(string: raw),
              (url.scheme == "http" || url.scheme == "https")
        else {
            NSLog("Notetaker: URL bar contents don't parse: \(raw)")
            return nil
        }
        NSLog("Notetaker: got URL=\(url.absoluteString)")
        return url.absoluteString
    }

    /// Query the AX element under the mouse cursor for an `AXURL`
    /// attribute. On Instagram / TikTok / YouTube / X feeds each visible
    /// video is wrapped in an `<a>` tag whose AXURL is the dedicated
    /// public URL for that video. Walking up a few levels catches cases
    /// where the hit-test lands on an inner `<img>` / `<span>`.
    private static func urlUnderMouse() -> String? {
        let nsPoint = NSEvent.mouseLocation
        // NSEvent uses Cocoa coords (origin bottom-left of primary screen).
        // AX uses Quartz coords (origin top-left of primary screen). Flip Y
        // using the primary screen's height — not the screen the cursor is on.
        guard let primary = NSScreen.screens.first else { return nil }
        let axY = primary.frame.height - nsPoint.y
        let axX = nsPoint.x

        let sys = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(sys, Float(axX), Float(axY), &elementRef)
        guard hitResult == .success, var current = elementRef else {
            NSLog("Notetaker: urlUnderMouse hit-test failed code=\(hitResult.rawValue)")
            return nil
        }

        // Walk up. A depth of 12 comfortably covers the nested
        // <a><div><img> structure used by every major feed.
        for _ in 0..<12 {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXURLAttribute as CFString, &raw) == .success,
               let value = raw {
                if let url = value as? URL,
                   url.scheme == "http" || url.scheme == "https" {
                    return url.absoluteString
                }
                if let str = value as? String,
                   let url = URL(string: str),
                   url.scheme == "http" || url.scheme == "https" {
                    return url.absoluteString
                }
            }
            var parentRaw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRaw) == .success,
                  let parent = parentRaw,
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            current = parent as! AXUIElement
        }
        return nil
    }

    private static func postCmd(keyCode: Int32) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// Carbon virtual key codes. These are the canonical values from
// <HIToolbox/Events.h> and have been stable since OS X 10.0.
private let kVK_ANSI_L: Int32 = 0x25
private let kVK_ANSI_C: Int32 = 0x08
