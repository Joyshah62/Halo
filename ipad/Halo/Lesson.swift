import SwiftUI

/// One coach owns the lesson between presentations. Network events and playback are consumed in
/// order. The lesson is a conversation: Halo asks what the student thinks before it teaches
/// (a "hook", never graded), builds on the guess, then hands the idea back with a check.
@MainActor
final class LessonCoach: ObservableObject {
    @Published var chapter: Chapter?
    @Published var sourceTitle = ""
    @Published var plan: LessonPlan?
    @Published var current = 1
    @Published var selected = 1
    @Published var materials: [Int: LessonMaterial] = [:]
    @Published var phase = "source"
    @Published var exampleMoves = 0
    @Published var boards: [Int: StudySession] = [:]
    @Published var question: LessonQuestion?
    @Published var grades: [Int: LessonGrade] = [:]
    @Published var summary: LessonSummary?
    @Published var busy = false
    @Published var waiting = false
    @Published var error: String?
    @Published var caption = ""
    @Published var draft = ""
    @Published var showHint = false
    @Published var voice = true
    @Published var saved = false
    @Published var answers: [String] = []
    /// What the student guessed before each concept was taught. Halo builds its explanation on it.
    @Published var guesses: [Int: String] = [:]
    /// The student's latest line, shown across from Halo's.
    @Published var said = ""
    /// What Halo has laid on the desk for each concept so far ("source", "visual", "example"), in the order it reached for them.
    @Published var shown: [Int: [String]] = [:]
    /// Something the student said while Halo was still talking; it is sent as soon as Halo's turn ends.
    @Published var interjection: String?
    /// Once the student answers by voice, the microphone reopens by itself each time it is their turn.
    @Published var handsFree = false
    // What the avatar says and how it reacts. `spoken` outlives `caption`, so the bubble keeps the last line.
    @Published var spoken = ""
    @Published var spokenAt = Date.distantPast
    @Published var spokenFor: TimeInterval = 0
    @Published var reaction: TutorMood?
    @Published var reactionUntil = Date.distantPast
    @Published var cheers = 0
    /// Where the lesson is happening right now, for the board to scroll to: "top" (Halo and what it's asking),
    /// an exhibit ("source", "visual", "example"), the newest move of the worked example, or the end of Halo's notes.
    /// `beat` changes every time, so the board follows Halo even when it stays on the same card.
    private(set) var attention = "top"
    @Published private(set) var beat = 0
    private func look(_ place: String) { attention = place; beat += 1 }
    let speech = SpeechInput()
    weak var paper: NoteAnimating?
    private let client = HaloClient()
    private let player = AnswerPlayer()
    private var task: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var token = UUID()
    private var server = ""
    private var demo = false
    private var sourcePages: [DigestPage] = []
    private var pending: LessonReply?
    private var demoAttempts = 0
    /// The rest of Halo's turn is written without being spoken, because the student has started talking.
    private var rushing = false
    /// The microphone was opened for an answer: when it closes, what was heard is sent.
    private var sendWhenHeard = false
    private struct Recovery {
        var current: Int; var selected: Int; var materials: [Int: LessonMaterial]; var boards: [Int: StudySession]; var question: LessonQuestion?; var grades: [Int: LessonGrade]; var summary: LessonSummary?
        var guesses: [Int: String]; var shown: [Int: [String]]; var said: String
    }
    private var recovery: Recovery?
    static let exhibits = ["source", "visual", "example"]

    var board: StudySession { boards[selected] ?? StudySession(number: selected, pageIndex: 0, region: nil) }
    var canAnswer: Bool { waiting && !busy && summary == nil && selected == current }
    /// Halo has asked what the student thinks and hasn't taught the concept yet.
    var isHook: Bool { question?.kind == "hook" && summary == nil }
    /// The student can type or talk: to answer when it is their turn, or to cut in while Halo is talking.
    var canSpeak: Bool { plan != nil && summary == nil && selected == current && error == nil && (waiting || busy) }
    var noteText: String {
        var lines = [plan?.title ?? "Lesson", plan?.thread ?? "", ""]
        for concept in plan?.concepts ?? [] {
            lines += ["\(concept.n). \(concept.name) · page \(concept.page)"]
            if let guess = guesses[concept.n], !guess.isEmpty { lines += ["My first guess: \(guess)"] }
            if let material = materials[concept.n] {
                lines += ["Textbook · p. \(material.anchor.page): \(material.anchor.quote)"]
                if let example = material.example { lines += [example.title, example.given] + example.steps + [example.result, example.why] }
                if let web = material.web { lines += ["Web perspective: \(web.text)"] + web.sources.map { "\($0.title): \($0.url)" } }
                lines += material.images.map { "Diagram: \($0.page) · \($0.credit) · \($0.license)" }
            }
            lines += boards[concept.n]?.messages.map(\.text) ?? []
            if let grade = grades[concept.n] { lines += ["Check: \(grade.verdict.replacingOccurrences(of: "_", with: " ")) — \(grade.say)"] }
            lines += [""]
        }
        lines += answers
        if let summary { lines += ["Remember: \(summary.takeaway)", "Revisit: \(summary.revisit.joined(separator: "; "))"] }
        return lines.joined(separator: "\n")
    }
    init() {
        speech.onTranscript = { [weak self] in self?.heard($0) }
        speech.onStopped = { [weak self] in self?.stoppedListening() }
    }
    func reset() {
        token = UUID(); task?.cancel(); task = nil; silence?.cancel(); sendWhenHeard = false; player.stop(); speech.stop()
        plan = nil; boards = [:]; materials = [:]; phase = "source"; exampleMoves = 0; question = nil; grades = [:]; summary = nil; error = nil
        current = 1; selected = 1; busy = false; waiting = false; caption = ""; draft = ""; pending = nil; saved = false; answers = []
        guesses = [:]; said = ""; shown = [:]; interjection = nil; rushing = false; handsFree = false
        spoken = ""; spokenAt = .distantPast; spokenFor = 0; reaction = nil; reactionUntil = .distantPast
    }
    func cue(listening: Bool) -> TutorCue {
        let base: TutorMood = listening ? .listening : busy && Date() >= spokenAt.addingTimeInterval(spokenFor) ? .thinking : !draft.isEmpty ? .attentive : .idle
        return TutorCue(base: base, speakingUntil: spokenAt.addingTimeInterval(spokenFor), reaction: reaction, reactionUntil: reactionUntil)
    }
    var voiceLevel: CGFloat? { player.outputLevel }
    private func react(_ mood: TutorMood, for seconds: TimeInterval = 2.6, cheer: Bool = false) {
        reaction = mood; reactionUntil = Date().addingTimeInterval(seconds)
        if cheer { cheers += 1 }
    }
    func hush() { voice = false; sendWhenHeard = false; handsFree = false; silence?.cancel(); player.stop(); speech.stop() }

