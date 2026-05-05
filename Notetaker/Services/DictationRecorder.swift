import AVFoundation
import Foundation

/// Captures microphone audio for the dictation pipeline. Writes a
/// 16 kHz mono PCM16 WAV file to a temp directory; that file gets
/// uploaded to the transcription API as multipart/form-data.
///
/// Why 16 kHz mono PCM16:
///   • Whisper / OpenAI-compatible transcription endpoints (Groq's
///     `whisper-large-v3-turbo` included) downsample to 16 kHz mono
///     internally, so anything higher just increases upload size for
///     no quality gain.
///   • Stereo 48 kHz at 24-bit float would be ~12 MB/min — slow to
///     upload, slow to transcribe. PCM16 mono 16 kHz is ~1.9 MB/min
///     — sub-second upload on any reasonable connection.
///   • PCM16 (Int16) is the cheapest format Whisper accepts directly,
///     no transcoding step on either side.
///
/// Architecture mirrors `zachlatta/freeflow`'s `AudioRecorder` but
/// trimmed to the bits Notetaker needs (no live realtime streaming,
/// no system-audio echo cancellation, no per-device picker — just
/// "record from default input until told to stop, hand back a WAV").
///
/// Lifecycle:
///   1. Caller invokes `startRecording()`.
///   2. We open the default audio input via AVCaptureSession.
///   3. Each sample buffer arriving on the audio queue gets converted
///      to 16 kHz mono Int16 and appended to the active AVAudioFile.
///      We also publish a normalized RMS level via `onLevelUpdate`
///      (range 0…1) so the pill UI can drive a live waveform.
///   4. Caller invokes `stopRecording()` → we close the session,
///      finalize the file, and call `onRecordingReady(fileURL)`.
///   5. Caller hands the file URL to `DictationService` for upload.
///
/// All file handles + capture state live on `sessionQueue` to keep
/// the AV* APIs serialized; published state hops to the main actor
/// before notifying.
///
/// Not `@MainActor` because the AVCaptureAudioDataOutputSampleBuffer
/// Delegate callback is invoked on a background queue (the
/// `bufferQueue` we pass to `setSampleBufferDelegate`). Class state
/// touched from that callback (converter, sourceFormat, audioFile)
/// is protected via `sessionQueue` serialization for writes; reads
/// from the delegate are serialized through the same lock-and-
/// dispatch pattern.
final class DictationRecorder: NSObject {
    /// Where the WAV lands on disk. Recreated per recording — old
    /// files are unlinked once the upload completes (or on the next
    /// `startRecording`).
    private(set) var currentFileURL: URL?

    /// Fires on the main actor whenever the audio level changes.
    /// Range [0, 1] where ~0.05 is silence and ~0.6 is normal speech.
    /// Pill UI subscribes to this for live waveform amplitude.
    var onLevelUpdate: ((Float) -> Void)?

    /// Fires on the main actor when `stopRecording` finalized a file.
    /// `nil` if the recording captured no audio (mic muted, permission
    /// denied, < 0.3s of speech, etc.).
    var onRecordingReady: ((URL?) -> Void)?

    /// Fires on the main actor on an unrecoverable capture error.
    /// `DictationOrchestrator` shows a transient error pill in
    /// response and exits the recording state.
    var onRecordingFailure: ((Error) -> Void)?

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    /// Source format from the mic — captured the first time a buffer
    /// arrives so we can build the right `AVAudioConverter`.
    private var sourceFormat: AVAudioFormat?
    private var totalFramesWritten: AVAudioFramePosition = 0

    private let sessionQueue = DispatchQueue(label: "com.aritradebnath.notetaker.dictation.session")
    private let bufferQueue = DispatchQueue(label: "com.aritradebnath.notetaker.dictation.buffers")

    /// Flag for `stopRecording` so the buffer-queue handler stops
    /// appending samples mid-finalization. Locked because reads
    /// happen on `bufferQueue` and writes on `sessionQueue`.
    private var isCapturing: Bool = false
    private let captureFlagLock = NSLock()

    // MARK: - Public API

    /// Begin capturing. Returns immediately; actual hardware open
    /// happens asynchronously on `sessionQueue`. Failures fire the
    /// `onRecordingFailure` callback rather than throwing.
    func startRecording() {
        sessionQueue.async { [weak self] in
            self?.startRecordingOnSessionQueue()
        }
    }

    /// Stop capturing and finalize the file. Fires `onRecordingReady`
    /// with the file URL once the close/encode is complete.
    func stopRecording() {
        sessionQueue.async { [weak self] in
            self?.stopRecordingOnSessionQueue()
        }
    }

    // MARK: - Session setup (sessionQueue)

