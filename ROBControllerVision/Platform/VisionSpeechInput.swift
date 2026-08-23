import AVFoundation
import Observation
import Speech

@MainActor
@Observable
final class VisionSpeechInput {
    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var status = "Ready for Vision Pro dictation"
    var onTranscript: ((String, Bool) -> Void)?

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var inputTapIsInstalled = false
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    func toggle() {
        if isRecording {
            stop()
        } else if !isStarting {
            isStarting = true
            status = "Preparing Vision Pro microphone…"
            startTask = Task { [weak self] in
                await self?.start()
            }
        }
    }

    func stop() {
        guard isStarting || isRecording || recognitionTask != nil else { return }
        startTask?.cancel()
        finishCapture(status: "Dictation stopped — review or send the transcript")
    }

    private func start() async {
        defer {
            isStarting = false
            startTask = nil
        }
        guard !isRecording, !Task.isCancelled else { return }
        let speechAuthorization = await Self.requestSpeechAuthorization()
        guard !Task.isCancelled else { return }
        guard speechAuthorization == .authorized else {
            status = "Speech recognition permission is required"
            return
        }
        let microphoneAllowed = await Self.requestMicrophonePermission()
        guard !Task.isCancelled else { return }
        guard microphoneAllowed else {
            status = "Microphone permission is required"
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            status = "Speech recognition is currently unavailable"
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionRequest = request

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true)
            guard audioSession.isInputAvailable else {
                finishCapture(status: "Vision Pro microphone input is unavailable")
                return
            }

            // Construct a fresh engine for each push-to-dictate session. This
            // guarantees that a tap retired by a prior session can't remain
            // attached to the new input node.
            let engine = AVAudioEngine()
            audioEngine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard Self.isUsableInputFormat(format) else {
                finishCapture(status: "Vision Pro returned an invalid microphone format")
                return
            }
            input.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: format
            ) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            inputTapIsInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            finishCapture(status: "Could not start microphone: \(error.localizedDescription)")
            return
        }

        guard !Task.isCancelled else {
            finishCapture(status: "Dictation stopped")
            return
        }
        isRecording = true
        status = "Listening through Vision Pro…"
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    self.onTranscript?(transcript, result.isFinal)
                    self.status = result.isFinal ? "Dictation complete" : "Listening through Vision Pro…"
                    if result.isFinal {
                        self.finishCapture(status: "Dictation complete")
                    }
                } else if let error {
                    self.finishCapture(status: "Dictation failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func isUsableInputFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate.isFinite
            && format.sampleRate > 0
            && format.channelCount > 0
    }

    /// TCC invokes permission completions on an arbitrary queue. Keep these
    /// bridges nonisolated so Swift 6 doesn't attach the app's default main-
    /// actor isolation to a callback that the framework calls off-main.
    private nonisolated static func requestSpeechAuthorization() async
        -> SFSpeechRecognizerAuthorizationStatus
    {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorization in
                continuation.resume(returning: authorization)
            }
        }
    }

    private nonisolated static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func finishCapture(status finalStatus: String) {
        startTask?.cancel()
        startTask = nil
        audioEngine?.stop()
        if inputTapIsInstalled, let input = audioEngine?.inputNode {
            input.removeTap(onBus: 0)
        }
        inputTapIsInstalled = false
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine?.reset()
        audioEngine = nil
        isRecording = false
        isStarting = false
        status = finalStatus
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
