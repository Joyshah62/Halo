import Combine
import AVFoundation
import Speech

enum PlaybackFailure: LocalizedError {
    case unavailable, timedOut, interrupted, invalidAudio
    var errorDescription: String? {
        switch self {
        case .unavailable: return "A system voice isn’t available. Answers will continue as text. Try server audio or install a voice in iPad accessibility settings."
        case .timedOut: return "Voice playback didn’t respond. Answers will continue as text."
        case .interrupted: return "Voice playback was interrupted. Answers will continue as text."
        case .invalidAudio: return "The audio clip couldn’t play. Answers will continue as text."
        }
    }
}

@MainActor
final class AnswerPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private var utterance: AVSpeechUtterance?
    private var audio: AVAudioPlayer?
    // Do not initialize Apple's voice service when the reader opens, or when
    // stopping idle playback. Server-provided clips do not require this service.
    private var synthesizer: AVSpeechSynthesizer?
    private var cachedVoice: AVSpeechSynthesisVoice?
    private var systemVoiceUnavailable = false
    private var sessionActive = false
    private var watchdog: Task<Void, Never>?
    private var completion: CheckedContinuation<Void, Error>?
    private var token = UUID()

    /// How long the step will take to speak, so ink can be paced to the voice.
    static func estimate(_ text: String) -> TimeInterval { 0.4 + Double(text.split(whereSeparator: \.isWhitespace).count) * 0.33 }
    func duration(of step: AnswerStep) -> TimeInterval {
        if let encoded = step.audio, let data = Data(base64Encoded: encoded), let player = try? AVAudioPlayer(data: data), player.duration.isFinite, player.duration > 0 { return player.duration }
        return Self.estimate(step.say)
    }

    func play(_ step: AnswerStep) async throws {
        try Task.checkCancellation(); stop()
        let id = UUID(); token = id
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true); sessionActive = true
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion = continuation
                    if let encoded = step.audio, let data = Data(base64Encoded: encoded), let player = try? AVAudioPlayer(data: data) {
                        audio = player; player.delegate = self; player.isMeteringEnabled = true
                        if player.play() {
                            let duration = player.duration.isFinite ? player.duration : 60
                            armWatchdog(seconds: min(180, max(8, duration + 5)), token: id)
                            return
                        }
                        audio = nil
                    }
                    guard !systemVoiceUnavailable else { finish(PlaybackFailure.unavailable); return }
                    if cachedVoice == nil { cachedVoice = AVSpeechSynthesisVoice(language: "en-US") }
                    guard let voice = cachedVoice else {
                        systemVoiceUnavailable = true; finish(PlaybackFailure.unavailable); return
                    }
                    if synthesizer == nil { synthesizer = AVSpeechSynthesizer(); synthesizer?.delegate = self }
                    let utterance = AVSpeechUtterance(string: step.say)
                    utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                    self.utterance = utterance
                    // Missing simulator voice assets can yield neither a start nor an error callback.
                    armWatchdog(seconds: 8, token: id)
                    synthesizer?.speak(utterance)
                }
            } onCancel: { Task { @MainActor [weak self] in if self?.token == id { self?.stop() } } }
        } catch {
            if utterance != nil, !(error is CancellationError) { systemVoiceUnavailable = true }
            stop(); throw error
        }
    }
    private func armWatchdog(seconds: Double, token: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.token == token, self.completion != nil else { return }
            if self.utterance != nil { self.systemVoiceUnavailable = true }
            self.finish(PlaybackFailure.timedOut)
        }
    }
    func stop() {
        token = UUID()
        finish(CancellationError())
    }
    /// Loudness of the clip playing now (0…1), or nil when no metered clip is playing.
    var outputLevel: CGFloat? {
        guard let audio, audio.isPlaying else { return nil }
        audio.updateMeters()
        return CGFloat(max(0, min(1, (audio.averagePower(forChannel: 0) + 45) / 45)))
    }
    private func finish(_ error: Error? = nil) {
        watchdog?.cancel(); watchdog = nil
        let pending = completion; completion = nil
        let hadUtterance = utterance != nil
        utterance = nil
        audio?.stop(); audio = nil
        if hadUtterance, let synthesizer, synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in guard self?.audio === player else { return }; self?.finish(flag ? nil : PlaybackFailure.invalidAudio) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in guard self?.audio === player else { return }; self?.finish(PlaybackFailure.invalidAudio) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            let words = utterance.speechString.split(whereSeparator: \.isWhitespace).count
            self.armWatchdog(seconds: min(180, max(15, Double(words) * 0.8 + 10)), token: self.token)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in guard self?.utterance === utterance else { return }; self?.finish() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in guard self?.utterance === utterance else { return }; self?.finish(PlaybackFailure.interrupted) }
    }
}

@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published var lastError: String?
    var onTranscript: ((String) -> Void)?
    var onStopped: (() -> Void)?
    /// Microphone loudness (0…1) while recording, for visual feedback.
    let meter = LevelMeter()
    private var sessionActive = false
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var token = UUID()
    func requestPermissions() async {
        _ = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        _ = await AVAudioApplication.requestRecordPermission()
    }
    func start() async throws {
        stop()
        lastError = nil
        let id = UUID(); token = id
        let speechPermission = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        let microphonePermission = await AVAudioApplication.requestRecordPermission()
        guard token == id else { return }
        guard speechPermission == .authorized, microphonePermission else { lastError = "Allow the microphone in Settings, or type your question."; throw NSError(domain: "HaloSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError!]) }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { lastError = "Voice isn’t available right now. Type your question."; throw NSError(domain: "HaloSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: lastError!]) }
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try AVAudioSession.sharedInstance().setActive(true); sessionActive = true
        let engine = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { stop(); lastError = "No microphone found. Type your question instead."; throw NSError(domain: "HaloSpeech", code: 3, userInfo: [NSLocalizedDescriptionKey: lastError!]) }
        let meter = self.meter
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
                let db = 20 * log10(max(1e-6, sqrt(sum / Float(buffer.frameLength))))
                meter.value = max(0, min(1, (db + 50) / 40))
            }
        }
        self.engine = engine; self.request = request
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.token == id else { return }
                if let result { self.onTranscript?(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true { self.stop() }
            }
        }
        do { engine.prepare(); try engine.start(); isRecording = true }
        catch { stop(); throw error }
    }
    func stop() {
        token = UUID()
        let wasRecording = isRecording
        isRecording = false
        meter.value = 0
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        request?.endAudio(); request = nil; recognition?.cancel(); recognition = nil
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if wasRecording { onStopped?() }
    }
}