    private func startRecordingOnSessionQueue() {
        // Tear down any prior session — calling startRecording twice
        // shouldn't pile up two captures.
        teardownSessionLocked()

        // Check Microphone permission BEFORE building the capture session.
        // If we skip this, AVCaptureSession.startRunning() will silently
        // produce empty buffers when permission is denied — the WAV file
        // ends up with 0 frames, the orchestrator throws away "too short"
        // recordings, and the user gets a silent failure with no clue
        // why. Explicit gate → explicit error message.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            break  // Good, continue.
        case .notDetermined:
            // First-launch path. Request, then re-enter via the same
            // session queue so we keep ordering guarantees.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self = self else { return }
                self.sessionQueue.async {
                    if granted {
                        self.startRecordingOnSessionQueue()
                    } else {
                        self.failOnSessionQueue(DictationRecorderError.microphoneDenied)
                    }
                }
            }
            return
        case .denied, .restricted:
            failOnSessionQueue(DictationRecorderError.microphoneDenied)
            return
        @unknown default:
            failOnSessionQueue(DictationRecorderError.microphoneDenied)
            return
        }

        captureFlagLock.lock()
        isCapturing = true
        captureFlagLock.unlock()

        // Build a fresh temp file URL. We use a UUID to avoid colliding
        // with prior recordings still in flight on the network.
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("notetaker-dictation-\(UUID().uuidString).wav")
        currentFileURL = url

        // 16 kHz mono PCM16 — see file header for justification.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            failOnSessionQueue(DictationRecorderError.invalidTargetFormat)
            return
        }
        targetFormat = target

        do {
            // AVAudioFile wraps Core Audio's AudioFileWrite — handles
            // WAV header generation + mono/stereo channel layout.
            let file = try AVAudioFile(
                forWriting: url,
                settings: target.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            audioFile = file
        } catch {
            failOnSessionQueue(error)
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        // Microphone selection. `AVCaptureDevice.default(for: .audio)`
        // returns the user's preferred system input device — the one
        // selected in System Settings → Sound → Input. This is more
        // reliable than enumerating via DiscoverySession and picking
        // `.first`.
        guard let device = AVCaptureDevice.default(for: .audio) else {
            failOnSessionQueue(DictationRecorderError.noMicrophone)
            return
        }
        DictationOrchestrator.dlog("recorder using mic: \(device.localizedName) (uid=\(device.uniqueID))")

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            failOnSessionQueue(error)
            return
        }
        guard session.canAddInput(input) else {
            failOnSessionQueue(DictationRecorderError.cannotAddInput)
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Ask the audio output to deliver samples DIRECTLY at our
        // target 16 kHz mono PCM16 format. macOS's audio plumbing
        // (Core Audio HAL) handles the resampling at hardware level,
        // which produces clean audio. The previous code took the
        // mic's native format (typically 48 kHz float32) and ran it
        // through an AVAudioConverter post-process — that introduced
        // both quality loss and a level mismatch where speech RMS
        // dropped to ~0.005 (silence floor) and Whisper hallucinated
        // ("Thank you" / "I love soap.") instead of transcribing.
        //
        // This matches FreeFlow's `RecordingOverlay`/`AudioRecorder`
        // pattern (zachlatta/freeflow `AudioRecorder.swift:574-582`).
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: target.sampleRate,                 // 16000
            AVNumberOfChannelsKey: Int(target.channelCount),    // 1
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !target.isInterleaved, // false (interleaved)
        ]
        output.setSampleBufferDelegate(self, queue: bufferQueue)
        guard session.canAddOutput(output) else {
            failOnSessionQueue(DictationRecorderError.cannotAddOutput)
            return
        }
        session.addOutput(output)

        captureSession = session
        audioOutput = output
        totalFramesWritten = 0
        sourceFormat = nil
        converter = nil

        session.startRunning()
        NSLog("nox: Dictation recorder started, file=\(url.lastPathComponent)")
    }

    private func stopRecordingOnSessionQueue() {
        captureFlagLock.lock()
        isCapturing = false
        captureFlagLock.unlock()

        captureSession?.stopRunning()
        teardownSessionLocked()

        // Sanity check: did we actually write any audio? Reject
        // ultra-short recordings (< 0.3s) — they're almost always
        // accidental hotkey hits.
        let minimumFrames: AVAudioFramePosition = 16_000 * 3 / 10  // 0.3s @ 16kHz
        let url = currentFileURL
        let frames = totalFramesWritten

        DispatchQueue.main.async { [weak self] in
            if frames >= minimumFrames, let url = url {
                self?.onRecordingReady?(url)
            } else {
                NSLog("nox: Dictation discarded — captured \(frames) frames (< 0.3s)")
                if let url = url {
                    try? FileManager.default.removeItem(at: url)
                }
                self?.onRecordingReady?(nil)
            }
        }
    }

    /// MUST be called from sessionQueue. Tears down the capture
    /// session + closes the audio file. Safe to call when nothing
    /// is set up.
    private func teardownSessionLocked() {
        if let session = captureSession {
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
        }
        captureSession = nil
        audioOutput = nil
        // Setting audioFile to nil triggers AVAudioFile's deinit which
        // flushes pending writes + closes the file handle. The WAV
        // header gets backfilled with the correct frame count.
        audioFile = nil
        converter = nil
    }

    private func failOnSessionQueue(_ error: Error) {
        captureFlagLock.lock()
        isCapturing = false
        captureFlagLock.unlock()

        teardownSessionLocked()
        NSLog("nox: Dictation recorder error — \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.onRecordingFailure?(error)
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension DictationRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        captureFlagLock.lock()
        let active = isCapturing
        captureFlagLock.unlock()
        guard active else { return }

        // The output is configured to deliver 16 kHz mono PCM16
        // directly (`audioSettings` set in `startRecordingOnSessionQueue`),
        // so we just copy bytes — no AVAudioConverter step. This is
        // FreeFlow's exact pattern, and it's what produces clean
        // audio that Whisper can actually transcribe.
        guard let pcmBuffer = makeAudioPCMBuffer(from: sampleBuffer) else { return }

        let level = computeRMSLevel(pcmBuffer)
        DispatchQueue.main.async { [weak self] in
            self?.onLevelUpdate?(level)
        }

        // Write the buffer (already in target format) to disk.
        sessionQueue.async { [weak self] in
            guard let self = self, let file = self.audioFile else { return }
            do {
                try file.write(from: pcmBuffer)
                self.totalFramesWritten += AVAudioFramePosition(pcmBuffer.frameLength)
            } catch {
                NSLog("nox: Dictation — write error \(error.localizedDescription)")
            }
        }
    }

    /// Wrap the CMSampleBuffer into an AVAudioPCMBuffer using the
    /// official Core Audio API. With `audioSettings` set on the
    /// AVCaptureAudioDataOutput, the buffer arrives in our exact
    /// target format (16 kHz mono PCM16 interleaved), so no format
    /// negotiation is needed.
    private nonisolated func makeAudioPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let avFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount
        // CMSampleBufferCopyPCMDataIntoAudioBufferList is the
        // canonical, format-aware copy. Replaces the previous
        // hand-rolled memcpy that guessed at format.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            NSLog("nox: Dictation — CMSampleBufferCopyPCMDataIntoAudioBufferList failed (OSStatus \(status))")
            return nil
        }
        return pcmBuffer
    }

    /// Compute root-mean-square audio level normalized to 0…1.
    /// Used to drive the pill's recording-state waveform.
    ///
    /// We DON'T multiply by 2.5 anymore — the previous gain
    /// boost was masking how quiet the audio actually was, which
    /// hid the underlying capture problem (post-processed audio
    /// hitting silence-floor RMS).
    private nonisolated func computeRMSLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sumSquares: Float = 0
        if let floatChannel = buffer.floatChannelData?[0] {
            for i in 0..<frameLength {
                let sample = floatChannel[i]
                sumSquares += sample * sample
            }
        } else if let int16Channel = buffer.int16ChannelData?[0] {
            for i in 0..<frameLength {
                let sample = Float(int16Channel[i]) / 32_767.0
                sumSquares += sample * sample
            }
        }
        let rms = sqrt(sumSquares / Float(frameLength))
        // Loudness normalization — speech RMS at the mic is ~0.05–0.20.
        // Scale up modestly (4×) so normal speech reads as 0.2–0.8 in
        // the waveform UI without slamming the cap. Loud speech
        // saturates cleanly. Compare to the old 2.5× scaler that was
        // applied AFTER the AVAudioConverter post-process which had
        // already attenuated levels.
        return min(1.0, rms * 4.0)
    }
}

// MARK: - Errors

enum DictationRecorderError: LocalizedError {
    case noMicrophone
    case microphoneDenied
    case cannotAddInput
    case cannotAddOutput
    case invalidTargetFormat

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone available."
        case .microphoneDenied:
            // User-actionable. Surfaced verbatim in the dictation pill /
            // settings panel — keep it short and tell them where to go.
            return "Microphone access denied. Open System Settings → Privacy & Security → Microphone and enable nox."
        case .cannotAddInput:
            return "Could not attach the microphone to the capture session."
        case .cannotAddOutput:
            return "Could not attach the audio output to the capture session."
        case .invalidTargetFormat:
            return "Could not configure the 16 kHz mono PCM16 target format."
        }
    }
}
