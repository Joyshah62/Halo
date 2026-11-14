import SwiftUI

// "Quiz me on my notes": Halo writes a short quiz from the student's own notes and asks it one question
// at a time, out loud. Multiple choice is marked here (the right option comes with the quiz); a short
// answer, typed or said, is marked by the server. Each answer gets a line on why, and the line of the
// notes it came from. At the end: the score, what was missed, and a go at just those.

@MainActor
final class QuizCoach: ObservableObject {
    enum Stage: Equatable { case loading, asking, marking, marked, done, failed(String) }
    struct Mark: Equatable {
        /// "right", "almost" or "wrong".
        var verdict: String
        var say: String
        var answer: String
        var right: Bool { verdict == "right" }
    }
    @Published private(set) var quiz: Quiz?
    @Published private(set) var index = 0
    @Published private(set) var stage: Stage = .loading
    @Published private(set) var marks: [UUID: Mark] = [:]
    @Published var picked: Int?
    @Published var draft = ""
    @Published var voice = true
    /// "this note" or "all your notes", for the header.
    @Published private(set) var scope = ""
    @Published private(set) var retrying = false
    // The avatar: how long it is speaking for, and how it last reacted.
    @Published private(set) var speakingUntil = Date.distantPast
    @Published private(set) var reaction: TutorMood?
    @Published private(set) var reactionUntil = Date.distantPast
    @Published private(set) var cheers = 0
    let speech = SpeechInput()
    private let player = AnswerPlayer()
    private let client = HaloClient()
    private var request: QuizRequest?
    private var server = ""
    private var demo = false
    private var full: Quiz?
    private var task: Task<Void, Never>?
    private var talk: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var token = UUID()

    init() {
        speech.onTranscript = { [weak self] text in self?.heard(text) }
        speech.onStopped = { [weak self] in self?.silence?.cancel() }
    }

    var question: QuizQuestion? { quiz.flatMap { $0.questions.indices.contains(index) ? $0.questions[index] : nil } }
    var mark: Mark? { question.flatMap { marks[$0.id] } }
    var count: Int { quiz?.questions.count ?? 0 }
    var score: Int { quiz?.questions.filter { marks[$0.id]?.right == true }.count ?? 0 }
    var missed: [QuizQuestion] { quiz?.questions.filter { marks[$0.id]?.right != true } ?? [] }
    var cue: TutorCue {
        var cue = TutorCue(speakingUntil: speakingUntil, reaction: reaction, reactionUntil: reactionUntil)
        if speech.isRecording { cue.base = .listening }
        else if stage == .loading || stage == .marking { cue.base = .thinking }
        else if stage == .asking { cue.base = .attentive }
        return cue
    }