    // MARK: Talking to Halo
    /// Tap to talk, tap again (or just stop talking) to send. Talking while Halo is mid-sentence cuts in.
    func toggleMic() {
        if speech.isRecording { silence?.cancel(); speech.stop(); return }
        guard canSpeak else { return }
        handsFree = true
        listen()
    }
    private func listen() {
        if busy { rushing = true }
        player.stop(); draft = ""; sendWhenHeard = true
        Task { [weak self] in
            guard let self else { return }
            do { try await speech.start() } catch { sendWhenHeard = false; handsFree = false }
        }
    }
    private func heard(_ text: String) {
        draft = text
        // A pause after speech means they've finished. No button to press.
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1700))
            guard let self, !Task.isCancelled, speech.isRecording, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            speech.stop()
        }
    }
    private func stoppedListening() {
        silence?.cancel()
        guard sendWhenHeard else { return }
        sendWhenHeard = false
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { handsFree = false } else { reply(spoken: true) }
    }

    func start(_ input: DigestRequest, server: String, demo: Bool, voice: Bool) {
        guard !busy else { return }
        guard !input.pages.isEmpty, input.pages.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            error = "This chapter has no selectable text. Use a PDF with a text layer so Halo can read it."; return
        }
        guard input.pages.count <= 120 else { error = "Choose a chapter of up to 120 pages. This selection is too long for one lesson."; return }
        self.sourcePages = input.pages
        self.server = server; self.demo = demo; self.voice = voice
        if demo { runDemo(start: true); return }
        consume(client.startLesson(input, server: server))
    }
    /// Sends the student's turn: an answer or a question of their own ("answer"), "show me" / "come back to this" ("skip"), or a concept to go over again ("jump").
    func reply(action: String = "answer", concept: Int = 0, spoken: Bool = false) {
        let answer = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let plan, summary == nil, action != "answer" || !answer.isEmpty else { return }
        sendWhenHeard = false; silence?.cancel(); speech.stop()
        if action == "answer" { handsFree = spoken }
        // Halo is still talking: it stops, finishes its notes, and takes this as soon as its turn ends.
        if busy {
            guard action == "answer", selected == current else { return }
            interjection = answer; said = answer; draft = ""; rushing = true; player.stop()
            return
        }
        guard waiting else { return }
        let hook = isHook
        let reply = LessonReply(id: plan.id, answer: answer, action: action, concept: concept)
        recovery = Recovery(current: current, selected: selected, materials: materials, boards: boards, question: question, grades: grades, summary: summary, guesses: guesses, shown: shown, said: said)
        pending = reply
        switch action {
        case "answer":
            answers.append("\(hook ? "My guess" : "You") · \(question?.ask ?? "")\n\(answer)")
            said = answer
            if hook { guesses[current] = answer }
        case "skip": said = hook ? "Show me" : "Let's come back to this one"
        default: break
        }
        draft = ""; selected = current; showHint = false
        if hook { question = nil }
        let opener = action == "answer" ? filler(hook ? "guess" : "answer") : nil
        if demo { runDemo(start: false, reply: reply, hook: hook, filler: opener) } else { consume(client.answerLesson(reply, server: server), filler: opener) }
    }
    func retry() {
        guard !busy, let pending else { return }
        if let recovery {
            current = recovery.current; selected = recovery.selected; boards = recovery.boards; materials = recovery.materials; phase = "source"
            question = recovery.question; grades = recovery.grades; summary = recovery.summary; guesses = recovery.guesses; shown = recovery.shown; said = recovery.said
        }
        consume(client.answerLesson(pending, server: server))
    }
    // Same rules as the server's list (lesson.js): short, no trailing "…", nothing that sounds like right or wrong.
    private static let localFillers = [
        LessonFiller(kind: "guess", say: "Ooh, interesting guess."), LessonFiller(kind: "guess", say: "Nice, let's find out."),
        LessonFiller(kind: "guess", say: "Good instinct. Let's see."),
        LessonFiller(kind: "answer", say: "Got it. Let's check."), LessonFiller(kind: "answer", say: "Alright, let's look at that."),
        LessonFiller(kind: "answer", say: "Right, let's walk through it.")
    ]
    private var lastFiller = ""
    /// A different line from last time, so the same words never play twice in a row.
    private func filler(_ kind: String) -> LessonFiller? {
        let voiced = (plan?.fillers ?? []).filter { $0.kind == kind }
        let pool = voiced.isEmpty ? Self.localFillers.filter { $0.kind == kind } : voiced
        let pick = pool.filter { $0.say != lastFiller }.randomElement() ?? pool.randomElement()
        if let pick { lastFiller = pick.say }
        return pick
    }
    /// What a person says in the second after you answer them. The reply is already on its way while this plays.
    private func murmur(_ filler: LessonFiller) async {
        caption = filler.say; spoken = filler.say; spokenAt = Date()
        if voice, !rushing, filler.audio != nil {
            let step = AnswerStep(index: 0, say: filler.say, audio: filler.audio)
            spokenFor = player.duration(of: step)
            try? await player.play(step)
        } else {
            spokenFor = 0.7
            try? await Task.sleep(for: .milliseconds(750))
        }
    }
    private func consume(_ events: AsyncThrowingStream<AskEvent, Error>, filler: LessonFiller? = nil) {
        busy = true; waiting = false; error = nil; saved = false
        let generation = token
        task = Task {
            do {
                if let filler { await murmur(filler) }
                var done = false
                for try await event in events {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    switch event {
                    case .lesson(let value): try await receive(value)
                    case .step(let step): try await write(step)
                    case .done: done = true
                    case .failure(let message): throw NSError(domain: "Lesson", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                    default: break
                    }
                }
                guard done else { throw HaloError.incompleteStream }
                waiting = summary == nil && question != nil; pending = nil
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            guard generation == token else { return }
            turnEnded()
        }
    }
    /// Halo has finished its turn. If the student cut in, that goes now; if they've been answering out loud, the microphone opens.
    private func turnEnded() {
        busy = false; caption = ""; rushing = false
        if let cut = interjection {
            interjection = nil
            if waiting { draft = cut; reply(spoken: handsFree) } else if summary == nil { draft = cut }
        } else if waiting, handsFree, !speech.isRecording, selected == current { listen() }
    }
    private func say(_ text: String, audio: String?) async throws {
        caption = text
        let words = Double(text.split(whereSeparator: \.isWhitespace).count)
        let aloud = voice && !rushing
        spoken = text; spokenAt = Date()
        spokenFor = aloud ? player.duration(of: AnswerStep(index: 0, say: text, audio: audio)) : min(3.5, 0.5 + words * 0.09)
        if aloud {
            do { try await player.play(AnswerStep(index: 0, say: text, audio: audio)) }
            catch is CancellationError { try Task.checkCancellation() }
            catch { voice = false }
        }
    }
    private func receive(_ event: LessonEvent) async throws {
        try Task.checkCancellation()
        switch event {
        case .plan(let value): plan = value; look("top"); try await say(value.say, audio: value.audio)
        case .concept(let n):
            current = n; selected = n; phase = "source"; exampleMoves = 0; question = nil; showHint = false; demoAttempts = 0
            shown[n] = []; said = ""; guesses[n] = nil
            boards[n] = StudySession(number: n, pageIndex: (plan?.concepts.first { $0.n == n }?.page ?? 1) - 1, region: nil)
            look("top")
        case .material(let value): materials[value.n] = value
        case .question(let value):
            question = value; showHint = false
            // Everything is on the desk to look back at while they think about the check.
            if value.kind != "hook" { shown[value.n] = (shown[value.n] ?? []) + Self.exhibits.filter { !(shown[value.n] ?? []).contains($0) } }
            look("top")
            try await say(value.ask, audio: value.audio)
        case .grade(let value):
            grades[value.n] = value
            if value.verdict == "got_it" { react(.happy, cheer: true) } else if value.verdict == "missed" || value.verdict == "almost" { react(.unsure) }
            look("top")
            try await say(value.say, audio: value.audio)
        case .finish(let value):
            summary = value; selected = 0; question = nil; waiting = false; said = ""
            look("top")
            react(.happy, for: 3.5, cheer: true)
            try await say(value.say, audio: value.audio)
        }
    }
    private func write(_ step: AnswerStep) async throws {
        try Task.checkCancellation()
        var board = boards[current] ?? StudySession(number: current, pageIndex: 0, region: nil)
        board.messages.append(StudyMessage(role: "assistant", text: step.say, ink: step.ink, isDemo: demo))
        boards[current] = board
        if let focus = step.focus, Self.exhibits.contains(focus) {
            // Halo reaches for this part of the desk: it appears (the first time) and takes the spotlight.
            if !(shown[current] ?? []).contains(focus) { shown[current, default: []].append(focus) }
            if focus == "example" { exampleMoves += 1 }
            phase = focus
            look(focus == "example" ? "example-end" : focus)
        } else {
            look("notes-end")
        }
        caption = step.say
        let duration = voice && !rushing ? player.duration(of: step) : rushing ? 0.3 : 0.8
        // Let SwiftUI mount the board before asking its ink renderer to animate.
        await Task.yield()
        let snapshot = board
        async let drawing: Void = paper?.animate(session: snapshot, duration: duration) ?? ()
        try await say(step.say, audio: step.audio)
        await drawing
    }

    // A clearly labelled, local sample. Imported documents always need the live tutor.
    private func sampleMaterial(_ n: Int) -> LessonMaterial {
        let page = n == 1 ? 1 : 2
        let anchor = LessonAnchor(page: page, quote: n == 1 ? "Bring the exponent down. Reduce the power by one." : n == 2 ? "Outside: u³ → 3u².  Inside: x² + 1 → 2x." : "y′ = 3(x² + 1)² × 2x")
        let nodes: [LessonDiagramNode] = n == 1 ? [
            .init(label: "x³", detail: "Start with a power"), .init(label: "3 × x²", detail: "Bring 3 down; subtract 1 from the power")
        ] : [
            .init(label: "x", detail: "The input"), .init(label: "x² + 1", detail: "The inside transforms it"), .init(label: "(x² + 1)³", detail: "The outside cubes the result")
        ]
        let example = n == 1 ? LessonExample(title: "From a rule to a move", given: "Differentiate x⁴", steps: ["The power is 4. Bring it in front.", "Subtract one from the exponent: 4 − 1 = 3."], result: "4x³", why: "The exponent becomes the multiplier and then drops by one.") : LessonExample(title: "Follow the two rates", given: "y = (x² + 1)³", steps: ["Differentiate the outside: 3(x² + 1)²", "The inside also changes: its derivative is 2x.", "Multiply the two rates together."], result: "y′ = 3(x² + 1)² × 2x", why: "Changing x affects both layers, so both rates belong in the answer.")
        return LessonMaterial(n: n, anchor: anchor, headline: n == 1 ? "One exponent. Two moves." : "The output of one function becomes the input of another.", status: "offline", visual: LessonVisual(kind: "flow", title: n == 1 ? "Watch the exponent move" : "Two functions, one journey", nodes: nodes, caption: n == 1 ? "The same rule works for every power." : "Work from the inside out; differentiate both layers."), example: example, images: [])
    }
    private let demoNames = ["the power rule", "a function inside a function", "why the inside matters"]
    private let demoHooks = [
        "So, before I show you anything… x squared turns into two x. Take a guess: what does x cubed turn into?",
        "Okay, next thing. If I cube x squared plus one, which happens first… the cubing, or the x squared plus one?",
        "Now, here's a strange one. The book's answer has an extra two x on the end. Any guess where it comes from?"
    ]
    private let demoLines = [
        ["x³ → 3x²: bring the power down, then subtract one", "xⁿ → n·xⁿ⁻¹"],
        ["(x² + 1)³ is two functions working together", "Inside: x² + 1 → outside: cube the result"],
        ["The inside changes too: d/dx (x² + 1) = 2x", "y′ = 3(x² + 1)² × 2x"]
    ]
    private let demoTalk = [
        ["So the power comes down in front, and then it drops by one. That's the whole move.", "Same thing for any power. Bring it down, knock one off."],
        ["There are two functions here, one tucked inside the other.", "The inside runs first, then the outside cubes whatever comes out."],
        ["Here's the thing… the inside is moving too. Its derivative is two x.", "So both rates multiply together, and that's the extra two x."]
    ]
    private let demoQuestions = ["So, in your own words… what are the two moves?", "In (x² + 1)³, which function is on the inside?", "Say a friend stops at 3(x² + 1)². What did they leave out?"]
    private let demoFollowUps = ["Smaller question, then: where does the exponent go first?", "Which part gets worked out before anything is cubed?", "Does the bit inside the brackets change when x changes?"]
    private func runDemo(start: Bool, reply: LessonReply? = nil, hook: Bool = false, filler: LessonFiller? = nil) {
        busy = true; waiting = false; error = nil
        let generation = token
        task = Task {
            do {
                if let filler { await murmur(filler) }
                var teach = false
                if start {
                    let concepts = demoNames.enumerated().map { LessonConcept(n: $0.offset + 1, name: $0.element, why: ["A move to build on", "See the two layers", "Connect the two rates of change"][$0.offset], page: $0.offset == 0 ? 1 : 2, kind: "idea", minutes: 2) }
                    try await receive(.plan(LessonPlan(id: "offline", title: "The chain rule", thread: "From one simple rule to two functions working together.", say: "Okay, this one's really a single idea in three stops. We'll start with powers and build up to why the inside matters.", concepts: concepts)))
                    try await openDemo(1)
                } else if let reply {
                    if reply.action == "jump" { try await receive(.concept(reply.concept)); teach = true }
                    else if hook { teach = true }
                    else {
                        let a = reply.answer.lowercased()
                        let right = current == 1 ? ((a.contains("down") || a.contains("front")) && (a.contains("one") || a.contains("1"))) : current == 2 ? (a.contains("x² + 1") || a.contains("squared plus one") || a.contains("x^2 + 1")) : (a.contains("inside") && (a.contains("change") || a.contains("derivative")))
                        let skipped = reply.action == "skip"
                        let n = current
                        try await receive(.grade(LessonGrade(n: n, verdict: skipped ? "skipped" : right ? "got_it" : "missed", say: skipped ? "No problem, we'll leave that one for now." : right ? "“\(reply.answer.prefix(40))”… yes. That's the connection we needed." : "That's on me, let me put it differently. The sample shows the loop; the live tutor works from your own words.", note: "")))
                        if right || skipped {
                            if n >= demoNames.count {
                                let got = demoNames.enumerated().filter { grades[$0.offset + 1]?.verdict == "got_it" }.map(\.element)
                                try await receive(.finish(LessonSummary(say: "That's our three-stop sample. Your notes show what clicked and what to revisit.", nailed: got, revisit: demoNames.filter { !got.contains($0) }.map { "\($0): try one more example" }, takeaway: "Outside derivative × inside derivative. Keep both rates of change.", mastery: grades.values.map { LessonMastery(n: $0.n, verdict: $0.verdict) })))
                            } else { try await openDemo(n + 1) }
                        } else {
                            demoAttempts += 1
                            try await receive(.question(LessonQuestion(n: n, kind: "open", ask: demoFollowUps[n - 1], options: [], hint: "Look at the worked example on the desk.", again: true, style: "explain")))
                        }
                    }
                }
                if teach {
                    let n = current
                    materials[n] = sampleMaterial(n)
                    for (index, line) in demoLines[n - 1].enumerated() {
                        let opening = index == 0 && hook ? (guesses[n].map { "You said “\($0.prefix(40))”… hold onto that. " } ?? "") : ""
                        try await write(AnswerStep(index: index, say: opening + demoTalk[n - 1][index], ink: [InkItem(type: "text", value: line)], focus: index == 0 ? "visual" : "example"))
                    }
                    try await receive(.question(LessonQuestion(n: n, kind: n == 2 ? "choice" : "open", ask: demoQuestions[n - 1], options: n == 2 ? ["x² + 1", "u³", "3u²"] : [], hint: ["Where does the exponent go? What happens to its value?", "What gets computed before cubing?", "Does the expression inside the brackets change with x?"][n - 1], style: ["explain", "choice", "spot_the_slip"][n - 1])))
                }
                waiting = summary == nil && question != nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            guard !Task.isCancelled, generation == token else { return }
            turnEnded()
        }
    }
    private func openDemo(_ n: Int) async throws {
        try await receive(.concept(n))
        materials[n] = LessonMaterial(n: n, anchor: sampleMaterial(n).anchor, headline: "", status: "offline", visual: nil, example: nil, images: [])
        try await receive(.question(LessonQuestion(n: n, kind: "hook", ask: demoHooks[n - 1], options: [], hint: "", style: "guess")))
    }
}

@MainActor
struct LessonBoard: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var coach: LessonCoach
    @ObservedObject var speech: SpeechInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var source = false
    @State private var showWeb = false
    @State private var introAt = Date()
    @State private var paperWidth: CGFloat = 320
    /// The last time the student scrolled the board themselves. Halo doesn't pull the page away from them for a moment after.
    @State private var touchedAt = Date.distantPast
    @State private var following: Task<Void, Never>?
    @FocusState private var typing: Bool
    init(store: StudyStore) { self.store = store; coach = store.lesson; speech = store.lesson.speech }

    private var viewingEarlier: Bool { coach.selected != coach.current && coach.summary == nil }
    private var onHook: Bool { coach.isHook && coach.selected == coach.current }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 850
            let side: CGFloat = wide ? 30 : 16
            Group {
                if coach.plan == nil {
                    VStack(spacing: 0) {
                        header.padding(.horizontal, side).padding(.vertical, 14)
                        introduction
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 18) {
                                header.id("top")
                                journey(wide: wide)
                                if let summary = coach.summary, coach.selected == 0 {
                                    completion(summary, wide: wide)
                                } else {
                                    stage(wide: wide)
                                    desk(wide: wide)
                                }
                            }
                            .padding(.horizontal, side).padding(.top, 14).padding(.bottom, 24)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .modifier(NoticesScrolling { touchedAt = Date() })
                        // Follow the lesson: wherever Halo is talking, writing or asking, the board scrolls there.
                        .onChange(of: coach.beat) { _, _ in follow(coach.attention, proxy: proxy) }
                        .onChange(of: coach.exampleMoves) { old, new in if new > old { follow("example-end", proxy: proxy, asked: !coach.busy) } }
                        .onChange(of: coach.selected) { _, _ in follow("top", proxy: proxy, asked: true) }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if coach.selected != 0 {
                            dock.padding(.horizontal, side).padding(.vertical, 10)
                                .background(HaloStyle.paper.opacity(0.97))
                        }
                    }
                }
            }
            .background(DeskPaper().ignoresSafeArea())
            .foregroundStyle(HaloStyle.text)
            .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.12), value: coach.current)
            .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.12), value: coach.shown)
            .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15), value: coach.said)
            .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.1), value: coach.question)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: coach.selected)
        }
        .sheet(isPresented: $source) { sourcePage }
        .onDisappear { coach.hush() }
        .onChange(of: coach.selected) { _, _ in showWeb = false }
        .onAppear { RemoteImageCache.relay = try? HaloClient.endpoint(store.serverURL, path: "api/dive/picture") }
    }

    /// Scrolls the board to where the lesson is happening. Halo's own moves wait if the student has just scrolled
    /// somewhere themselves (a new stop or a question to answer still brings them back); taps the student made always go.
    private func follow(_ place: String, proxy: ScrollViewProxy, asked: Bool = false) {
        let important = place == "top"
        if !asked {
            guard !viewingEarlier || important else { return }
            guard important || Date().timeIntervalSince(touchedAt) > 4 else { return }
        }
        // Where the new thing sits on screen: the top of a card Halo picks up, the bottom of something that just grew.
        let anchor: UnitPoint = place.hasSuffix("-end") ? UnitPoint(x: 0.5, y: 0.92) : place == "top" ? .top : UnitPoint(x: 0.5, y: 0.04)
        following?.cancel()
        following = Task { @MainActor in
            // Let the new card, move or line of notes lay out first, so the scroll lands on it rather than above it.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.08)) { proxy.scrollTo(place, anchor: anchor) }
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 14) {
            HaloRing(size: 38, working: coach.busy)
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(store.demoMode ? "HALO · OFFLINE SAMPLE" : "HALO · YOUR CHAPTER, TOGETHER", color: HaloStyle.coral)
                Text(coach.plan?.title ?? "A tutor. Your book. Your pace.").font(HaloKit.title(26)).fixedSize(horizontal: false, vertical: true)
                if let thread = coach.plan?.thread, !thread.isEmpty {
                    Text(thread).hand(21).foregroundStyle(HaloStyle.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            roundButton(coach.voice ? "speaker.wave.2" : "speaker.slash", label: coach.voice ? "Mute tutor" : "Read aloud") { coach.voice.toggle(); if !coach.voice { coach.hush() } }
            roundButton(coach.saved ? "checkmark" : "square.and.arrow.down", label: "Save lesson to my notes") { store.saveLesson() }
                .disabled(coach.plan == nil || coach.busy || coach.saved)
            HomeButton { Task { await store.goHome() } }
            CloseButton(label: "Return to book; keep lesson") { store.showLesson = false }
        }
    }
    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                .background(Color.white, in: Circle()).overlay(Circle().stroke(HaloStyle.ink.opacity(0.12))).foregroundStyle(HaloStyle.text)
                .contentTransition(.symbolEffect(.replace))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    // MARK: Before the lesson
    private var greeting: String {
        let name = store.learner.name.trimmingCharacters(in: .whitespaces)
        let what = coach.chapter.map { "“\($0.title)”" } ?? "this chapter"
        return "Hi\(name.isEmpty ? "" : " \(name)")! I'm Halo. Let's go through \(what) together. I'll ask what you think before I explain anything, so just talk to me like I'm sitting next to you."
    }
    private static let readingLines = ["Reading your chapter…", "Finding the ideas that matter…", "Working out how they connect…", "Thinking about what to ask you first…", "Picking examples you can try…"]
    private var introduction: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 26) {
                    ZStack {
                        Circle().fill(RadialGradient(colors: [HaloStyle.coral.opacity(0.14), .clear], center: .center, startRadius: 40, endRadius: 260)).frame(width: 520, height: 520)
                        TutorAvatar(cue: coach.busy ? TutorCue(base: .thinking) : TutorCue(base: .idle, speakingUntil: introAt.addingTimeInterval(introFor)), size: 230,
                                    voiceLevel: { nil })
                    }.frame(height: 300)
                    TutorBubble(text: greeting, spokenAt: introAt, duration: introFor, cue: coach.busy ? TutorCue(base: .thinking) : TutorCue(base: .idle, speakingUntil: introAt.addingTimeInterval(introFor)), fontSize: 24, tail: .top)
                        .frame(maxWidth: 620)
                    Text("Make it make sense.").font(HaloKit.title(52, .regular)).tracking(-1.5).multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        ScribbleChip(text: coach.chapter.map { "pages \($0.start + 1)–\($0.end + 1)" } ?? store.displayTitle, icon: "book")
                        ScribbleChip(text: "asks what you think", icon: "questionmark.bubble")
                        ScribbleChip(text: "just talk back", icon: "waveform")
                    }
                    if store.demoMode { Text("Offline sample · a scripted chain-rule lesson. Turn off sample answers in Settings to teach an imported chapter.").font(HaloKit.text(13)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    errors.frame(maxWidth: 620)
                    Button { store.beginLesson() } label: {
                        HStack(spacing: 12) {
                            if coach.busy {
                                ProgressView().tint(.white)
                                TimelineView(.periodic(from: .now, by: 2.2)) { context in
                                    let i = Int(context.date.timeIntervalSinceReferenceDate / 2.2) % Self.readingLines.count
                                    Text(Self.readingLines[i]).contentTransition(.opacity).animation(.easeInOut, value: i)
                                }
                            } else { Text("Teach me"); Image(systemName: "sparkles") }
                        }
                        .font(HaloKit.text(18, .semibold)).padding(.horizontal, 30).padding(.vertical, 18)
                        .background(LinearGradient(colors: [HaloStyle.ink, Color(red: 0.48, green: 0.24, blue: 0.86), HaloStyle.coral], startPoint: .leading, endPoint: .trailing), in: Capsule())
                        .foregroundStyle(.white).shadow(color: HaloStyle.coral.opacity(0.35), radius: 18, y: 8)
                    }.buttonStyle(.plain).disabled(coach.busy).accessibilityLabel("Build my lesson")
                }.padding(40).frame(maxWidth: .infinity).frame(minHeight: geo.size.height)
            }
        }
        .onAppear { introAt = Date() }
    }
    private var introFor: TimeInterval { Double(greeting.split(separator: " ").count) * 0.16 }

    // MARK: The journey: every stop of the lesson, and where we are on it
    private func journey(wide: Bool) -> some View {
        let concepts = coach.plan?.concepts ?? []
        return HStack(alignment: .top, spacing: 0) {
            ForEach(concepts) { concept in
                let reached = coach.boards[concept.n] != nil
                Button { if reached { coach.selected = concept.n } } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            HStack(spacing: 0) {
                                TrailLine(walked: concept.n <= coach.current || coach.summary != nil).opacity(concept.n == concepts.first?.n ? 0 : 1)
                                TrailLine(walked: concept.n < coach.current || coach.summary != nil).opacity(concept.n == concepts.last?.n ? 0 : 1)
                            }
                            JourneyStop(number: concept.n, verdict: coach.grades[concept.n]?.verdict, here: concept.n == coach.current && coach.summary == nil, viewing: concept.n == coach.selected)
                        }.frame(height: 44)
                        if wide || concept.n == coach.selected {
                            Text(concept.name).font(HaloKit.text(12.5, concept.n == coach.selected ? .semibold : .regular))
                                .foregroundStyle(reached ? HaloStyle.text : HaloStyle.text.opacity(0.45))
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                        }
                    }.frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!reached)
                    .accessibilityLabel("Stop \(concept.n): \(concept.name)")
            }
        }
    }

    // MARK: The stage: Halo, what it's saying, and what you last said back
    private func stage(wide: Bool) -> some View {
        let cue = coach.cue(listening: speech.isRecording)
        let fallback = viewingEarlier ? "We covered this one earlier. Have another look, then come back to where we were."
            : coach.question != nil ? (coach.question?.ask ?? "")
            : coach.plan?.say ?? ""
        let text = coach.spoken.isEmpty || viewingEarlier ? fallback : coach.spoken
        return HStack(alignment: .top, spacing: wide ? 22 : 14) {
            ZStack {
                TutorAvatar(cue: cue, size: wide ? 128 : 92, voiceLevel: { [coach] in coach.voiceLevel }, micLevel: { [speech] in CGFloat(speech.meter.value) })
                ConfettiBurst(trigger: coach.cheers).frame(width: 460, height: 380)
            }
            .frame(width: wide ? 134 : 96, height: wide ? 144 : 104)
            VStack(alignment: .trailing, spacing: 8) {
                TutorBubble(text: text, spokenAt: text == coach.spoken ? coach.spokenAt : .distantPast, duration: text == coach.spoken ? coach.spokenFor : 0, cue: cue, fontSize: wide ? 21 : 18)
                    .animation(.spring(duration: 0.35), value: text)
                if !coach.said.isEmpty, !viewingEarlier, coach.said != coach.guesses[coach.current] || coach.question == nil {
                    HStack(spacing: 8) {
                        if coach.interjection != nil { Text("Halo's wrapping up, then it's yours").font(HaloKit.text(12)).foregroundStyle(.secondary) }
                        Text(coach.said).hand(23).foregroundStyle(HaloStyle.ink).fixedSize(horizontal: false, vertical: true)
                        Text("YOU").font(HaloKit.text(9.5, .bold)).tracking(1.2).foregroundStyle(HaloStyle.ink.opacity(0.6))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(HaloStyle.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .accessibilityLabel("You said: \(coach.said)")
                }
            }
        }
        .zIndex(1)
    }

    // MARK: The desk: what Halo has put in front of you
    @ViewBuilder private func desk(wide: Bool) -> some View {
        if onHook { hunch }
        else if wide {
            HStack(alignment: .top, spacing: 20) {
                exhibits(notes: false)
                notepad.frame(width: 320).fixedSize(horizontal: false, vertical: true)
            }
        } else { exhibits(notes: true) }
    }
    /// Halo has asked what you think. Nothing to read yet: the desk is clear so the only thing on it is the question.
    private var hunch: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            HaloRing(size: 92, symbol: "questionmark").breathing()
            Text("What's your hunch?").font(HaloKit.title(42)).tracking(-1).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("no wrong answers. a guess just tells me where to start").hand(26).foregroundStyle(HaloStyle.ink).multilineTextAlignment(.center)
            if let concept = coach.plan?.concepts.first(where: { $0.n == coach.current }) {
                ScribbleChip(text: "stop \(concept.n) of \(coach.plan?.concepts.count ?? 0) · about \(concept.minutes) min", icon: "mappin.and.ellipse").padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
    private func exhibits(notes: Bool) -> some View {
        let n = coach.selected
        let material = coach.materials[n]
        let laid = viewingEarlier || coach.summary != nil ? LessonCoach.exhibits : coach.shown[n] ?? []
        return VStack(alignment: .leading, spacing: 18) {
                    if let guess = coach.guesses[n], !guess.isEmpty {
                        Sticky(label: "Your hunch", tilt: -0.8) { Text(guess).hand(27).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true) }
                            .frame(maxWidth: 360, alignment: .leading).padding(.leading, 4).transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    if let material {
                        ForEach(laid, id: \.self) { kind in
                            exhibit(kind, material).id(kind)
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(HaloStyle.coral.opacity(spotlight(kind) ? 0.55 : 0), lineWidth: 2))
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                        if laid.count == LessonCoach.exhibits.count { extras(material) }
                    }
                    if laid.isEmpty || material == nil {
                        HStack(spacing: 10) { HaloRing(size: 22, working: true); Text(coach.busy ? "Halo's working out where to start…" : "Nothing on the desk yet.").hand(24).foregroundStyle(HaloStyle.ink) }
                            .padding(.vertical, 22).padding(.horizontal, 6)
                    }
                    if notes { notepad }
        }.padding(.horizontal, 3).padding(.top, 10).padding(.bottom, 8)
    }
    /// The card Halo is talking about right now gets a coral edge.
    private func spotlight(_ kind: String) -> Bool { coach.busy && coach.phase == kind && coach.selected == coach.current }
    @ViewBuilder private func exhibit(_ kind: String, _ material: LessonMaterial) -> some View {
        switch kind {
        case "visual": pictureCard(material)
        case "example": exampleCard(material)
        default: bookCard(material)
        }
    }
    private func bookCard(_ material: LessonMaterial) -> some View {
        HStack(alignment: .top, spacing: 20) {
            if let page = store.pdf?.page(at: material.anchor.page - 1) {
                Button { source = true } label: {
                    Taped(tilt: -2.2) {
                        Image(uiImage: page.thumbnail(of: CGSize(width: 330, height: 420), for: .cropBox)).resizable().scaledToFit().frame(width: 104, height: 132)
                    }
                }.buttonStyle(.plain).padding(.top, 8).accessibilityLabel("Open page \(material.anchor.page) of the book")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Eyebrow("IN YOUR BOOK · PAGE \(material.anchor.page)", color: HaloStyle.coral)
                    Spacer()
                    Button { source = true } label: { Label("Open the page", systemImage: "arrow.up.right").font(HaloKit.text(12.5, .medium)) }.buttonStyle(.plain).foregroundStyle(HaloStyle.ink)
                }
                if !material.headline.isEmpty { Text(material.headline).font(HaloKit.title(23)).fixedSize(horizontal: false, vertical: true) }
                if !material.anchor.quote.isEmpty {
                    Text("“\(material.anchor.quote)”").font(HaloKit.title(18)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(HaloKit.highlight.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }.haloCard(padding: 20)
    }
    @ViewBuilder private func pictureCard(_ material: LessonMaterial) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let scene = material.scene3d, scene.isSupported { Scene3DCard(store: store, scene: scene) }
            if let visual = material.visual, !visual.nodes.isEmpty {
                Eyebrow("PICTURE IT", color: HaloStyle.coral)
                if !visual.title.isEmpty { Text(visual.title).font(HaloKit.title(23)) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) {
                        ForEach(Array(visual.nodes.enumerated()), id: \.offset) { index, node in
                            diagramNode(node, index: index).frame(width: 150).arrives(index * 3)
                            if index < visual.nodes.count - 1 { Image(systemName: visual.kind == "compare" ? "arrow.left.arrow.right" : "arrow.right").font(.system(size: 15, weight: .bold)).foregroundStyle(HaloStyle.coral).arrives(index * 3 + 2) }
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(visual.nodes.enumerated()), id: \.offset) { index, node in
                            diagramNode(node, index: index).frame(maxWidth: .infinity).arrives(index * 3)
                            if index < visual.nodes.count - 1 { Image(systemName: visual.kind == "compare" ? "arrow.up.arrow.down" : "arrow.down").font(.system(size: 15, weight: .bold)).foregroundStyle(HaloStyle.coral).padding(.leading, 22).arrives(index * 3 + 2) }
                        }
                    }
                }
                if visual.kind == "cycle" { Label("and round again", systemImage: "arrow.uturn.backward").font(HaloKit.hand(21)).foregroundStyle(HaloStyle.coral) }
                if !visual.caption.isEmpty { Text(visual.caption).hand(24).foregroundStyle(HaloStyle.ink).fixedSize(horizontal: false, vertical: true) }
            } else {
                Label(material.status == "searching" ? "Halo's sketching this…" : "Halo's notes have the picture for this one.", systemImage: "scribble.variable").font(HaloKit.hand(23)).foregroundStyle(HaloStyle.ink)
            }
        }.haloCard(padding: 20)
    }
    private func diagramNode(_ node: LessonDiagramNode, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(index + 1)").font(HaloKit.hand(22)).foregroundStyle(HaloStyle.coral)
            Text(node.label).font(HaloKit.title(20, .medium)).foregroundStyle(HaloStyle.ink).fixedSize(horizontal: false, vertical: true)
            Text(node.detail).font(HaloKit.text(13)).lineSpacing(2).foregroundStyle(HaloStyle.text.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(HaloStyle.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HaloStyle.ink.opacity(0.14)))
    }
    @ViewBuilder private func exampleCard(_ material: LessonMaterial) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let example = material.example, !example.steps.isEmpty {
                let moves = coach.selected == coach.current && coach.summary == nil ? min(coach.exampleMoves, example.steps.count) : example.steps.count
                Eyebrow("WORK IT THROUGH", color: HaloStyle.coral)
                if !example.title.isEmpty { Text(example.title).font(HaloKit.title(23)) }
                Text(example.given).font(HaloKit.title(25, .medium)).foregroundStyle(HaloStyle.ink).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(example.steps.prefix(moves).enumerated()), id: \.offset) { index, move in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(HaloKit.hand(26)).foregroundStyle(HaloStyle.coral).frame(width: 24)
                        Text(move).font(HaloKit.text(17)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }.transition(.opacity.combined(with: .move(edge: .top)))
                }
                if moves < example.steps.count {
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { coach.exampleMoves = moves + 1 }
                    } label: { Label(moves == 0 ? "Show the first move" : "Show the next move", systemImage: "plus.circle") }
                        .buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: false))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(example.result).font(HaloKit.title(27, .medium)).foregroundStyle(HaloStyle.ink).fixedSize(horizontal: false, vertical: true)
                        if !example.why.isEmpty { Text(example.why).hand(23).fixedSize(horizontal: false, vertical: true) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(HaloKit.highlight, in: RoundedRectangle(cornerRadius: 6)).transition(.opacity)
                }
            } else {
                Label(material.status == "searching" ? "Halo's picking a small example…" : "Ask Halo for an example below.", systemImage: "pencil.and.outline").font(HaloKit.hand(23)).foregroundStyle(HaloStyle.ink)
            }
        }.haloCard(padding: 20)
        // The newest move is at the bottom of the card: this is where the board scrolls when Halo adds one.
        .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id("example-end") }
    }
    /// From outside the book: a second explanation with its sources, and credited pictures.
    @ViewBuilder private func extras(_ material: LessonMaterial) -> some View {
        if material.status == "searching" {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for another way to show this…") }.font(HaloKit.text(12)).foregroundStyle(.secondary).padding(.leading, 6)
        }
        if let web = material.web {
            DisclosureGroup(isExpanded: $showWeb) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(web.heading).font(HaloKit.title(18, .medium))
                    Text(web.text).font(HaloKit.text(15)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    FlowRow(spacing: 8) {
                        ForEach(Array(web.sources.enumerated()), id: \.offset) { _, item in
                            if let url = webURL(item.url) {
                                Link(destination: url) { Label(item.site, systemImage: "arrow.up.right").font(HaloKit.text(12, .medium)).padding(8).background(HaloStyle.ink.opacity(0.07), in: Capsule()) }
                                    .accessibilityLabel("Source: \(item.title)")
                            }
                        }
                    }
                    Text("Supplementary explanation from the web. Your textbook sets the lesson’s scope.").font(HaloKit.text(11)).foregroundStyle(.secondary)
                }.padding(.top, 12)
            } label: { Label("Another angle · \(web.sources.first?.site ?? "web")", systemImage: "globe").font(HaloKit.text(13.5, .medium)) }
            .tint(HaloStyle.ink).haloCard(radius: 18, padding: 16)
        }
        ForEach(material.images) { picture in
            if let url = webURL(picture.page) {
                VStack(alignment: .leading, spacing: 8) {
                    Link(destination: url) {
                        RemoteImage(url: webURL(picture.thumb), fill: false) { _ in Image(systemName: "photo").foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity).frame(height: 200).background(Color.white)
                    }
                    Text(picture.title).font(HaloKit.text(14, .medium))
                    Link("\(picture.credit) · \(picture.license) · source ↗", destination: url).font(HaloKit.text(11))
                }.haloCard(radius: 18, padding: 14)
            }
        }
    }
    /// Halo's own handwriting, written in time with its voice.
    private var notepad: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line").font(.system(size: 12, weight: .bold)).foregroundStyle(HaloStyle.ink)
                Eyebrow("HALO'S NOTES", color: HaloStyle.ink)
                Spacer()
            }
            ZStack(alignment: .topLeading) {
                LessonPaper(coach: coach, session: coach.board)
                if coach.board.messages.isEmpty {
                    Text("I'll jot things down here as we talk.").hand(23).foregroundStyle(HaloStyle.text.opacity(0.35)).padding(.top, 6)
                }
            }
            .frame(height: max(180, InkLayout.height(of: coach.board) * max(1, paperWidth - 32) / InkLayout.width))
        }
        .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id("notes-end") }
        .padding(16)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paperWidth = $0 }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(HaloStyle.coral.opacity(0.25)).frame(width: 1.5).padding(.leading, 9) }
        .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
        .rotationEffect(.degrees(0.5))
        .padding(.top, 10).padding(.bottom, 6)
    }
    private func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    // MARK: The dock: your side of the conversation
    private var turnLabel: String {
        if speech.isRecording { return "I'M LISTENING · PAUSE WHEN YOU'RE DONE" }
        guard let question = coach.question, coach.waiting else { return coach.interjection != nil ? "GOT IT · ONE SECOND" : "HALO'S TALKING · JUMP IN ANY TIME" }
        if question.kind == "hook" { return "JUST A GUESS · NO WRONG ANSWERS" }
        if question.again == true { return "YOUR TURN · ONE SMALL STEP" }
        switch question.style {
        case "predict": return "YOUR TURN · WHAT HAPPENS NEXT?"
        case "next_move": return "YOUR MOVE"
        case "spot_the_slip": return "YOUR TURN · SPOT THE SLIP"
        case "choice": return "YOUR TURN · PICK ONE"
        default: return "YOUR TURN · IN YOUR OWN WORDS"
        }
    }
    private var prompt: String {
        speech.isRecording ? "Listening…" : "Ask Halo or share your answer…"
    }
    @ViewBuilder private var dock: some View {
        if viewingEarlier {
            HStack(spacing: 12) {
                Button { coach.selected = coach.current } label: { Label("Back to where we were", systemImage: "arrow.right") }.buttonStyle(PillButtonStyle(color: HaloStyle.ink))
                if coach.waiting { Button("Go over this one again") { coach.reply(action: "jump", concept: coach.selected) }.buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: false)) }
                Spacer()
            }.padding(.vertical, 6)
        } else if coach.summary != nil {
            Button { coach.selected = 0 } label: { Label("Back to my recap", systemImage: "arrow.right") }.buttonStyle(PillButtonStyle(color: HaloStyle.ink)).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 11) {
                errors
                HStack(spacing: 8) {
                    Circle().fill(coach.waiting || speech.isRecording ? HaloStyle.coral : HaloStyle.ink.opacity(0.35)).frame(width: 7, height: 7)
                    Eyebrow(turnLabel, color: coach.waiting || speech.isRecording ? HaloStyle.coral : HaloStyle.text.opacity(0.5))
                }
                if let question = coach.question, question.kind == "choice", coach.waiting {
                    FlowRow(spacing: 10) { ForEach(question.options, id: \.self) { option in choice(option) } }
                }
                if coach.showHint, let hint = coach.question?.hint, !hint.isEmpty {
                    Label { Text(hint).hand(24) } icon: { Image(systemName: "lightbulb") }.font(HaloKit.hand(24)).foregroundStyle(HaloStyle.ink).transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                HaloComposer(text: $coach.draft, prompt: prompt, recording: speech.isRecording,
                             enabled: coach.canSpeak, microphone: { coach.toggleMic() },
                             focus: $typing, send: { coach.reply() })
                quickReplies.disabled(!coach.canAnswer)
                if let error = speech.lastError { Text(error).font(HaloKit.text(12)).foregroundStyle(.red) }
            }
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(HaloStyle.coral.opacity(coach.waiting ? 0.35 : 0), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.09), radius: 20, y: 8)
        }
    }
    /// One-tap things a student says to a tutor.
    private var quickReplies: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
            if coach.isHook {
                quick("No idea, show me", icon: "eyes") { coach.reply(action: "skip") }
            } else {
                if let hint = coach.question?.hint, !hint.isEmpty {
                    quick(coach.showHint ? "Hide the nudge" : "Give me a nudge", icon: "lightbulb") { withAnimation(.spring(duration: 0.3)) { coach.showHint.toggle() } }
                }
                quick("Say it another way", icon: "arrow.triangle.2.circlepath") { send("Can you say that another way?") }
                quick("Show me an example", icon: "pencil.and.outline") { send("Can you show me an example?") }
                quick("Why does that work?", icon: "questionmark") { send("Why does that work?") }
                quick("Come back to this", icon: "arrow.uturn.right") { coach.reply(action: "skip") }
            }
            }.fixedSize(horizontal: true, vertical: false).padding(.vertical, 3)
        }
    }
    private func send(_ text: String) { coach.draft = text; coach.reply() }
    private func quick(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ScribbleChip(text: text, icon: icon, tint: HaloStyle.ink) }.buttonStyle(.plain)
    }
    private func choice(_ option: String) -> some View {
        Button { coach.draft = option; coach.reply() } label: {
            Text(option).font(HaloKit.title(19, .medium)).padding(.horizontal, 20).padding(.vertical, 12)
                .background(HaloStyle.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HaloStyle.ink.opacity(0.22)))
                .foregroundStyle(HaloStyle.ink)
        }.buttonStyle(.plain).disabled(!coach.canAnswer)
    }

    // MARK: The end
    private func completion(_ summary: LessonSummary, wide: Bool) -> some View {
        let concepts = coach.plan?.concepts ?? []
        return VStack(alignment: .leading, spacing: 24) {
                stage(wide: wide)
                Text("Look what\nyou connected.").font(HaloKit.title(46)).tracking(-1).arrives(1)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(concepts) { concept in
                        let got = summary.nailed.contains(concept.name)
                        let reason = summary.revisit.first { $0.hasPrefix(concept.name + ":") }.map { String($0.dropFirst(concept.name.count + 1)).trimmingCharacters(in: .whitespaces) }
                        Button { if coach.boards[concept.n] != nil { coach.selected = concept.n } } label: {
                            HStack(alignment: .center, spacing: 14) {
                                JourneyStop(number: concept.n, verdict: got ? "got_it" : "skipped", here: false, viewing: false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(concept.name).font(HaloKit.title(18, .medium))
                                    Text(got ? "you've got this" : reason ?? "worth another look").hand(22).foregroundStyle(got ? HaloKit.leaf : HaloKit.amber)
                                }
                                Spacer(minLength: 0)
                                if coach.boards[concept.n] != nil { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).arrives(concept.n + 1)
                    }
                }.haloCard(padding: 20)
                if !summary.takeaway.isEmpty {
                    Sticky(label: "The one thing to remember", tilt: -1) { Text(summary.takeaway).hand(31).fixedSize(horizontal: false, vertical: true) }
                        .frame(maxWidth: 560).arrives(concepts.count + 2)
                }
                errors
                HStack(spacing: 12) {
                    Button { store.saveLesson() } label: { Label(coach.saved ? "Saved in My notes" : "Keep my lesson notes", systemImage: coach.saved ? "checkmark" : "square.and.arrow.down") }
                        .buttonStyle(PillButtonStyle()).disabled(coach.saved || coach.busy)
                    Button("Start a fresh lesson") { coach.reset() }.buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: false)).disabled(coach.busy)
                }.arrives(concepts.count + 3)
            }.padding(.vertical, 10).padding(.horizontal, 3).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
    }
    @ViewBuilder private var errors: some View {
        if let error = coach.error {
            VStack(alignment: .leading, spacing: 10) {
                Text(error).font(HaloKit.text(14)).foregroundStyle(.red)
                if coach.plan != nil {
                    HStack(spacing: 10) {
                        Button("Try that again") { coach.retry() }.buttonStyle(PillButtonStyle(color: HaloStyle.ink))
                        Button("Restart lesson") { coach.reset(); store.beginLesson() }.buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: false))
                    }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }
    private var sourcePage: some View {
        NavigationStack {
            if let concept = coach.plan?.concepts.first(where: { $0.n == coach.selected }), let page = store.pdf?.page(at: (coach.materials[coach.selected]?.anchor.page ?? concept.page) - 1) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Page \(coach.materials[coach.selected]?.anchor.page ?? concept.page) · \(concept.name)").font(HaloKit.text(17, .semibold))
                        Image(uiImage: page.thumbnail(of: CGSize(width: 1300, height: 1800), for: .cropBox)).resizable().scaledToFit()
                    }.padding()
                }.background(HaloStyle.paper).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Back to lesson") { source = false } } }
            }
        }
    }
}

