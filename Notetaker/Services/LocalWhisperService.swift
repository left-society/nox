import Foundation
import WhisperKit

/// On-device Whisper transcription via WhisperKit (Argmax's
/// Swift port that runs Whisper as a Core ML graph on the
/// Apple Neural Engine).
///
/// **Why local instead of OpenAI API**:
///   • Privacy — recordings never leave the user's machine
///   • Offline — works on planes, in spotty WiFi
///   • Latency — no network round-trip; on M2 Air `small.en`
///     transcribes ~3× faster than realtime, so a 10s recording
///     completes in ~3s with no upload time
///   • Cost — zero per-transcription cost
///
/// **Trade-off vs API**:
///   • Accuracy is slightly lower for `small.en` (~466 MB)
///     compared to OpenAI's `whisper-large-v3-turbo`. Real-world
///     gap on clean speech is usually invisible; the gap shows
///     on heavy accents, rare proper nouns, and noisy audio.
///   • The LLM-cleanup pass (Groq/OpenAI) still runs over the
///     local transcript when configured — keeps post-processing
///     quality identical regardless of the transcribe path.
///
/// **Adaptation strategy** (the "does it learn my voice" question):
///   The Whisper model itself is frozen — neither this nor the
///   API trains on user data. What DOES adapt is the **prompt
///   biasing layer**: the `prompt` parameter biases the decoder
///   toward specific words. Three sources stack into the prompt:
///     1. Personal vocabulary (Settings → Vocabulary list)
///     2. Auto-learned words from user corrections
///        (DictationCorrectionLearner observes edits)
///     3. Recent notes content (rolling 3-5 notes as context)
///   This is structurally identical to how Apple's own
///   on-device dictation gets better with use.
/// 2026-04-29: removed @MainActor isolation. WhisperKit's
/// `transcribe(audioPath:)` does heavy Core ML work on its own
/// dispatch queue, but if the calling actor is the main thread,
/// SwiftUI re-eval + animation timing got starved during long
/// transcriptions (user reported "2 hours for one sentence" —
/// which was actually the main thread being held by the @MainActor
/// isolation guarantee while the model was still loading async).
/// Now uses an `actor` for thread-safe state without main-thread
/// pinning, plus an internal `prepareTask` to coalesce concurrent
/// `prepare()` calls into a single load.
actor LocalWhisperService {

    /// Singleton — loading the WhisperKit pipeline takes ~2s
    /// (model decompression + ANE compilation), so we want
    /// exactly one instance per process.
    static let shared = LocalWhisperService()

    /// True once the model has finished loading and is ready
    /// to accept transcription requests.
    private(set) var isReady: Bool = false

    /// True while the model is downloading or compiling.
    private(set) var isLoading: Bool = false

    /// Last error, surfaced to the UI for diagnostics.
    private(set) var lastError: Error?

    /// Active WhisperKit pipeline. nil until `prepare()` resolves.
    private var pipeline: WhisperKit?

    /// In-flight prepare task — coalesces concurrent calls so we
    /// only load the model once even if multiple dictations
    /// trigger simultaneously. Without this, the second call
    /// would hit the `if isLoading { return }` short-circuit and
    /// throw `.notReady` even though the first call is still
    /// loading.
    private var prepareTask: Task<Void, Never>?

    /// Model size identifier. `openai_whisper-small.en` is the
    /// default — best accuracy/size tradeoff for English-only
    /// users. `tiny.en` is the bundled fallback (~75 MB) so the
    /// app always works offline even if `small.en` hasn't
    /// downloaded yet. `medium.en` is opt-in for users who
    /// want max accuracy and don't mind 1.4 GB.
    enum ModelSize: String, CaseIterable {
        case tiny = "openai_whisper-tiny.en"
        case base = "openai_whisper-base.en"
        case small = "openai_whisper-small.en"
        case medium = "openai_whisper-medium.en"

        var displayName: String {
            switch self {
            case .tiny: return "Tiny (75 MB)"
            case .base: return "Base (140 MB)"
            case .small: return "Small (466 MB)"
            case .medium: return "Medium (1.4 GB)"
            }
        }
    }

    /// User's selected model size. Read from UserDefaults so
    /// the choice survives relaunch. Synchronous because
    /// UserDefaults is thread-safe and we want callers to be
    /// able to read it without an `await`.
    nonisolated var preferredModel: ModelSize {
        let raw = UserDefaults.standard.string(forKey: "Notetaker.localWhisperModel") ?? ModelSize.small.rawValue
        return ModelSize(rawValue: raw) ?? .small
    }

    private init() {}

    // MARK: - Lifecycle

    /// Prepare the WhisperKit pipeline. Idempotent — repeat
    /// calls await the in-flight load instead of starting
    /// another one (the previous version's `if isLoading
    /// { return }` short-circuit caused the second caller to
    /// see `isReady == false` and throw `.notReady` even
    /// though loading was actually progressing).
    ///
    /// On first launch with `small.en` selected, this triggers
    /// a ~466 MB download from HuggingFace + a Core ML compile
    /// pass (~30-60s on M-series). After the first call, models
    /// are cached in `~/Documents/huggingface/...` and
    /// subsequent launches resolve in ~1-2s.
    func prepare() async {
        if isReady { return }
        // Coalesce concurrent calls into a single load.
        if let existing = prepareTask {
            await existing.value
            return
        }
        let task = Task {
            await self.runPrepare()
        }
        prepareTask = task
        await task.value
        prepareTask = nil
    }

    private func runPrepare() async {
        isLoading = true
        lastError = nil
        let model = preferredModel.rawValue
        let started = Date()
        do {
            let kit = try await WhisperKit(model: model)
            self.pipeline = kit
            self.isReady = true
            self.isLoading = false
            let dt = Date().timeIntervalSince(started)
            NSLog("Notetaker: LocalWhisper ready model=\(model) loadTime=\(String(format: "%.1f", dt))s")
        } catch {
            self.lastError = error
            self.isLoading = false
            NSLog("Notetaker: LocalWhisper FAILED to load \(model): \(error)")
        }
    }

    // MARK: - Transcription

    /// Transcribe an audio file using the loaded WhisperKit
    /// pipeline. Returns plain text — no JSON, no segments.
    ///
    /// `vocabularyPrompt` is the three-layer biasing string:
    /// settings vocab + auto-learned terms + recent notes
    /// context, joined into a Whisper-compatible prompt.
    /// Whisper interprets this as the "start of the transcript"
    /// and biases its decoder toward continuing in the same
    /// vocabulary + style.
    func transcribe(fileURL: URL, vocabularyPrompt: String?) async throws -> String {
        if !isReady {
            await prepare()
        }
        guard let pipeline = pipeline else {
            throw LocalWhisperError.notReady
        }

        var options = DecodingOptions()
        options.language = "en"
        options.temperature = 0

        if let prompt = vocabularyPrompt, !prompt.isEmpty,
           let tokenizer = pipeline.tokenizer {
            let encoded = tokenizer.encode(text: prompt)
            options.promptTokens = encoded
        }

        let started = Date()
        let results = try await pipeline.transcribe(
            audioPath: fileURL.path,
            decodeOptions: options
        )
        let dt = Date().timeIntervalSince(started)
        NSLog("Notetaker: LocalWhisper transcribe done in \(String(format: "%.2f", dt))s")

        let text = results.map { $0.text }.joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LocalWhisperError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Local Whisper model is still loading. Try again in a moment."
        }
    }
}