    func start(_ request: QuizRequest, scope: String, server: String, voice: Bool, demo: Bool) {
        self.request = request; self.scope = scope; self.server = server; self.voice = voice; self.demo = demo
        load()
    }
    /// A new quiz from the same notes.
    func again() { load() }
    func load() {
        guard let request else { return }
        hush(); token = UUID(); let id = token
        quiz = nil; full = nil; marks = [:]; index = 0; picked = nil; draft = ""; retrying = false; stage = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let made = demo ? try await Self.demoQuiz() : try await client.quiz(request, server: server)
                guard token == id, !Task.isCancelled else { return }
                full = made; quiz = made
                ask()
            } catch {
                guard token == id, !Task.isCancelled else { return }
                stage = .failed((error as? LocalizedError)?.errorDescription ?? "Halo couldn’t write a quiz just now. Check the server in Settings and try again.")
            }
        }
    }
    func retryMissed() {
        guard let full else { return }
        let again = missed
        guard !again.isEmpty else { return }
        hush(); token = UUID()
        quiz = Quiz(title: full.title, questions: again.map { var q = $0; q.id = UUID(); return q })
        marks = [:]; index = 0; retrying = true
        ask()
    }
    func next() {
        guard stage == .marked else { return }
        hush()
        if index + 1 < count { index += 1; ask() }
        else {
            stage = .done
            let share = count == 0 ? 0 : Double(score) / Double(count)
            react(share >= 0.8 ? .proud : share >= 0.5 ? .happy : .unsure, for: 3)
            if share >= 0.8 { cheers += 1 }
            say(share == 1 ? "Every one. Your notes have this covered." : share >= 0.5 ? "\(score) out of \(count). Let's look at the ones that got away." : "\(score) out of \(count). A second look at these will help.")
        }
    }
    func pick(_ option: Int) {
        guard stage == .asking, let question, question.isChoice else { return }
        hush()
        picked = option
        let right = option == question.answer
        let say = right ? question.explain : "It’s “\(question.options[question.answer])”. \(question.explain)"
        marked(Mark(verdict: right ? "right" : "wrong", say: say, answer: question.options[option]), speak: say)
    }
    func submit(_ text: String? = nil) {
        guard stage == .asking, let question, !question.isChoice else { return }
        let answer = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        hush(); draft = answer; stage = .marking
        let id = token
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let grade = demo ? Self.demoGrade(question, answer) : try await client.grade(QuizGradeRequest(question: question, answer: answer), server: server)
                guard token == id, !Task.isCancelled else { return }
                marked(Mark(verdict: grade.verdict, say: grade.say, answer: answer), speak: grade.say, audio: grade.audio)
            } catch {
                guard token == id, !Task.isCancelled else { return }
                stage = .asking
                say("I couldn’t mark that one. Try sending it again.")
            }
        }
    }
    /// "I don't know" is an answer too: Halo shows the right one.
    func reveal() {
        guard stage == .asking, let question else { return }
        hush()
        let right = question.isChoice ? question.options[question.answer] : question.expected
        let say = "Here it is: \(right). \(question.explain)"
        marked(Mark(verdict: "wrong", say: say, answer: ""), speak: say)
    }
    func listen() {
        if speech.isRecording { speech.stop(); submit(); return }
        hush(); draft = ""
        Task { try? await speech.start() }
    }
    func toggleVoice() { voice.toggle(); if !voice { player.stop(); speakingUntil = .distantPast } }
    /// Stops Halo talking and listening (the quiz screen is closing, or moving on).
    func hush() {
        talk?.cancel(); talk = nil; silence?.cancel(); player.stop(); speech.stop(); speakingUntil = .distantPast
    }
    func close() { hush(); token = UUID(); task?.cancel(); task = nil }

    private func ask() {
        picked = nil; draft = ""; stage = .asking
        guard let question else { return }
        say(question.ask, audio: question.audio)
    }
    private func marked(_ mark: Mark, speak line: String, audio: String? = nil) {
        guard let question else { return }
        marks[question.id] = mark
        stage = .marked
        react(mark.right ? .proud : mark.verdict == "almost" ? .happy : .unsure, for: 2.2)
        if mark.right { cheers += 1 }
        say(line, audio: audio)
    }
    private func react(_ mood: TutorMood, for seconds: Double) { reaction = mood; reactionUntil = Date().addingTimeInterval(seconds) }
    /// Halo says a line: the clip that came with it, or one asked for now, or the iPad's voice.
    private func say(_ line: String, audio: String? = nil) {
        talk?.cancel()
        guard voice else { return }
        let server = server, demo = demo
        talk = Task { [weak self] in
            guard let self else { return }
            var clip = audio
            if clip == nil, !demo { clip = try? await client.speak(line, server: server) }
            guard !Task.isCancelled else { return }
            let step = AnswerStep(index: 0, say: line, audio: clip)
            speakingUntil = Date().addingTimeInterval(player.duration(of: step))
            try? await player.play(step)
            if !Task.isCancelled { speakingUntil = .distantPast }
        }
    }
    private func heard(_ text: String) {
        guard stage == .asking else { return }
        draft = text
        // A pause after speaking means the answer is finished.
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self, !Task.isCancelled, !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            speech.stop(); submit()
        }
    }

    // MARK: offline sample (the demo document)
    private static func demoQuiz() async throws -> Quiz {
        try await Task.sleep(for: .seconds(1.2))
        return Quiz(title: "The chain rule", questions: [
            QuizQuestion(kind: "choice", ask: "Why do we multiply by two x when we differentiate x squared plus one, all cubed?",
                         options: ["Two x is the derivative of the outside", "Two x is the derivative of the inside", "It balances the exponent", "The power rule says so"], answer: 1,
                         explain: "The chain rule multiplies by the inside’s derivative, and x squared plus one gives two x.", source: "outside' × inside'"),
            QuizQuestion(kind: "short", ask: "What question should you always ask first when you use the chain rule?",
                         expected: "What's inside? (find the inner function)", explain: "Spotting the inside function tells you what to differentiate second.", source: "always ask: what's inside?"),
            QuizQuestion(kind: "choice", ask: "Using the power rule, what is the derivative of x cubed?",
                         options: ["x squared", "3x squared", "3x cubed", "2x squared"], answer: 1,
                         explain: "Bring the three down and reduce the power by one.", source: "power rule: xⁿ → n·xⁿ⁻¹"),
        ])
    }
    private static func demoGrade(_ question: QuizQuestion, _ answer: String) -> QuizGrade {
        answer.lowercased().contains("inside")
            ? QuizGrade(verdict: "right", say: "Finding the inside function first tells you what to differentiate second.")
            : QuizGrade(verdict: "wrong", say: "Your notes say to ask what’s inside: find the inner function first.")
    }
}

