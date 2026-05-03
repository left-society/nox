import AppKit

/// Wraps `NSSharingService(named: .sendViaAirDrop)` with a small API
/// surface tailored for the notch's drop picker.
///
/// Implementation note: NSSharingService is the same primitive Finder
/// uses when you right-click → Share → AirDrop. macOS shows its
/// native receiver picker (Bluetooth/WiFi peer discovery, etc.) — we
/// don't reimplement any of that. The service runs from `.accessory`
/// apps without entitlements.
///
/// Reference patterns: Apple's NSSharingService docs, Dropover's
/// "Instant Actions" feature (which exposes the same AirDrop service
/// behind a drop-zone UI).
@MainActor
enum AirDropService {

    /// Send `urls` via AirDrop. macOS shows its native receiver
    /// picker; we have no UI of our own here.
    ///
    /// Returns `false` if AirDrop refuses to handle the items
    /// (offline, no compatible peers in range, urls empty, etc.) so
    /// the caller can fall back to a message or the Save flow.
    @discardableResult
    static func send(urls: [URL]) -> Bool {
        guard !urls.isEmpty else {
            NSLog("Notetaker: AirDropService.send — no URLs supplied")
            return false
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            NSLog("Notetaker: AirDropService.send — service unavailable")
            return false
        }
        // canPerform() pre-flights the items. If macOS isn't going to
        // accept them (e.g., the file disappeared between drag and
        // drop), better to know now than to enqueue a sheet that
        // immediately errors.
        guard service.canPerform(withItems: urls) else {
            NSLog("Notetaker: AirDropService.send — canPerform=false for \(urls.count) item(s)")
            return false
        }
        NSLog("Notetaker: AirDropService.send → \(urls.count) item(s)")
        service.perform(withItems: urls)
        return true
    }

    /// Convenience: AirDrop a single URL (most drag-from-Finder
    /// drops are single files).
    @discardableResult
    static func send(url: URL) -> Bool {
        send(urls: [url])
    }

    /// AirDrop arbitrary data by writing to a temp file first. Used
    /// when the drag carries raw image bytes (e.g. a browser image
    /// dragged from Safari) rather than a file URL.
    ///
    /// Caller passes a sensible filename (e.g. "image.png") — we
    /// derive the extension and write into the system temp dir. The
    /// temp file is left in place after the AirDrop sheet appears;
    /// macOS reads it during the transfer and the OS cleans up
    /// `/tmp` automatically.
    @discardableResult
    static func send(data: Data, suggestedFilename: String) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
        let safeName = suggestedFilename.isEmpty ? "shared" : suggestedFilename
        let url = tempDir.appendingPathComponent(safeName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Notetaker: AirDropService.send(data:) — write failed: \(error.localizedDescription)")
            return false
        }
        return send(url: url)
    }
}
