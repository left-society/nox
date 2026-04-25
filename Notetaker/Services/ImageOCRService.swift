import Vision
import AppKit
import CoreGraphics
import ImageIO

/// Vision-backed text extraction from saved images. Async because
/// Vision gates a real ML model load that can take ~hundreds of
/// milliseconds the first time the recognizer runs in a process —
/// blocking the main actor on that warmup would visibly hitch the
/// context menu.
///
/// Used by the Images tab's `Copy text from image` context menu
/// item. Result lands as plain text on the system clipboard.
enum ImageOCRService {
    /// Runs Vision text recognition on the image at `url`. Returns
    /// every recognized line joined by newlines, or nil if no text
    /// was found (or the file couldn't be decoded as an image).
    static func extractText(from url: URL) async -> String? {
        guard let cgImage = loadCGImage(at: url) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                guard let results = req.results as? [VNRecognizedTextObservation] else {
                    cont.resume(returning: nil); return
                }
                let lines = results.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage)
            // Hop the actual perform off the main actor — VNImageRequestHandler
            // is synchronous and can take ~100-1000ms on the first call after
            // a cold start while the ML model is loaded into memory.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