/// One stop on the lesson's journey: a number until it's reached, a coral ring while we're on it, a green tick once it's understood.
private struct JourneyStop: View {
    let number: Int
    let verdict: String?
    let here: Bool
    let viewing: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let got = verdict == "got_it", left = verdict == "skipped"
        ZStack {
            if here {
                Circle().stroke(HaloStyle.coral.opacity(0.35), lineWidth: 2).frame(width: 36, height: 36)
                    .scaleEffect(pulse ? 1.45 : 1).opacity(pulse ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(got ? HaloKit.leaf : Color.white).frame(width: 36, height: 36)
                .overlay(Circle().stroke(got ? HaloKit.leaf : here ? HaloStyle.coral : left ? HaloKit.amber.opacity(0.7) : HaloStyle.ink.opacity(0.18), lineWidth: here ? 3 : 1.5))
                .shadow(color: .black.opacity(here ? 0.12 : 0.04), radius: here ? 6 : 2, y: 2)
            if got { Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white).transition(.scale.combined(with: .opacity)) }
            else if left { Image(systemName: "arrow.uturn.right").font(.system(size: 13, weight: .bold)).foregroundStyle(HaloKit.amber) }
            else { Text("\(number)").font(HaloKit.hand(25)).foregroundStyle(here ? HaloStyle.coral : HaloStyle.ink.opacity(0.55)) }
        }
        .overlay(alignment: .bottom) { if viewing && !here { Capsule().fill(HaloStyle.ink).frame(width: 14, height: 3).offset(y: 6) } }
        .animation(.spring(duration: 0.5, bounce: 0.35), value: verdict)
        .onAppear { pulse = true }
    }
}
/// The path between two stops: solid once walked, dotted while it's still ahead.
private struct TrailLine: View {
    let walked: Bool
    var body: some View {
        GeometryReader { geo in
            Path { path in path.move(to: CGPoint(x: 0, y: geo.size.height / 2)); path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2)) }
                .stroke(walked ? HaloStyle.ink.opacity(0.55) : HaloStyle.ink.opacity(0.22), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: walked ? [] : [1, 7]))
        }.frame(height: 4).animation(.easeInOut(duration: 0.5), value: walked)
    }
}
@MainActor
private struct LessonPaper: UIViewRepresentable {
    @ObservedObject var coach: LessonCoach
    let session: StudySession
    func makeUIView(context: Context) -> NotePaperView { let view = NotePaperView(); view.isScrollEnabled = false; view.followsPen = false; coach.paper = view; return view }
    func updateUIView(_ view: NotePaperView, context: Context) { coach.paper = view; view.show(session) }
}

/// Tells the board when the student scrolls it themselves, so following the lesson never fights their finger.
private struct NoticesScrolling: ViewModifier {
    let touched: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in if phase == .interacting || phase == .decelerating { touched() } }
        } else { content }
    }
}