@MainActor
struct QuizView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var coach: QuizCoach
    @ObservedObject var speech: SpeechInput
    @Environment(\.horizontalSizeClass) private var sizeClass
    init(store: StudyStore) { self.store = store; self.coach = store.quizCoach; self.speech = store.quizCoach.speech }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) { content }
                    .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(DeskPaper().ignoresSafeArea())
        .overlay { ConfettiBurst(trigger: coach.cheers).allowsHitTesting(false) }
        .animation(.spring(duration: 0.35), value: coach.stage)
        .animation(.spring(duration: 0.35), value: coach.index)
        .onDisappear { coach.close() }
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(coach.retrying ? "Quiz · the ones you missed" : "Quiz · \(coach.scope)", color: HaloStyle.coral)
                Text(coach.quiz?.title ?? "Quiz on your notes").font(HaloKit.title(28)).foregroundStyle(HaloStyle.text).lineLimit(2)
                if coach.count > 0, coach.stage != .done { progress }
            }
            Spacer(minLength: 8)
            Button { coach.toggleVoice() } label: {
                Image(systemName: coach.voice ? "speaker.wave.2" : "speaker.slash").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44).background(Color.white, in: Circle()).overlay(Circle().stroke(HaloStyle.ink.opacity(0.12)))
                    .foregroundStyle(HaloStyle.text)
            }.buttonStyle(.plain).accessibilityLabel(coach.voice ? "Mute Halo" : "Read questions aloud")
            CloseButton(label: "Back to my notes") { coach.close(); store.closeQuiz() }
        }
    }
    private var progress: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Array((coach.quiz?.questions ?? []).enumerated()), id: \.element.id) { i, q in
                    Capsule().fill(dot(i, q)).frame(width: i == coach.index ? 22 : 9, height: 9)
                }
            }
            Text("Question \(coach.index + 1) of \(coach.count)").font(HaloKit.text(13, .semibold).monospacedDigit()).foregroundStyle(.secondary)
        }
        .animation(.spring(duration: 0.3), value: coach.index)
        .accessibilityElement(children: .ignore).accessibilityLabel("Question \(coach.index + 1) of \(coach.count)")
    }
    private func dot(_ i: Int, _ q: QuizQuestion) -> Color {
        if let mark = coach.marks[q.id] { return mark.right ? HaloKit.leaf : mark.verdict == "almost" ? HaloKit.amber : HaloStyle.coral }
        return i == coach.index ? HaloStyle.ink : HaloStyle.ink.opacity(0.15)
    }

    // MARK: content
    @ViewBuilder private var content: some View {
        switch coach.stage {
        case .loading:
            halo(says: "Reading your notes and writing a few questions…")
            HStack(spacing: 12) { HaloRing(size: 26, working: true); Text("writing your quiz").font(HaloKit.hand(24)).foregroundStyle(HaloStyle.ink) }
                .padding(.leading, 6)
        case .failed(let why):
            halo(says: why)
            HStack(spacing: 12) {
                Button("Try again") { coach.again() }.buttonStyle(PillButtonStyle())
                Button("Back to my notes") { coach.close(); store.closeQuiz() }.buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: false))
            }
        case .done:
            results
        default:
            if let question = coach.question { asking(question) }
        }
    }
    /// Halo, and what it is saying.
    private func halo(says line: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            TutorAvatar(cue: coach.cue, size: sizeClass == .compact ? 88 : 112)
                .frame(width: sizeClass == .compact ? 88 : 112, height: sizeClass == .compact ? 88 : 112)
            Text(line).font(HaloKit.title(23)).foregroundStyle(HaloStyle.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BubbleShape(tail: .leading).fill(Color.white).shadow(color: HaloStyle.ink.opacity(0.1), radius: 12, y: 5))
                .id(line).transition(.opacity)
        }
    }
    @ViewBuilder private func asking(_ question: QuizQuestion) -> some View {
        halo(says: question.ask)
        if question.isChoice { choices(question) } else { shortAnswer(question) }
        if let mark = coach.mark { feedback(mark, question).transition(.move(edge: .bottom).combined(with: .opacity)) }
    }
    private func choices(_ question: QuizQuestion) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
                let marked = coach.stage == .marked
                let right = marked && i == question.answer, wrong = marked && i == coach.picked && i != question.answer
                Button { coach.pick(i) } label: {
                    HStack(spacing: 14) {
                        Text(String(UnicodeScalar(UInt8(65 + i))))
                            .font(HaloKit.text(15, .bold)).frame(width: 34, height: 34)
                            .background(right ? HaloKit.leaf : wrong ? HaloStyle.coral : HaloStyle.ink.opacity(0.08), in: Circle())
                            .foregroundStyle(right || wrong ? .white : HaloStyle.ink)
                        Text(option).font(HaloKit.text(17, .medium)).foregroundStyle(HaloStyle.text)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if right { Image(systemName: "checkmark.circle.fill").foregroundStyle(HaloKit.leaf) }
                        if wrong { Image(systemName: "xmark.circle.fill").foregroundStyle(HaloStyle.coral) }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(right ? HaloKit.leaf : wrong ? HaloStyle.coral : HaloStyle.ink.opacity(0.1), lineWidth: right || wrong ? 2 : 1))
                    .opacity(marked && !right && !wrong ? 0.55 : 1)
                    .contentShape(Rectangle())
                }
                // Not `.disabled`: that greys out the very answers the student needs to read once it is marked.
                .buttonStyle(.plain).allowsHitTesting(coach.stage == .asking)
                .accessibilityLabel("Option \(String(UnicodeScalar(UInt8(65 + i)))): \(option)")
                .accessibilityAddTraits(right ? .isSelected : [])
            }
            if coach.stage == .asking { dontKnow }
        }
    }
    @ViewBuilder private func shortAnswer(_ question: QuizQuestion) -> some View {
        if coach.stage == .asking || coach.stage == .marking {
            VStack(alignment: .leading, spacing: 10) {
                HaloComposer(text: $coach.draft, prompt: speech.isRecording ? "Listening…" : "Type or say your answer…",
                             recording: speech.isRecording, enabled: coach.stage == .asking,
                             microphone: { coach.listen() }, send: { coach.submit() })
                if coach.stage == .marking {
                    HStack(spacing: 10) { HaloRing(size: 18, working: true); Text("checking your answer").font(HaloKit.hand(22)).foregroundStyle(HaloStyle.ink) }
                } else { dontKnow }
            }
        } else if let mark = coach.mark, !mark.answer.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("You said")
                Text(mark.answer).font(HaloKit.hand(26)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(HaloKit.highlight.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
    private var dontKnow: some View {
        Button { coach.reveal() } label: {
            Label("I don’t know, show me", systemImage: "eyes").font(HaloKit.hand(23))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.white, in: Capsule()).overlay(Capsule().stroke(HaloStyle.ink.opacity(0.12)))
                .foregroundStyle(HaloStyle.ink)
        }.buttonStyle(.plain)
    }
    private func feedback(_ mark: QuizCoach.Mark, _ question: QuizQuestion) -> some View {
        let tint = mark.right ? HaloKit.leaf : mark.verdict == "almost" ? HaloKit.amber : HaloStyle.coral
        let last = coach.index + 1 >= coach.count
        return VStack(alignment: .leading, spacing: 12) {
            Label(mark.right ? "Right" : mark.verdict == "almost" ? "Almost" : mark.answer.isEmpty ? "Here’s the answer" : "Not quite",
                  systemImage: mark.right ? "checkmark.circle.fill" : mark.verdict == "almost" ? "circle.lefthalf.filled" : "arrow.uturn.backward.circle.fill")
                .font(HaloKit.text(15, .bold)).foregroundStyle(tint)
            Text(mark.say).font(HaloKit.text(17)).foregroundStyle(HaloStyle.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if !question.isChoice, !mark.right {
                Text("A full answer: \(question.expected)").font(HaloKit.text(15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !question.source.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "text.quote").font(.system(size: 13, weight: .semibold)).foregroundStyle(HaloStyle.ink.opacity(0.6))
                    Text("From your notes: “\(question.source)”").font(HaloKit.hand(22)).foregroundStyle(HaloStyle.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button { coach.next() } label: { Label(last ? "See how I did" : "Next question", systemImage: last ? "flag.checkered" : "arrow.right") }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(tint.opacity(0.45), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
    }

    // MARK: results
    @ViewBuilder private var results: some View {
        let total = coach.count, score = coach.score
        halo(says: score == total ? "Every one. Your notes have this covered." : "\(score) out of \(total). Here’s what to look at again.")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(score)").font(HaloKit.title(64, .semibold).monospacedDigit()).foregroundStyle(score == total ? HaloKit.leaf : HaloStyle.text)
            Text("of \(total) right").font(HaloKit.hand(30)).foregroundStyle(HaloStyle.ink)
        }
        .accessibilityElement(children: .combine)
        VStack(spacing: 10) {
            ForEach(coach.quiz?.questions ?? []) { q in
                let mark = coach.marks[q.id]
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: mark?.right == true ? "checkmark.circle.fill" : mark?.verdict == "almost" ? "circle.lefthalf.filled" : "xmark.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(mark?.right == true ? HaloKit.leaf : mark?.verdict == "almost" ? HaloKit.amber : HaloStyle.coral)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(q.ask).font(HaloKit.text(15.5, .semibold)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
                        if mark?.right != true {
                            Text("Answer: \(q.isChoice ? q.options[q.answer] : q.expected)").font(HaloKit.text(14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        FlowRow(spacing: 12) {
            if !coach.missed.isEmpty {
                Button { coach.retryMissed() } label: { Label("Retry the \(coach.missed.count) I missed", systemImage: "arrow.counterclockwise") }.buttonStyle(PillButtonStyle())
            }
            Button { coach.again() } label: { Label("New quiz", systemImage: "sparkles") }.buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: coach.missed.isEmpty))
            Button { coach.close(); store.closeQuiz() } label: { Label("Back to my notes", systemImage: "square.and.pencil") }.buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: false))
        }
    }
}
