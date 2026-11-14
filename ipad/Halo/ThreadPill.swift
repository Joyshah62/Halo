import SwiftUI

/// What the note attached to a circle is doing right now.
enum PillState: Equatable {
    case hidden
    case listening(String)      // live transcript
    case typing
    case thinking(String)       // the question
    case speaking(String)       // caption of the current step
    case ready                  // answer finished; ask a follow-up on the same note
    case error(String)
}

@MainActor
enum NoteMetrics {
    static let width: CGFloat = 340
    static var scale: CGFloat { width / InkLayout.width }
}

/// The store writes on whichever note is open through this.
@MainActor
protocol NoteAnimating: AnyObject {
    func animate(session: StudySession, duration: TimeInterval) async
}

/// Halo's margin. The conversation gets a place of its own, docked beside the page (or under it,
/// when the iPad is upright), so nothing on the page is covered and nothing has to be moved.
/// Halo writes the answer there by hand while speaking; the same margin listens for the question,
/// takes a typed one, and shows what Halo is saying.
@MainActor
struct HaloMargin: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var speech: SpeechInput
    let session: StudySession
    /// Beside the page (true) or along the bottom of it (false).
    let sideways: Bool
    @FocusState private var focused: Bool
    @State private var showTranscript = false
    @State private var confirmDelete = false
    @State private var pulse = false
    init(store: StudyStore, session: StudySession, sideways: Bool) {
        self.store = store; self.speech = store.speech; self.session = session; self.sideways = sideways
    }
    private static let starters = ["Explain this", "Why is that true?", "Give me an example", "Show me a video"]
    private var answered: Bool { session.messages.contains { $0.role == "assistant" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if sideways {
                paper.frame(maxHeight: .infinity)
                controls.padding(.horizontal, 18).padding(.bottom, 16)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    paper.frame(maxWidth: 640, maxHeight: .infinity)
                    Divider().padding(.vertical, 8)
                    controls.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.horizontal, 18).padding(.bottom, 14)
                }
            }
        }
        .background(Color(uiColor: InkPalette.note).ignoresSafeArea(edges: sideways ? [.bottom, .trailing] : [.bottom, .horizontal]))
        .overlay(alignment: sideways ? .leading : .top) {
            // The edge it shares with the page.
            Rectangle().fill(HaloStyle.coral.opacity(0.55)).frame(width: sideways ? 2 : nil, height: sideways ? nil : 2)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, x: sideways ? -6 : 0, y: sideways ? 0 : -6)
        .onChange(of: store.pill) { _, state in if case .typing = state, answered { focused = true } }
        .onChange(of: focused) { _, isFocused in
            if isFocused, case .listening = store.pill { store.typeInstead() }
        }
        .onAppear { pulse = true }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete note and circle", role: .destructive) { store.deleteSession(session.id) }
        }
    }

    // MARK: header
    private var header: some View {
        HStack(spacing: 12) {
            // Halo itself, talking, listening and thinking along with the note.
            TutorAvatar(cue: store.haloCue, size: 78, voiceLevel: { [store] in store.player.outputLevel }, micLevel: { [speech] in CGFloat(speech.meter.value) })
                .frame(width: 60, height: 60).padding(.trailing, -2)
            Text("\(session.number)").font(HaloKit.hand(40)).foregroundStyle(HaloStyle.coral).frame(minWidth: 22).offset(y: -2)
            VStack(alignment: .leading, spacing: 1) {
                Eyebrow(answered ? "Halo’s note" : "Ask Halo", color: HaloStyle.coral)
                Text(session.topic.isEmpty ? store.pageLabel(session.pageIndex) : "\(session.topic) · \(store.pageLabel(session.pageIndex))")
                    .font(HaloKit.text(14, .medium)).foregroundStyle(noteSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if !session.messages.isEmpty {
                Button { showTranscript = true } label: { Image(systemName: "text.alignleft").font(.system(size: 15, weight: .medium)).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).foregroundStyle(faint).accessibilityLabel("Read as text")
                    .popover(isPresented: $showTranscript, arrowEdge: .top) { TranscriptView(session: session).frame(minWidth: 340, minHeight: 320) }
                Button { confirmDelete = true } label: { Image(systemName: "trash").font(.system(size: 14.5, weight: .medium)).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).foregroundStyle(faint).accessibilityLabel("Delete note")
            }
            CloseButton(label: "Put note away") { store.dismissPill() }
        }
        .padding(.leading, 18).padding(.trailing, 14).padding(.top, 12).padding(.bottom, 8)
    }
    private var noteSecondary: Color { Color(uiColor: InkPalette.question) }
    private var faint: Color { noteSecondary.opacity(0.7) }

    // MARK: the writing
    @ViewBuilder private var paper: some View {
        if session.messages.isEmpty { invitation }
        else { NotePaper(store: store, session: session).padding(.horizontal, 6) }
    }
    /// Before the first question: what Halo is hearing, or a few ways to start.
    private var invitation: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            if case .listening(let heard) = store.pill {
                Text(heard.isEmpty ? "ask your question out loud" : "“\(heard)”").font(HaloKit.hand(32)).foregroundStyle(HaloStyle.ink)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).animation(.easeOut(duration: 0.15), value: heard)
                Text("I’ll answer when you pause").font(HaloKit.text(13.5)).foregroundStyle(noteSecondary)
            } else {
                Text("what do you want to know about this?").font(HaloKit.hand(30)).foregroundStyle(HaloStyle.ink).multilineTextAlignment(.center)
                FlowRow(spacing: 8) {
                    ForEach(Self.starters, id: \.self) { starter in
                        Button { store.setDraft(starter); store.ask() } label: {
                            Text(starter).font(HaloKit.text(14.5, .medium)).padding(.horizontal, 13).padding(.vertical, 8)
                                .background(Color.white.opacity(0.8), in: Capsule()).overlay(Capsule().stroke(HaloStyle.ink.opacity(0.14))).foregroundStyle(HaloStyle.ink)
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: 420)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 22)
    }

    // MARK: listen / type / status
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.busy, !store.agentTodos.isEmpty, !speaking { agentPlan }
            if showsStatus {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: micSymbol).font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(HaloStyle.coral).frame(width: 30, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(HaloKit.text(13, .bold)).tracking(0.6).foregroundStyle(HaloStyle.coral).lineLimit(1)
                        Text(subtitle).font(HaloKit.text(16.5)).foregroundStyle(subtitleStyle).lineSpacing(2).lineLimit(sideways ? 5 : 4).fixedSize(horizontal: false, vertical: true)
                            .animation(.easeOut(duration: 0.15), value: subtitle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if store.pill == .ready, store.canAskWhyStuck {
                Button { store.whyStuck() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.bubble").font(.system(size: 15, weight: .semibold))
                        Text("Why am I stuck?").font(HaloKit.text(15, .semibold))
                        Text("Halo checks your book").font(HaloKit.text(13.5)).opacity(0.85).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 11)
                    .background(HaloStyle.ink, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }.buttonStyle(.plain).accessibilityHint("Halo finds the idea behind this mistake and where your book teaches it")
            }
            if store.pill == .ready, let found = session.stuck, found.page > 0 {
                Button { store.openStuckPage() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "book.pages").font(.system(size: 15, weight: .semibold))
                        Text("Page \(found.page)").font(HaloKit.text(15, .semibold))
                        Text(found.gap).font(HaloKit.text(13.5)).opacity(0.8).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(HaloStyle.ink).padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(HaloStyle.ink.opacity(0.14)))
                }.buttonStyle(.plain).accessibilityHint("Opens the page of your book that teaches this")
            }
            if store.pill == .ready, answered {
                Button { store.diveFromSession() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 15, weight: .semibold))
                        Text("Go deeper").font(HaloKit.text(15, .semibold))
                        Text("videos · pictures · sources").font(HaloKit.text(13.5)).opacity(0.85).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 11)
                    .background(HaloStyle.coral, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }.buttonStyle(.plain).accessibilityHint("Halo looks this up on the web")
            }
            if showsInput {
                HaloComposer(text: Binding(get: { store.draft }, set: { store.setDraft($0) }),
                             prompt: inputPlaceholder, recording: speech.isRecording, canSend: canSend,
                             microphone: { store.toggleListening() }, focus: $focused,
                             send: { store.ask() })
            }
        }
        .padding(.top, 8)
    }

    private var speaking: Bool { if case .speaking = store.pill { return true }; return false }
    /// The deep agent's own to-do list, ticking off while it works, with what it is doing right now underneath.
    private var agentPlan: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(store.agentTodos.enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 9) {
                    Image(systemName: todo.status == "completed" ? "checkmark.circle.fill" : todo.status == "in_progress" ? "circle.dotted" : "circle")
                        .font(HaloKit.text(15, .semibold)).foregroundStyle(todo.status == "pending" ? faint : HaloStyle.coral)
                    Text(todo.content).font(HaloKit.text(15)).foregroundStyle(todo.status == "pending" ? noteSecondary : HaloStyle.text)
                        .strikethrough(todo.status == "completed", color: noteSecondary).lineLimit(2)
                }
            }
            if !store.agentStage.isEmpty {
                Text(store.agentStage).font(HaloKit.text(13.5)).foregroundStyle(noteSecondary).lineLimit(1).padding(.leading, 24)
                    .animation(.easeOut(duration: 0.15), value: store.agentStage)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine).accessibilityLabel("Halo is working on it")
    }

    private func micButton(size: CGFloat) -> some View {
        Button { store.toggleListening() } label: {
            ZStack {
                if case .listening = store.pill {
                    Circle().stroke(HaloStyle.coral.opacity(0.6), lineWidth: 2).scaleEffect(pulse ? 1.6 : 1).opacity(pulse ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
                }
                Circle().fill(micColor).frame(width: size, height: size)
                Image(systemName: micSymbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(micForeground)
            }.frame(width: size + 6, height: size + 6)
        }.buttonStyle(.plain).accessibilityLabel(micLabel)
    }

    private var title: String {
        switch store.pill {
        case .hidden, .ready: return ""
        case .listening: return "LISTENING"
        case .typing: return session.messages.isEmpty ? "ASK ABOUT THIS" : "ASK MORE"
        case .thinking: return "THINKING"
        case .speaking: return "HALO"
        case .error: return "HMM"
        }
    }
    private var subtitle: String {
        switch store.pill {
        case .hidden, .ready: return ""
        case .listening(let text): return text.isEmpty ? "Ask your question out loud" : text
        case .typing: return speech.lastError ?? "Tap the mic, or type below"
        case .thinking(let q): return "“\(q)”"
        case .speaking(let caption): return caption
        case .error(let message): return message
        }
    }
    private var subtitleStyle: Color {
        if case .speaking = store.pill { return HaloStyle.text }
        if case .error = store.pill { return .red }
        return noteSecondary
    }
    private var showsStatus: Bool {
        switch store.pill { case .ready, .hidden: return false; default: return true }
    }
    private var showsInput: Bool {
        switch store.pill { case .typing, .listening, .ready, .error: return true; default: return false }
    }
    private var inputPlaceholder: String { session.messages.isEmpty ? "…or type your question" : "Ask a follow-up…" }
    private var canSend: Bool { !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.busy }
    private var micColor: Color {
        switch store.pill { case .listening: return HaloStyle.coral; case .thinking: return HaloStyle.ink; default: return Color.white.opacity(0.85) }
    }
    private var micForeground: Color {
        switch store.pill { case .listening, .thinking: return .white; default: return HaloStyle.ink }
    }
    private var micSymbol: String {
        switch store.pill { case .thinking: return "circle.dotted"; case .speaking: return "speaker.wave.2.fill"; default: return "mic.fill" }
    }
    private var micLabel: String { if case .listening = store.pill { return "Stop listening" }; return "Ask by voice" }
}

/// What Halo writes on: a soft sheet with no colour of its own. Over a page it is frosted, so the
/// print underneath blurs away instead of fighting the handwriting; on a plain background it is paper.
struct NoteSheet: View {
    var frosted: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            if frosted {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(uiColor: InkPalette.note).opacity(0.72))
            } else {
                shape.fill(Color(uiColor: InkPalette.note))
            }
            shape.strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        }
        // The shadow belongs to the sheet only; on the whole stack it also smudges under the handwriting.
        .compositingGroup()
        .shadow(color: .black.opacity(frosted ? 0.16 : 0.08), radius: frosted ? 18 : 8, x: 0, y: frosted ? 8 : 3)
    }
}

