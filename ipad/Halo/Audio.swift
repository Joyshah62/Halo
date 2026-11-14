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
    /// Halo's own (server) voice has played. After that, a step that arrives without a clip is shown, not read
    /// in Apple's voice: a different voice halfway through an answer sounds like a different tutor.
    private var heardServerVoice = false
    /// Releases the audio session once nothing has played for a moment (see `finish`).
    private var release: Task<Void, Never>?
    /// Told when playback starts (true) and ends (false), so the wake-word listener can step aside.
    var onActive: ((Bool) -> Void)?

    /// How long the step will take to speak, so ink can be paced to the voice.
    static func estimate(_ text: String) -> TimeInterval { 0.4 + Double(text.split(whereSeparator: \.isWhitespace).count) * 0.33 }
    func duration(of step: AnswerStep) -> TimeInterval {
        if let encoded = step.audio, let data = Data(base64Encoded: encoded), let player = try? AVAudioPlayer(data: data), player.duration.isFinite, player.duration > 0 { return player.duration }
        return Self.estimate(step.say)
    }

    func play(_ step: AnswerStep) async throws {
        try Task.checkCancellation()
        // Ends whatever was playing but keeps the audio session: clips that follow each other (a lesson plays
        // a filler, a reaction, then each step) used to switch audio off and on between them, and every
        // restart swallowed the first syllable of the next clip.
        finish(CancellationError(), release: false)
        release?.cancel(); release = nil
        let id = UUID(); token = id
        onActive?(true)
        do {
            let session = AVAudioSession.sharedInstance()
            // Coming straight from the microphone, the audio route is changing (on Bluetooth headphones this is a
            // switch out of call mode). Starting a clip before it settles cuts off its first words.
            let switching = session.category != .playback || session.mode != .spokenAudio
            if switching { try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers]) }
            if !sessionActive || switching { try session.setActive(true); sessionActive = true }
            if switching {
                let wireless = session.currentRoute.outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) }
                try await Task.sleep(for: .milliseconds(wireless ? 350 : 120))
                guard token == id else { throw CancellationError() }
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion = continuation
                    if let encoded = step.audio, let data = Data(base64Encoded: encoded), let player = try? AVAudioPlayer(data: Self.loud(data)) {
                        audio = player; player.delegate = self; player.isMeteringEnabled = true
                        player.prepareToPlay()
                        if player.play() {
                            heardServerVoice = true
                            let duration = player.duration.isFinite ? player.duration : 60
                            armWatchdog(seconds: min(180, max(8, duration + 5)), token: id)
                            return
                        }
                        audio = nil
                    }
                    if heardServerVoice {
                        // No clip for this step (the voice service had a hiccup): stay quiet for as long as it would
                        // take to say, so captions and ink keep their pace.
                        watchdog?.cancel()
                        watchdog = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(Self.estimate(step.say))) } catch { return }
                            guard let self, self.token == id else { return }
                            self.finish()
                        }
                        return
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
    /// The voice service's clips arrive very quiet (peaks near -34 dBFS, measured), far below what the volume buttons
    /// can make up for. Brings the loudest moment of a clip to just under full scale; a clip that is already loud,
    /// silent or unreadable is played as it came.
    static func loud(_ data: Data) -> Data {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        let target = source.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        do {
            try data.write(to: source)
            let file = try AVAudioFile(forReading: source)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return data }
            try file.read(into: buffer)
            guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { return data }
            let channels = Int(buffer.format.channelCount), count = Int(buffer.frameLength)
            var peak: Float = 0
            for channel in 0..<channels { for index in 0..<count { peak = max(peak, abs(samples[channel][index])) } }
            // Below 0.0005 there is nothing but noise to amplify; above 0.7 there is nothing to gain.
            guard peak > 0.0005, peak < 0.7 else { return data }
            let gain = 0.9 / peak
            for channel in 0..<channels { for index in 0..<count { samples[channel][index] *= gain } }
            do {
                // The file is only complete on disk once this goes out of scope.
                let written = try AVAudioFile(forWriting: target, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: buffer.format.sampleRate, AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                try written.write(from: buffer)
            }
            return try Data(contentsOf: target)
        } catch { return data }
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
    /// Stops now and gives the audio back at once (the microphone may be about to take it).
    func stop() {
        token = UUID()
        finish(CancellationError(), release: true)
    }
    /// Loudness of the clip playing now (0…1), or nil when no metered clip is playing.
    var outputLevel: CGFloat? {
        guard let audio, audio.isPlaying else { return nil }
        audio.updateMeters()
        return CGFloat(max(0, min(1, (audio.averagePower(forChannel: 0) + 45) / 45)))
    }
    /// `release`: true gives the audio session back now; false keeps it for the next clip; nil (a clip ended on its
    /// own) gives it back after a short pause, unless another clip has started by then.
    private func finish(_ error: Error? = nil, release now: Bool? = nil) {
        watchdog?.cancel(); watchdog = nil
        let pending = completion; completion = nil
        let hadUtterance = utterance != nil
        utterance = nil
        audio?.stop(); audio = nil
        if hadUtterance, let synthesizer, synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
        switch now {
        case true?: releaseSession()
        case false?: break
        case nil:
            release?.cancel()
            release = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                guard let self, self.completion == nil else { return }
                self.releaseSession()
            }
        }
    }
    private func releaseSession() {
        release?.cancel(); release = nil
        if sessionActive {
            sessionActive = false
            // The microphone may have taken the session in the meantime: then it is the microphone's to release.
            if AVAudioSession.sharedInstance().category == .playback {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        onActive?(false)
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
    /// Told when the microphone is taken (true) and released (false), so the wake-word listener can step aside.
    var onActive: ((Bool) -> Void)?
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
        onActive?(true)
        do {
            // A2DP, not HFP: Bluetooth headphones stay in full-quality listening mode and the iPad's own microphone hears
            // the question. HFP (the headphones' mic) puts them in call mode, and switching back cut off Halo's next words.
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true); sessionActive = true
        } catch { stop(); throw error }
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
        onActive?(false)
    }
}

