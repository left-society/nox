import Foundation

/// Lightweight one-shot routing layer for dictation transcripts.
///
/// Default flow: Fn key → record → transcribe → DictationPasteHelper
/// types the text into whatever app is frontmost.
///
/// Override flow: a view inside Notetaker (the note editor's mic
/// button, the clipboard tab's mic button, etc.) sets
/// `pendingDestination` to a closure that handles the transcript
/// itself — typically by inserting at the active NSTextView's
/// cursor — and posts `.startDictation`. AppDelegate starts the
/// recorder; when the transcript lands, it checks
/// `pendingDestination` first and routes there if non-nil
/// (clearing it to make this a one-shot).
///
/// This way the same dictation pipeline (Fn-key path AND in-app
/// mic buttons) reuses the orchestrator/recorder/pill UI, just
/// with different terminal sinks.
@MainActor
enum DictationRouter {
    /// Set by an in-app mic button BEFORE posting `.startDictation`.
    /// AppDelegate's `onTranscriptReady` consumes and clears this
    /// after delivery. nil = system-wide auto-type.
    static var pendingDestination: ((String) -> Void)?
}

extension Notification.Name {
    /// Posted by an in-app mic button to ask AppDelegate to start
    /// dictation. The destination MUST be set on
    /// `DictationRouter.pendingDestination` before posting; this
    /// notification carries no userInfo.
    static let notetakerStartDictation = Notification.Name("notetakerStartDictation")

    /// Posted by AppDelegate every time the dictation state changes
    /// (idle → recording → transcribing → idle). userInfo["isRecording"]
    /// is a Bool indicating whether the orchestrator is currently
    /// capturing audio. Views (mic buttons) observe this to mirror
    /// state — show "stop" while recording, "mic" otherwise.
    static let notetakerDictationStateChanged = Notification.Name("notetakerDictationStateChanged")
}