/// A square of paper with the bottom-right corner folded over (the small numbered tabs in lists).
struct NoteShape: Shape {
    var fold: CGFloat = 18
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 3, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.minY)); p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 3), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold)); p.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY)); p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 3), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 3)); p.addQuadCurve(to: CGPoint(x: rect.minX + 3, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
struct NoteFold: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.closeSubpath()
        return p
    }
}

/// The hand-drawn tail from a note to the thing it is about.
struct NoteTail: Shape {
    var from: CGPoint
    var to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let dx = to.x - from.x, dy = to.y - from.y, len = max(1, hypot(dx, dy))
        let bend = min(36, len * 0.2)
        let control = CGPoint(x: (from.x + to.x) / 2 - dy / len * bend, y: (from.y + to.y) / 2 + dx / len * bend)
        p.move(to: from); p.addQuadCurve(to: to, control: control)
        let tx = to.x - control.x, ty = to.y - control.y, tl = max(1, hypot(tx, ty)), ux = tx / tl, uy = ty / tl, s: CGFloat = 11
        p.move(to: CGPoint(x: to.x - ux * s - uy * s * 0.6, y: to.y - uy * s + ux * s * 0.6))
        p.addLine(to: to)
        p.addLine(to: CGPoint(x: to.x - ux * s + uy * s * 0.6, y: to.y - uy * s - ux * s * 0.6))
        return p
    }
}