/// Listens for "Sup Halo" while a document is open, on the iPad only (audio never leaves it).
/// Steps aside whenever Halo is speaking or taking a question, since they share the microphone and audio session.
@MainActor
final class WakeListener {
    /// Fires with whatever was said after the wake phrase ("sup halo, go to page 12" → "go to page 12"; empty if nothing).
    var onWake: ((String) -> Void)?
    /// On-device recognition is required: a wake word means listening all the time, and that must not stream to a server.
    var supported: Bool { SFSpeechRecognizer()?.supportsOnDeviceRecognition == true }

    private var wanted = false
    private var holders: Set<String> = []
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var sessionActive = false
    private var token = UUID()
    private var resumeTask: Task<Void, Never>?
    private var heardTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var failures = 0

    // "sup halo", and the ways a recogniser writes it down.
    private static let phrase = try! NSRegularExpression(
        pattern: #"\b(?:'?sup+|soup|sop|sub|wh?a(?:t'?s|ss)\s*up|wassup)[\s,.!?]+(?:halo|hallo|hello|hollow|halow|haylo)\b[\s,.!?]*"#,
        options: [.caseInsensitive])

    /// Whether Halo should be listening for the phrase at all (setting on, a document open, nothing else using the mic).
    func setEnabled(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        if on { failures = 0; begin() } else { end() }
    }
    /// Something else needs the microphone or speaker (`source` is "speech" or "player"). Stops at once;
    /// picks back up a moment after the last holder lets go, so it doesn't restart between spoken steps.
    func hold(_ source: String, _ active: Bool) {
        if active {
            resumeTask?.cancel()
            if holders.insert(source).inserted { end() }
        } else if holders.remove(source) != nil, holders.isEmpty {
            resume(after: .milliseconds(1200))
        }
    }

    /// Try again now, e.g. once the microphone has just been allowed.
    func retry() { failures = 0; begin() }

    private func resume(after delay: Duration) {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.begin()
        }
    }

    private func begin() {
        guard wanted, holders.isEmpty, engine == nil else { return }
        // Never prompt from here: permission is asked when the setting is switched on.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized, AVAudioApplication.shared.recordPermission == .granted,
              let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        let id = UUID(); token = id
        let started = Date()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true); sessionActive = true
            let engine = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.contextualStrings = ["sup Halo", "Halo"]
            let input = engine.inputNode, format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { end(); return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            self.engine = engine; self.request = request
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || result?.isFinal == true
                Task { @MainActor in
                    guard let self, self.token == id else { return }
                    if let text { self.heard(text) }
                    if done { self.ended(after: Date().timeIntervalSince(started)) }
                }
            }
            engine.prepare(); try engine.start()
        } catch { end(); ended(after: 0) }
        // Start a fresh transcript every so often, so it stays short and an old "sup halo" can't match again.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(50))
            guard let self, !Task.isCancelled, self.token == id, self.heardTask == nil else { return }
            self.end(); self.begin()
        }
    }

    private func heard(_ text: String) {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Self.phrase.matches(in: text, range: range).last, let end = Range(match.range, in: text) else { return }
        let rest = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Wait for a pause, in case a question follows the phrase.
        heardTask?.cancel()
        heardTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(rest.isEmpty ? 900 : 1300))
            guard let self, !Task.isCancelled else { return }
            self.heardTask = nil
            self.end()
            self.onWake?(rest)
            self.resume(after: .seconds(1))
        }
    }

    /// The recogniser stopped on its own (silence, a time limit, an error): start again, backing off if it keeps failing.
    private func ended(after seconds: TimeInterval) {
        guard heardTask == nil else { return }
        end()
        failures = seconds < 2 ? failures + 1 : 0
        guard failures < 6 else { return }
        resume(after: .seconds(failures == 0 ? 0.3 : Double(failures) * 2))
    }

    private func end() {
        token = UUID()
        refreshTask?.cancel(); refreshTask = nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        request?.endAudio(); request = nil; recognition?.cancel(); recognition = nil
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if !wanted || !holders.isEmpty { heardTask?.cancel(); heardTask = nil; resumeTask?.cancel() }
    }
}
