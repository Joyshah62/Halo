import SwiftUI
import WebKit

// "Explore in 3D": a model the student can hold. Turn it, look inside, touch a part, and ask Halo about it.
// While Halo answers, the part it is talking about lights up and turns to face the student.
//
// The model itself is the bundled WebGL viewer (Resources/Scene3D, built from shared/scene3d); everything
// around it is drawn here. The two talk over one small bridge: the viewer says what was touched, and the
// app says what to point at and how to show it.

// MARK: - What Halo knows about each model (the same catalog the viewer and the server use)

struct Scene3DModel: Decodable {
    struct Part: Decodable { let label: String; let detail: String; let group: String? }
    let title: String
    let summary: String
    let source: String
    let kind: String?
    let credit: String?
    let parts: [String: Part]
}
enum Scene3DLibrary {
    static let models: [String: Scene3DModel] = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Scene3D"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Scene3DModel].self, from: data)) ?? [:]
    }()
    /// A picture of the model for the card that opens it.
    static func picture(_ model: String) -> UIImage? {
        Bundle.main.url(forResource: "thumb-\(model)", withExtension: "png", subdirectory: "Scene3D").flatMap { UIImage(contentsOfFile: $0.path) }
    }
}

// MARK: - The card that opens a model

struct Scene3DCard: View {
    @ObservedObject var store: StudyStore
    let scene: Scene3DSpec
    var featured = false
    /// The start screen's card: all the models, not just this one.
    var gallery = false
    @State private var exploring = false
    private var title: String { gallery ? "Explore 3D models" : scene.title }
    private var note: String {
        if gallery { return "a real human brain, a neuron and a cell. turn them, touch a part, ask me" }
        if !scene.caption.isEmpty { return scene.caption }
        return scene.model == "brain" ? "turn it, look inside, touch a part and ask me" : "turn it, touch a part and ask me"
    }
    var body: some View {
        Button { exploring = true } label: {
            HStack(spacing: featured ? 20 : 14) {
                Group {
                    if let picture = Scene3DLibrary.picture(scene.model) { Image(uiImage: picture).resizable().scaledToFit() }
                    else { Image(systemName: "cube.transparent").font(.system(size: 30)).foregroundStyle(HaloStyle.coral) }
                }
                .frame(width: featured ? 168 : 84, height: featured ? 128 : 66)
                VStack(alignment: .leading, spacing: featured ? 6 : 3) {
                    Eyebrow("Explore in 3D", color: HaloStyle.coral)
                    Text(title).font(HaloKit.title(featured ? 27 : 18, .medium)).foregroundStyle(HaloStyle.text)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Text(note).font(HaloKit.hand(featured ? 23 : 19)).foregroundStyle(HaloStyle.ink)
                        .multilineTextAlignment(.leading).lineLimit(featured ? 3 : 2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: featured ? 17 : 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: featured ? 42 : 32, height: featured ? 42 : 32).background(HaloStyle.coral, in: Circle())
            }
            .padding(featured ? 18 : 13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: featured ? 24 : 18, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 16, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(gallery ? "Explore 3D models" : "Explore \(scene.title) in 3D")
        .fullScreenCover(isPresented: $exploring) {
            if gallery { Explorer3DLibrary(store: store, first: scene.model) } else { Explorer3D(store: store, scene: scene) }
        }
    }
}

// MARK: - What is going on in the explorer

@MainActor
final class ExplorerModel: ObservableObject {
    struct Line: Identifiable, Equatable { let id = UUID(); var text: String; var part: String? }
    struct Turn: Identifiable, Equatable { let id = UUID(); var question: String; var lines: [Line] = []; var problem: String? }

    let scene: Scene3DSpec
    let entry: Scene3DModel?
    @Published var ready = false
    @Published var unavailable = false
    @Published var order: [String] = []
    @Published var views: [String] = []
    @Published var selected: String?
    @Published var view = "whole"
    @Published var turns: [Turn] = []
    @Published var busy = false
    @Published var speaking: UUID?
    @Published var listening = false
    @Published var heard = ""
    @Published var draft = ""
    weak var web: WKWebView?
    private weak var store: StudyStore?
    private var task: Task<Void, Never>?
    private var silence: Task<Void, Never>?

    init(scene: Scene3DSpec, store: StudyStore) {
        self.scene = scene; self.store = store; entry = Scene3DLibrary.models[scene.model]
        order = (entry?.parts ?? [:]).sorted { $0.value.label < $1.value.label }.map(\.key)
    }
    var title: String { entry?.title ?? scene.title }
    func part(_ id: String?) -> Scene3DModel.Part? { id.flatMap { entry?.parts[$0] } }
    /// Parts in the model's own order, under their headings.
    var groups: [(name: String, parts: [String])] {
        var result: [(name: String, parts: [String])] = []
        for id in order {
            let name = part(id)?.group ?? ""
            if let index = result.firstIndex(where: { $0.name == name }) { result[index].parts.append(id) } else { result.append((name, [id])) }
        }
        return result
    }
    var suggestions: [String] {
        if let name = part(selected)?.label.lowercased() {
            return ["What does the \(name) do?", "What happens if it’s damaged?", "What does it work with?"]
        }
        switch scene.model {
        case "brain": return ["Where do memories form?", "Which part lets me see?", "What keeps me breathing?"]
        case "neuron": return ["How does a signal travel?", "Why is myelin important?"]
        default: return ["Where is the DNA kept?", "Where does the cell get energy?"]
        }
    }

    // MARK: the bridge to the viewer
    struct Signal: Sendable { var type = ""; var part: String?; var by = ""; var view = ""; var parts: [String] = []; var views: [String] = [] }
    func receive(_ signal: Signal) {
        switch signal.type {
        case "ready":
            if !signal.parts.isEmpty { order = signal.parts }
            views = signal.views
            withAnimation(.easeOut(duration: 0.4)) { ready = true }
            runScript()
        case "select":
            if signal.by == "touch", signal.part != selected { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { selected = signal.part }
        case "view": withAnimation(.spring(duration: 0.3)) { view = signal.view }
        case "failed": unavailable = true
        default: break
        }
    }
    private func run(_ script: String) { web?.evaluateJavaScript("window.halo3d && window.halo3d.\(script)", completionHandler: nil) }
    private func quoted(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
    /// Lights a part up and turns the model to show it (nil lets go).
    func point(at part: String?) { run("select(\(part.map(quoted) ?? "null"))") }
    func show(_ view: String) { run("setView(\(quoted(view)))") }
    func reset() { run("reset()") }

    // MARK: asking Halo
    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let store else { return }
        stopListening(); task?.cancel(); store.player.stop()
        draft = ""
        let earlier = turns.flatMap { turn -> [ConversationTurn] in
            let answer = turn.lines.map(\.text).joined(separator: " ")
            return answer.isEmpty ? [] : [ConversationTurn(role: "user", text: turn.question), ConversationTurn(role: "assistant", text: answer)]
        }
        let turn = Turn(question: question)
        withAnimation(.spring(duration: 0.35)) { turns.append(turn); busy = true }
        let touched = selected
        var learner = store.learner; learner.struggles = []
        let request = AskRequest(question: question, explorer: ExplorerContext(model: scene.model, focus: touched), about: about(touched),
                                 title: "3D explorer · \(title)", conversation: earlier, tutorMode: false, learner: learner)
        let stream = store.client.ask(request, server: store.serverURL), aloud = store.voiceOut, id = turn.id
        task = Task { [weak self] in
            var answered = false
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .step(let step): answered = true; await self.present(step, in: id, aloud: aloud)
                    case .failure(let message): if !answered { await self.fallBack(in: id, touched: touched, aloud: aloud, because: message) }
                    default: break
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                if !answered { await self.fallBack(in: id, touched: touched, aloud: aloud, because: error.localizedDescription) }
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.busy = false; self.speaking = nil }
        }
    }
    /// One step of the answer: the part it is about lights up, the line is written, and Halo says it.
    private func present(_ step: AnswerStep, in turn: UUID, aloud: Bool) async {
        guard let index = turns.firstIndex(where: { $0.id == turn }) else { return }
        let focus = step.ink.compactMap(\.scene3D).last?.focus
        let written = step.ink.first(where: { $0.type == "text" })?.value.flatMap { $0.isEmpty ? nil : $0 } ?? step.say
        if let focus { point(at: focus) }
        let line = Line(text: written, part: focus)
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { turns[index].lines.append(line); speaking = line.id }
        if aloud { try? await store?.player.play(step) } else { try? await Task.sleep(for: .milliseconds(1100)) }
    }
    /// No server: Halo still says what it knows about the part from the catalog.
    private func fallBack(in turn: UUID, touched: String?, aloud: Bool, because problem: String) async {
        guard let index = turns.firstIndex(where: { $0.id == turn }) else { return }
        guard let known = part(touched) else {
            withAnimation { turns[index].problem = "I couldn’t reach my server (\(problem)). Touch a part and I can still tell you what it does." }
            return
        }
        await present(AnswerStep(index: 0, say: "\(known.label). \(known.detail)", ink: []), in: turn, aloud: aloud)
        if let index = turns.firstIndex(where: { $0.id == turn }) { turns[index].problem = "That’s from my notes: I couldn’t reach my server for a fuller answer." }
    }
    private func about(_ touched: String?) -> String {
        guard let entry else { return "" }
        var lines = ["The student is exploring Halo's interactive 3D model “\(entry.title)”. \(entry.summary)"]
        if let touched, let known = entry.parts[touched] { lines.append("They are touching: \(known.label). \(known.detail)") }
        lines.append("Parts of the model:")
        for id in order { if let known = entry.parts[id] { lines.append("- \(known.label) (\(id)): \(known.detail)") } }
        return lines.joined(separator: "\n")
    }
    func hush() {
        task?.cancel(); task = nil; store?.player.stop()
        withAnimation(.easeOut(duration: 0.2)) { busy = false; speaking = nil }
    }

    // MARK: asking out loud (the microphone is borrowed from circle-and-ask, and handed back)
    func toggleMicrophone() {
        guard let store else { return }
        if listening { store.speech.stop(); return }
        hush()
        store.speech.onTranscript = { [weak self] text in self?.heardMore(text) }
        store.speech.onStopped = { [weak self] in self?.listeningStopped() }
        heard = ""
        withAnimation(.spring(duration: 0.3)) { listening = true }
        Task { [weak self] in
            do { try await store.speech.start() } catch { self?.listeningStopped() }
        }
    }
    private func heardMore(_ text: String) {
        guard listening else { return }
        heard = text
        // A pause after speech means the question is finished.
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self, !Task.isCancelled, self.listening, !self.heard.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.store?.speech.stop()
        }
    }
    private func listeningStopped() {
        silence?.cancel(); store?.restoreSpeech()
        let was = listening, said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.spring(duration: 0.3)) { listening = false }
        heard = ""
        if was, !said.isEmpty { ask(said) }
    }
    func stopListening() {
        guard listening else { return }
        listening = false; heard = ""; silence?.cancel()
        store?.restoreSpeech(); store?.speech.stop()
    }
    func close() { stopListening(); hush() }

    /// `--touch hippocampus`, `--explore-view half`, `--explore-ask "what does it do?"`: a scripted visit, for screenshots.
    private func runScript() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard value("--touch") != nil || value("--explore-view") != nil || value("--explore-ask") != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            if let view = value("--explore-view") { self?.show(view) }
            if let part = value("--touch") { self?.point(at: part) }
            try? await Task.sleep(for: .milliseconds(1400))
            if let question = value("--explore-ask") { self?.ask(question) }
        }
    }
}