// MARK: - The paper Halo writes on

@MainActor
struct NotePaper: UIViewRepresentable {
    @ObservedObject var store: StudyStore
    let session: StudySession
    func makeUIView(context: Context) -> NotePaperView { let view = NotePaperView(); store.notePaper = view; return view }
    func updateUIView(_ view: NotePaperView, context: Context) { store.notePaper = view; view.show(session) }
}

/// A finished note shown whole and still (the session summary): no scrolling, no live writing.
@MainActor
struct NotePaperStatic: UIViewRepresentable {
    let session: StudySession
    func makeUIView(context: Context) -> NotePaperView {
        let view = NotePaperView(); view.isScrollEnabled = false; view.isUserInteractionEnabled = false; view.followsPen = false
        return view
    }
    func updateUIView(_ view: NotePaperView, context: Context) { view.show(session) }
}

/// Scrollable handwriting for one thread. Saved steps are drawn at once; the newest step is
/// written stroke by stroke in time with the voice, and the paper scrolls to follow the pen.
@MainActor
final class NotePaperView: UIScrollView, NoteAnimating {
    private let container = CALayer()
    private var session: StudySession?
    private var writing: UUID?          // the message being written right now
    private var epoch = 0
    private var signature = ""
    private var laidOutWidth: CGFloat = 0
    var followsPen = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; showsHorizontalScrollIndicator = false; alwaysBounceVertical = false
        container.anchorPoint = .zero
        layer.addSublayer(container)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var scale: CGFloat { bounds.width / InkLayout.width }
    private func key(_ session: StudySession) -> String {
        "\(session.id)|\(session.messages.count)|\(session.messages.last?.id.uuidString ?? "")|\(writing?.uuidString ?? "")"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != laidOutWidth else { return }
        laidOutWidth = bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.position = .zero
        container.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        if let session { contentSize = CGSize(width: bounds.width, height: InkLayout.height(of: session) * scale) }
    }

