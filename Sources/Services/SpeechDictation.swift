import Foundation
import AVFoundation
import Speech

/// Microphone + speech recognition plumbing. Deliberately not actor-isolated: the tap and recognition
/// callbacks arrive on audio/speech queues, so every callback handed in must be `@Sendable`.
final class SpeechDictationSession: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Speech recognition isn't available right now. Check your internet connection or the language in System Settings." }
    }

    static func requestPermissions() async -> String? {
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speech == .authorized else {
            return "GitXX isn't allowed to use Speech Recognition. Turn it on in System Settings › Privacy & Security › Speech Recognition."
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return "GitXX isn't allowed to use the microphone. Turn it on in System Settings › Privacy & Security › Microphone."
        }
        return nil
    }

    func start(onText: @escaping @Sendable (String, Bool) -> Void,
               onLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw Failure.unavailable }
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        nonisolated(unsafe) let request = self.request
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in stride(from: 0, to: n, by: 8) { sum += samples[i] * samples[i] }
            onLevel(min(1, sqrt(sum / Float(max(n / 8, 1))) * 8))
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { result, error in
            if let result { onText(result.bestTranscription.formattedString, result.isFinal) }
            if let error { onError(error) }
        }
    }

    /// Stops listening; the recogniser may still deliver a final result.
    func stop() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task?.finish()
    }
}

/// Voice input for the assistant composer: appends the live transcript to whatever was already typed.
@MainActor
final class AIVoiceInput: ObservableObject {
    static let shared = AIVoiceInput()

    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var level: Float = 0
    @Published var problem: String?

    private var session: SpeechDictationSession?
    private var prefix = ""
    private var generation = 0

    func toggle(chat: AIChatStore) {
        isRecording || isStarting ? stop() : start(chat: chat)
    }

    func start(chat: AIChatStore) {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        problem = nil
        generation += 1
        let gen = generation
        prefix = chat.input.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let message = await SpeechDictationSession.requestPermissions() {
                isStarting = false
                problem = message
                return
            }
            guard gen == generation, isStarting else { return }
            let session = SpeechDictationSession()
            do {
                try session.start(
                    onText: { text, final in
                        Task { @MainActor in AIVoiceInput.shared.receive(text, final: final, gen: gen, chat: chat) }
                    },
                    onLevel: { level in
                        Task { @MainActor in if AIVoiceInput.shared.generation == gen { AIVoiceInput.shared.level = level } }
                    },
                    onError: { error in
                        let message = error.localizedDescription
                        Task { @MainActor in AIVoiceInput.shared.failed(message, gen: gen) }
                    })
                self.session = session
                isStarting = false
                isRecording = true
            } catch {
                isStarting = false
                problem = error.localizedDescription
            }
        }
    }

    func stop() {
        generation += 1
        session?.stop()
        session = nil
        isStarting = false
        isRecording = false
        level = 0
    }

    private func receive(_ text: String, final: Bool, gen: Int, chat: AIChatStore) {
        guard gen == generation else { return }
        chat.input = prefix.isEmpty ? text : prefix + " " + text
        if final { stop() }
    }

    private func failed(_ message: String, gen: Int) {
        guard gen == generation else { return }
        stop()
        // "No speech detected" and cancellations aren't worth surfacing.
        if !message.localizedCaseInsensitiveContains("no speech") && !message.localizedCaseInsensitiveContains("cancel") {
            problem = message
        }
    }
}
