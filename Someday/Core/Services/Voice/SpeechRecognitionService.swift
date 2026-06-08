import Foundation
import Speech
import AVFoundation

/// On-device speech recognition for the AI chat mic button. Walks the
/// permission ladder (mic + speech), spins up an `SFSpeechRecognizer`
/// session, pipes partial results back to a closure so the UI can
/// stream the transcription into the text field as the user talks.
///
/// Design choices:
///   • Single shared instance. Only one mic session can be active at
///     a time on iOS, so multiple owners would just step on each other.
///   • `@Observable` so SwiftUI views can react to `isListening` /
///     `errorMessage` without an explicit Combine subscription.
///   • Auto-stops on a 1.5s silence window so the user doesn't have to
///     tap stop — same UX as iMessage dictation. Manual `stop()` still
///     available for the explicit toggle case.
///   • Never records to disk. Audio frames go straight into the
///     recognizer's buffer; once `stop()` runs the buffer is released.
///     Matches the Info.plist promise: "audio isn't stored".
@MainActor
@Observable
final class SpeechRecognitionService {
    static let shared = SpeechRecognitionService()

    /// True while the mic is open and capturing. Drives the chat bar
    /// mic button's pulsing/red "listening" state via a SwiftUI bind.
    private(set) var isListening = false
    /// Latest partial transcription. Useful for debugging / debug UI;
    /// the canonical text path is the `onUpdate` callback passed to
    /// `start(onUpdate:)`.
    private(set) var lastTranscription = ""
    /// Surfaced when a step fails (permission denied, audio session
    /// blocked, recognizer unavailable). Cleared on the next start.
    private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Locale-pinned recognizer. Pinning to en-US for now — switching
    /// to `Locale.current` once we have UI for picking a recognition
    /// language is a small one-liner.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// Auto-stop timer fired when partial results stop arriving. Reset
    /// every time the recognizer produces a fresh chunk.
    private var silenceTimer: Timer?

    private init() {}

    // MARK: - Public

    /// Convenience toggle for the mic button: tap once to start, tap
    /// again to stop. `onUpdate` is called on the main actor with the
    /// running partial transcription so the UI can mirror it live.
    func toggle(onUpdate: @escaping (String) -> Void) {
        if isListening { stop() } else { start(onUpdate: onUpdate) }
    }

    /// Start a fresh recognition session. Idempotent — calling while
    /// already listening is a no-op (the existing session keeps running).
    func start(onUpdate: @escaping (String) -> Void) {
        guard !isListening else { return }
        errorMessage = nil
        Task { await beginSession(onUpdate: onUpdate) }
    }

    /// Tear the session down. Safe to call from anywhere; idempotent.
    func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        isListening = false
        // Restore the shared audio session so other audio (music,
        // VoiceOver, ringtones) can resume their normal routing.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Private

    private func beginSession(onUpdate: @escaping (String) -> Void) async {
        // 1. Speech recognition permission. iOS returns the answer
        //    via callback; we wrap it in a continuation so the rest
        //    of the flow stays linear.
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard speechStatus == .authorized else {
            errorMessage = "Speech recognition permission was declined."
            return
        }
        // 2. Microphone permission. iOS 17 has `AVAudioApplication`;
        //    fall back to `AVCaptureDevice` for older targets.
        let micStatus: Bool
        if #available(iOS 17.0, *) {
            micStatus = await AVAudioApplication.requestRecordPermission()
        } else {
            micStatus = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard micStatus else {
            errorMessage = "Microphone permission was declined."
            return
        }
        // 3. Verify the recognizer is actually usable (offline model
        //    might not be downloaded yet, no network, etc.).
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }

        // 4. Configure the shared audio session. `.record` + `.measurement`
        //    is the canonical "we're capturing voice for a task" combo.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Couldn't start the mic: \(error.localizedDescription)"
            return
        }

        // 5. Wire up the recognition request + audio tap.
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 16.0, *) { req.addsPunctuation = true }
        self.request = req

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stop()
            errorMessage = "Couldn't start audio engine: \(error.localizedDescription)"
            return
        }

        isListening = true
        Haptics.tap()

        // 6. Kick off the recognition task. Partial results stream
        //    back as the user talks; on each one we reset the silence
        //    timer so a real pause auto-stops the session.
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.lastTranscription = text
                    onUpdate(text)
                    self.armSilenceTimer()
                    if result.isFinal { self.stop() }
                }
                if error != nil { self.stop() }
            }
        }
        armSilenceTimer()
    }

    /// Arms (or re-arms) the auto-stop timer. iMessage-style: after 1.5s
    /// of no fresh partial results, the session closes itself so the
    /// user doesn't have to tap stop after a clean pause.
    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }
}