    /// Draws the thread as it stands. Cheap to call repeatedly; redraws only when the thread changed.
    func show(_ session: StudySession) {
        if let writing, self.session?.id != session.id || !session.messages.contains(where: { $0.id == writing }) {
            self.writing = nil; epoch += 1
        }
        let switched = self.session?.id != session.id
        self.session = session
        let signature = key(session)
        guard signature != self.signature else { return }
        self.signature = signature
        let layout = InkLayout.build(session, stoppingBefore: writing)
        draw(layout.elements)
        contentSize = CGSize(width: bounds.width, height: InkLayout.height(of: session) * scale)
        if switched || !followsPen { contentOffset = .zero } else { scrollToEnd(animated: true) }
    }

    func animate(session: StudySession, duration: TimeInterval) async {
        guard let newest = session.messages.last, newest.role == "assistant" else { return }
        epoch += 1
        let mine = epoch
        writing = newest.id; self.session = session; signature = key(session)
        var layout = InkLayout.build(session, stoppingBefore: newest.id)
        let before = layout.elements.count
        layout.add(newest)
        draw(Array(layout.elements[..<before]))
        contentSize = CGSize(width: bounds.width, height: layout.height * scale)
        let fresh = Array(layout.elements[before...])
        let totalCost = max(1, fresh.reduce(0) { $0 + $1.cost })
        let budget = max(0.9, duration * 0.85)
        for element in fresh {
            guard mine == epoch, !Task.isCancelled else { break }
            let layer = element.layer(animated: true)
            container.addSublayer(layer)
            follow(element)
            await InkPen.write(layer, element: element, seconds: budget * Double(element.cost / totalCost))
        }
        guard mine == epoch else { return }
        // Settle: the finished step becomes ordinary saved ink.
        writing = nil; signature = key(session)
        draw(layout.elements)
    }