// MARK: - Every model, one at a time

/// The explorer with a switcher between the models. Each switch builds the chosen model fresh.
struct Explorer3DLibrary: View {
    @ObservedObject var store: StudyStore
    @State private var model: String
    init(store: StudyStore, first: String = "brain") { self.store = store; _model = State(initialValue: first) }
    var body: some View {
        Explorer3D(store: store, scene: Scene3DSpec(model: model), switchTo: { next in withAnimation(.easeInOut(duration: 0.25)) { model = next } })
            .id(model)
    }
}

// MARK: - The screen

@MainActor
struct Explorer3D: View {
    @ObservedObject var store: StudyStore
    @StateObject private var model: ExplorerModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    /// Set when the student can move to another model from here.
    var switchTo: ((String) -> Void)?

    init(store: StudyStore, scene: Scene3DSpec, switchTo: ((String) -> Void)? = nil) {
        self.store = store; self.switchTo = switchTo
        _model = StateObject(wrappedValue: ExplorerModel(scene: scene, store: store))
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900 && geometry.size.width > geometry.size.height
            ZStack(alignment: .topTrailing) {
                DeskPaper().ignoresSafeArea()
                if wide {
                    HStack(spacing: 0) {
                        stage
                        panel.frame(width: min(430, geometry.size.width * 0.36)).padding(.vertical, 18).padding(.trailing, 18)
                    }
                } else {
                    VStack(spacing: 0) {
                        stage.frame(height: typing ? geometry.size.height * 0.3 : geometry.size.height * 0.48)
                        panel.padding(.horizontal, 14).padding(.bottom, 12)
                    }
                }
                CloseButton(label: "Close the 3D explorer") { model.close(); dismiss() }
                    .padding(.top, wide ? 30 : 14).padding(.trailing, wide ? 34 : 18)
            }
        }
        .onDisappear { model.close() }
        .animation(.spring(duration: 0.35), value: typing)
    }

    // MARK: the model, and how to look at it
    private var stage: some View {
        ZStack {
            // A pool of light on the desk for the model to sit in.
            RadialGradient(colors: [.white.opacity(0.95), .white.opacity(0)], center: .center, startRadius: 30, endRadius: 440)
                .allowsHitTesting(false)
            if model.unavailable {
                EmptyDesk(title: "3D isn’t available here", note: "I can still tell you about every part. Pick one on the right.", symbol: "cube.transparent")
            } else {
                Scene3DWebView(model: model).opacity(model.ready ? 1 : 0)
                if !model.ready {
                    VStack(spacing: 12) {
                        HaloRing(size: 54, working: true)
                        Text("building the model…").font(HaloKit.hand(24)).foregroundStyle(HaloStyle.ink)
                    }.transition(.opacity)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow("Explore in 3D", color: HaloStyle.coral)
                    Text(model.title).font(HaloKit.title(34)).foregroundStyle(HaloStyle.text)
                    Text(model.selected == nil ? "touch any part, then ask me about it" : "drag to turn it · pinch to zoom")
                        .font(HaloKit.hand(24)).foregroundStyle(HaloStyle.ink).contentTransition(.opacity)
                }
                .padding(.leading, 30).padding(.top, 26).allowsHitTesting(false)
                if switchTo != nil { shelf.padding(.leading, 26).padding(.top, 12) }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if !model.views.isEmpty { lenses }
                    Button { model.reset() } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 15, weight: .bold)).frame(width: 42, height: 42)
                            .background(Color.white, in: Circle()).overlay(Circle().stroke(HaloStyle.ink.opacity(0.12))).foregroundStyle(HaloStyle.ink)
                    }.buttonStyle(.plain).accessibilityLabel("Reset the view")
                }
                .frame(maxWidth: .infinity).padding(.bottom, 22).opacity(model.ready ? 1 : 0)
            }
        }
    }
    private static let shelfModels = [("brain", "Brain", "brain"), ("neuron", "Neuron", "point.3.connected.trianglepath.dotted"), ("animal-cell", "Cell", "circle.hexagongrid")]
    /// The other models, to switch to.
    private var shelf: some View {
        HStack(spacing: 4) {
            ForEach(Self.shelfModels, id: \.0) { id, name, icon in
                let on = model.scene.model == id
                Button { if !on { model.close(); switchTo?(id) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 12, weight: .bold))
                        Text(name).font(HaloKit.text(14, .semibold)).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 13).frame(height: 36)
                    .background(on ? HaloStyle.coral : Color.clear, in: Capsule())
                    .foregroundStyle(on ? .white : HaloStyle.text)
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityLabel("Show the \(name.lowercased()) in 3D")
            }
        }
        .padding(4).background(Color.white, in: Capsule())
        .overlay(Capsule().stroke(HaloStyle.ink.opacity(0.1))).shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
    private static let lensNames: [String: (name: String, icon: String)] = [
        "whole": ("Whole", "circle.fill"), "inside": ("See inside", "eye"),
        "half": ("Cut in half", "circle.lefthalf.filled"), "apart": ("Pull apart", "arrow.up.left.and.arrow.down.right"),
    ]
    /// Ways of looking at it: whole, as glass, cut down the middle, or pulled apart.
    private var lenses: some View {
        HStack(spacing: 4) {
            ForEach(model.views, id: \.self) { id in
                let on = model.view == id, lens = Self.lensNames[id] ?? (id.capitalized, "circle")
                Button { model.show(id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: lens.icon).font(.system(size: 12, weight: .bold))
                        Text(lens.name).font(HaloKit.text(14, .semibold)).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 13).frame(height: 38)
                    .background(on ? HaloStyle.ink : Color.clear, in: Capsule())
                    .foregroundStyle(on ? .white : HaloStyle.ink)
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4).background(Color.white, in: Capsule())
        .overlay(Capsule().stroke(HaloStyle.ink.opacity(0.1))).shadow(color: .black.opacity(0.08), radius: 12, y: 5)
    }

    // MARK: Halo's side: what you touched, what you asked, what it said
    private var cue: TutorCue {
        var cue = TutorCue(base: model.listening ? .listening : model.busy && model.speaking == nil ? .thinking : .attentive)
        if model.speaking != nil, store.voiceOut { cue.speakingUntil = .distantFuture }
        return cue
    }
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                TutorAvatar(cue: cue, size: 66, voiceLevel: { store.player.outputLevel })
                VStack(alignment: .leading, spacing: 2) {
                    if let known = model.part(model.selected) {
                        Eyebrow(known.group ?? "You touched", color: HaloStyle.coral)
                        Text(known.label).font(HaloKit.title(25, .medium)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Eyebrow("Halo", color: HaloStyle.coral)
                        Text("Touch a part").font(HaloKit.title(25, .medium)).foregroundStyle(HaloStyle.text)
                    }
                }
                Spacer(minLength: 0)
                if model.selected != nil {
                    Button { model.point(at: nil) } label: {
                        Text("All parts").font(HaloKit.text(13, .semibold)).padding(.horizontal, 11).padding(.vertical, 7)
                            .background(HaloStyle.ink.opacity(0.07), in: Capsule()).foregroundStyle(HaloStyle.ink)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12).padding(.trailing, 44)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let known = model.part(model.selected) {
                            Text(known.detail).font(HaloKit.text(16)).foregroundStyle(HaloStyle.text.opacity(0.85)).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true).transition(.opacity)
                        } else if model.turns.isEmpty {
                            Text(model.entry?.summary ?? "").font(HaloKit.text(16)).foregroundStyle(HaloStyle.text.opacity(0.85)).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.busy {
                            FlowRow(spacing: 8) {
                                ForEach(model.suggestions, id: \.self) { question in
                                    Button { model.ask(question) } label: { ScribbleChip(text: question, icon: "sparkle") }.buttonStyle(.plain)
                                }
                            }
                        }
                        if model.selected == nil, model.turns.isEmpty { index }
                        ForEach(model.turns) { turn in conversation(turn) }
                        if model.busy, model.turns.last?.lines.isEmpty == true {
                            HStack(spacing: 10) {
                                HaloRing(size: 22, working: true)
                                Text("looking closely…").font(HaloKit.hand(22)).foregroundStyle(HaloStyle.ink)
                            }.breathing()
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 18).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.turns) { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) } }
            }

            VStack(alignment: .leading, spacing: 8) {
                if model.listening {
                    Text(model.heard.isEmpty ? "I’m listening…" : model.heard).font(HaloKit.hand(23)).foregroundStyle(HaloStyle.ink)
                        .padding(.horizontal, 6).transition(.opacity)
                }
                HaloComposer(text: $model.draft,
                             prompt: model.part(model.selected).map { "Ask about the \($0.label.lowercased())…" } ?? "Ask Halo anything…",
                             recording: model.listening, microphone: { model.toggleMicrophone() }, focus: $typing) { model.ask(model.draft) }
            }
            .padding(12)
        }
        .background(Color.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.09), radius: 24, y: 10)
    }
    /// Every part by name, for when you don't know where to touch.
    private var index: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.groups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 8) {
                    if !group.name.isEmpty { Eyebrow(group.name) }
                    FlowRow(spacing: 7) {
                        ForEach(group.parts, id: \.self) { id in
                            Button { model.point(at: id) } label: {
                                Text(model.part(id)?.label ?? id).font(HaloKit.text(14, .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(HaloStyle.ink.opacity(0.07), in: Capsule()).foregroundStyle(HaloStyle.ink)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder private func conversation(_ turn: ExplorerModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question).font(HaloKit.text(15.5, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(HaloStyle.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
            ForEach(turn.lines) { line in
                let now = model.speaking == line.id
                Button { model.point(at: line.part) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(HaloStyle.coral).frame(width: 7, height: 7).offset(y: -4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.text).font(HaloKit.hand(24)).foregroundStyle(HaloStyle.text).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if let name = model.part(line.part)?.label {
                                Label(name, systemImage: "hand.point.up.left").font(HaloKit.text(11.5, .bold)).foregroundStyle(HaloStyle.coral)
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(now ? HaloKit.highlight.opacity(0.75) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).disabled(line.part == nil)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let problem = turn.problem {
                Text(problem).font(HaloKit.text(13)).foregroundStyle(HaloKit.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The viewer itself

private struct Scene3DWebView: UIViewRepresentable {
    let model: ExplorerModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(Relay(context.coordinator), name: "halo")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // Only the model is drawn; the desk shows through around it.
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false; view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        model.web = view
        let scene = model.scene
        var spec: [String: Any] = ["model": scene.model, "caption": scene.caption, "embed": true]
        if let focus = scene.focus { spec["focus"] = focus }
        guard scene.isSupported,
              let file = Bundle.main.url(forResource: "viewer", withExtension: "html", subdirectory: "Scene3D"),
              let data = try? JSONSerialization.data(withJSONObject: spec), let json = String(data: data, encoding: .utf8),
              var url = URLComponents(url: file, resolvingAgainstBaseURL: false) else {
            DispatchQueue.main.async { [model] in model.unavailable = true }
            return view
        }
        // The fragment stays local; the viewer validates the model and part IDs again.
        url.fragment = json
        if let target = url.url { view.loadFileURL(target, allowingReadAccessTo: file.deletingLastPathComponent()) }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "halo")
        view.stopLoading(); view.navigationDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }
    /// The content controller keeps its handler alive; this keeps that from keeping the whole screen alive.
    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        init(_ target: Coordinator) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { target?.heard(message.body) }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: ExplorerModel
        init(model: ExplorerModel) { self.model = model }
        func heard(_ body: Any) {
            guard let body = body as? [String: Any], let type = body["type"] as? String else { return }
            let signal = ExplorerModel.Signal(type: type, part: body["part"] as? String, by: body["by"] as? String ?? "", view: body["view"] as? String ?? "",
                                              parts: body["parts"] as? [String] ?? [], views: body["views"] as? [String] ?? [])
            Task { @MainActor [model] in model.receive(signal) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // References open in the system browser; the embedded viewer stays on its bundled page.
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, url.scheme == "https" { UIApplication.shared.open(url) }
                decisionHandler(.cancel); return
            }
            decisionHandler(navigationAction.request.url?.isFileURL == true || navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
