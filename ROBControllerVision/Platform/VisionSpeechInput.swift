import AVFoundation
import Observation
import Speech

@MainActor
@Observable
final class VisionSpeechInput {
    private(set) var isRecording = false
    private(set) var status = "Ready for Vision Pro dictation"
    var onTranscript: ((String, Bool) -> Void)?

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    func toggle() {
        if isRecording {
            stop()
        } else {
            Task { await start() }
        }
    }

    func stop() {
        guard isRecording || recognitionTask != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        status = "Dictation stopped — review or send the transcript"
    }

    private func start() async {
        guard !isRecording else { return }
        let speechAuthorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechAuthorization == .authorized else {
            status = "Speech recognition permission is required"
            return
        }
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
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

        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            recognitionRequest = nil
            status = "Could not start microphone: \(error.localizedDescription)"
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
                    if result.isFinal { self.stop() }
                } else if let error {
                    self.status = "Dictation failed: \(error.localizedDescription)"
                    self.stop()
                }
            }
        }
    }
}