    private func draw(_ elements: [InkElement]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        for element in elements { container.addSublayer(element.layer(animated: false)) }
        CATransaction.commit()
    }
    private func follow(_ element: InkElement) {
        let box = element.bounds
        guard !box.isEmpty, bounds.height > 0 else { return }
        let bottom = min(contentSize.height, (box.maxY + 16) * scale)
        let target = max(0, bottom - bounds.height)
        if target > contentOffset.y + 1 { setContentOffset(CGPoint(x: 0, y: target), animated: true) }
    }
    private func scrollToEnd(animated: Bool) {
        let target = max(0, contentSize.height - bounds.height)
        if abs(target - contentOffset.y) > 1 { setContentOffset(CGPoint(x: 0, y: target), animated: animated) }
    }
}

/// Plain-text record of a thread, for reading back or accessibility. Opens from the note.
@MainActor
struct TranscriptView: View {
    let session: StudySession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.title).font(HaloKit.text(17, .semibold))
                ForEach(session.messages) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.role == "user" ? "You" : "Halo").font(HaloKit.text(12, .semibold)).foregroundStyle(message.role == "user" ? HaloStyle.coral : HaloStyle.ink)
                        Text(message.text).font(HaloKit.text(15)).textSelection(.enabled)
                        let written = message.ink.compactMap { $0.type == "text" ? $0.value : nil }
                        if !written.isEmpty { Text(written.joined(separator: "   ")).font(.custom("Caveat-Regular", size: 22)).foregroundStyle(HaloStyle.ink) }
                    }
                }
            }.padding(16)
        }
    }
}
