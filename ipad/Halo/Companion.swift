import SwiftUI

// Halo, the companion. The avatar sits by the page the whole time: it watches, dozes, cheers, and takes any
// request, typed or spoken, with or without a circle ("explain this page", "go to page 12", "quiz me",
// "find entropy"). Tapping it opens everything Halo can do, with words on every button.

/// The bar along the bottom of the page (or the top, while the Pencil palette owns the bottom):
/// Halo itself, a place to ask it anything, and the page tools.
@MainActor
struct HaloDock: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var speech: SpeechInput
    /// Docked at the top of the page: what pops out of it opens downwards.
    var atTop = false
    /// Room for words on the page tools.
    var wide = true
    /// The page area Halo can be dragged around in.
    var area: CGSize
    @State private var text = ""
    @FocusState private var focused: Bool
    /// Where the student parked Halo, as an offset from its home corner: there may be notes under it.
    @AppStorage("halo.parkedX") private var parkedX = 0.0
    @AppStorage("halo.parkedY") private var parkedY = 0.0
    @GestureState private var drag = CGSize.zero
    /// The field holds what Halo heard, not something typed.
    @State private var dictated = false
    init(store: StudyStore, atTop: Bool = false, wide: Bool = true, area: CGSize) { self.store = store; self.speech = store.speech; self.atTop = atTop; self.wide = wide; self.area = area }

    /// Keeps the avatar on the page, whatever was saved and however the iPad is turned.
    private func onPage(_ x: Double, _ y: Double) -> CGSize {
        let margin = max(0, (area.width - 972) / 2), reach = max(0, area.height - 112)
        return CGSize(width: max(-margin, min(x, area.width - margin - 112)), height: atTop ? max(0, min(y, reach)) : min(0, max(y, -reach)))
    }
    private func parked(after drag: CGSize) -> CGSize {
        let home = onPage(parkedX, parkedY)
        return onPage(home.width + drag.width, home.height + drag.height)
    }

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if atTop { bar; extras } else { extras; bar }
        }
        .frame(maxWidth: 940, alignment: .leading)
        .padding(.horizontal, 16)
        // The open bar and menu need the full width, so they open at home; put away, Halo goes back to where it was parked.
        .offset(store.showDock ? .zero : parked(after: drag))
        .animation(.spring(duration: 0.35, bounce: 0.15), value: focused)
        .onChange(of: store.showLauncher) { _, open in if open { focused = false } }
        // Spoken words that were sent (or abandoned) don't wait in the field for next time; a typed draft does.
        .onChange(of: store.showDock) { _, open in if !open, dictated { text = ""; dictated = false } }
    }

    /// What opens out of the dock: the menu, ideas for what to ask, or a word from Halo.
    @ViewBuilder private var extras: some View {
        if store.showLauncher {
            HaloLauncher(store: store).transition(.scale(scale: 0.9, anchor: atTop ? .topLeading : .bottomLeading).combined(with: .opacity))
        } else if focused, typed.isEmpty {
            ideas.transition(.move(edge: atTop ? .top : .bottom).combined(with: .opacity))
        } else if let says = store.haloSays {
            Text(says).hand(25).foregroundStyle(HaloStyle.text).lineLimit(2)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(BubbleShape(tail: atTop ? .top : .leading).fill(Color.white).shadow(color: HaloStyle.ink.opacity(0.16), radius: 10, y: 4))
                .padding(.leading, atTop ? 6 : 92).padding(.top, atTop ? 8 : 0)
                .transition(.scale(scale: 0.6, anchor: atTop ? .topLeading : .bottomLeading).combined(with: .opacity))
                .accessibilityLabel("Halo says: \(says)")
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            avatar
            if store.showDock { field }
        }
    }

    /// The ask field and page tools, slid out from the avatar.
    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            HaloComposer(text: $text, prompt: store.dockHeard == nil ? "Ask Halo…" : store.learner.name.isEmpty ? "Hey, I’m listening…" : "Hey \(store.learner.name), I’m listening…",
                         recording: store.dockHeard != nil,
                         microphone: { if store.dockHeard != nil { store.stopDockListening() } else { store.askAboutPage(store.pageIndex) } },
                         focus: $focused, send: send)
                // Words appear in the field as they are heard; touching the field means typing instead.
                .onChange(of: store.dockHeard) { _, heard in if let heard { text = heard; dictated = true } }
                .onChange(of: focused) { _, typing in if typing { store.stopDockListening(); dictated = false } }
                .accessibilityHint("A question about this page, or something to do, like go to page 12 or quiz me")
            ScrollView(.horizontal, showsIndicators: false) {
                // Its own card: bare icons over a dark page couldn't be seen.
                tools.fixedSize(horizontal: true, vertical: false)
                    .padding(4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(HaloStyle.ink.opacity(0.12)))
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
                    .padding(.vertical, 8).padding(.horizontal, 2)   // room for the shadow inside the scroll view
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var avatar: some View {
        // A tap and a drag on one view: a Button would also fire when a drag ends on it.
        Group {
            TutorAvatar(cue: store.haloCue, size: 104, voiceLevel: { [store] in store.player.outputLevel }, micLevel: { [speech] in CGFloat(speech.meter.value) })
                .offset(y: -5)
                .frame(width: 80, height: 80)
                .background(Color.white, in: Circle())
                .overlay(Circle().stroke(HaloStyle.coral.opacity(store.showLauncher ? 0.7 : 0.18), lineWidth: 2))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                .overlay(alignment: .topTrailing) {
                    if store.streak >= 2 {
                        HStack(spacing: 2) {
                            Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold))
                            Text("\(store.streak)").font(HaloKit.text(12, .bold).monospacedDigit())
                        }
                        .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(HaloStyle.coral, in: Capsule()).offset(x: 6, y: -2)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("\(store.streak) steps right in a row")
                    }
                }
        }
        .contentShape(Circle())
        .onTapGesture { focused = false; store.pokeHalo() }
        .gesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($drag) { value, state, _ in state = value.translation }
            // Dragging Halo while its bar is open puts the bar away and moves it.
            .onChanged { _ in if store.showDock { store.tuckDock() } }
            .onEnded { value in
                let end = parked(after: value.translation)
                parkedX = end.width; parkedY = end.height
            })
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .accessibilityLabel(store.showDock ? "Put Halo’s bar away" : "Halo. Ask, tools and everything it can do")
        .accessibilityHint("Drag to move Halo off your notes")
    }

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(ReaderTool.allCases, id: \.self) { tool in
                let on = store.tool == tool
                Button { withAnimation(.spring(duration: 0.3)) { store.tool = tool } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tool == .circle ? "circle.dashed" : tool == .write ? "pencil.tip" : "book")
                        Text(tool.rawValue).lineLimit(1).fixedSize()
                    }
                    .font(HaloKit.text(13, .semibold))
                    .padding(.horizontal, on ? 12 : 9).frame(height: 38)
                    .background(on ? (tool == .circle ? HaloStyle.coral : HaloStyle.ink) : Color.clear, in: Capsule())
                    .foregroundStyle(on ? .white : HaloStyle.text)
                }.buttonStyle(.plain).accessibilityLabel(tool.rawValue).accessibilityAddTraits(on ? .isSelected : [])
            }
            Button { store.tutorMode.toggle(); store.react(.happy, say: store.tutorMode ? "Hints only. You do the thinking" : "Full answers again") } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.tutorMode ? "lightbulb.fill" : "lightbulb")
                    Text("Hints").lineLimit(1).fixedSize()
                }
                .font(HaloKit.text(13, .semibold)).padding(.horizontal, 10).frame(height: 38)
                .background(store.tutorMode ? HaloKit.amber : Color.clear, in: Capsule())
                .foregroundStyle(store.tutorMode ? .white : HaloStyle.text)
            }.buttonStyle(.plain).accessibilityLabel("Tutor mode: hints instead of answers").accessibilityAddTraits(store.tutorMode ? .isSelected : [])
            if store.tool == .circle {
                Button { store.circleWithFinger.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: store.circleWithFinger ? "hand.point.up.left.fill" : "hand.point.up.left")
                        Text("Finger").lineLimit(1).fixedSize()
                    }
                    .font(HaloKit.text(13, .semibold)).padding(.horizontal, 10).frame(height: 38)
                    .background(store.circleWithFinger ? HaloStyle.ink.opacity(0.15) : Color.clear, in: Capsule()).foregroundStyle(HaloStyle.text)
                }.buttonStyle(.plain).accessibilityLabel("Circle with a finger too").accessibilityAddTraits(store.circleWithFinger ? .isSelected : [])
            }
            if store.demoMode { Text("DEMO").font(HaloKit.text(9, .bold)).padding(.horizontal, 6).padding(.vertical, 3).background(.orange.opacity(0.15), in: Capsule()) }
        }
    }

    /// Things worth asking, offered the moment the field is tapped.
    private var ideas: some View {
        let list = ["Explain this page", "Give me an example", "Quiz me on this chapter", "What’s this chapter about?", "Find ", "Go to page "]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(list, id: \.self) { idea in
                    Button {
                        // "Find " and "Go to page " are the start of a sentence the student finishes.
                        if idea.hasSuffix(" ") { text = idea } else { text = ""; focused = false; store.askHalo(idea) }
                    } label: {
                        Text(idea.hasSuffix(" ") ? idea + "…" : idea).hand(22).lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Color.white, in: Capsule()).overlay(Capsule().stroke(HaloStyle.ink.opacity(0.12)))
                            .foregroundStyle(HaloStyle.ink).shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                    }.buttonStyle(.plain)
                }
            }.padding(.leading, 92).padding(.vertical, 4)
        }
    }

    private func send() {
        let asked = typed
        guard !asked.isEmpty else { return }
        text = ""; focused = false
        store.stopDockListening()
        store.askHalo(asked)
    }
}

/// Everything Halo can do with this document, on one card, in words.
@MainActor
struct HaloLauncher: View {
    @ObservedObject var store: StudyStore

    private struct Tile: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let note: String
        let tint: Color
        let action: () -> Void
    }
    private var tiles: [Tile] {
        let asked = store.notes.sessions.filter { !$0.messages.isEmpty }.count
        return [
            Tile(id: 0, icon: "bubble.left.and.text.bubble.right", title: "Ask about this page", note: "out loud, no circle needed", tint: HaloStyle.coral) { store.askAboutPage(store.pageIndex) },
            Tile(id: 1, icon: "graduationcap", title: "Teach me this chapter", note: store.currentChapter?.title ?? "one idea at a time", tint: HaloStyle.ink) { store.openLesson() },
            Tile(id: 2, icon: "text.magnifyingglass", title: "Find anything", note: "chapters · notes · search", tint: HaloKit.leaf) { store.openNavigator(store.navigatorTab) },
            Tile(id: 3, icon: "square.and.pencil", title: "My notes", note: "Halo improves them", tint: HaloKit.amber) { store.openNotebook() },
            Tile(id: 4, icon: "list.clipboard", title: "Session summary", note: asked == 0 ? "everything you asked" : "\(asked) question\(asked == 1 ? "" : "s") so far", tint: HaloStyle.ink) { store.openRecap() },
            Tile(id: 5, icon: "sparkles", title: store.isBook ? "Halo’s read of this chapter" : "Halo’s read of this", note: "the ideas to keep", tint: HaloStyle.coral) { store.showBrief() },
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow("Halo", color: HaloStyle.coral)
                    Text("What should we do?").font(HaloKit.title(26)).foregroundStyle(HaloStyle.text)
                }
                Spacer(minLength: 8)
                CloseButton(label: "Close Halo’s menu") { withAnimation(.spring(duration: 0.3)) { store.showLauncher = false } }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(tiles) { tile in
                    Button { store.showDock = false; store.showLauncher = false; tile.action() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: tile.icon).font(.system(size: 17, weight: .medium)).foregroundStyle(tile.tint)
                                .frame(width: 40, height: 40).background(tile.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            VStack(alignment: .leading, spacing: 0) {
                                // Tiles are about 250pt wide on a 10.5-inch iPad: wrap rather than cut words off.
                                Text(tile.title).font(HaloKit.text(15.5, .semibold)).foregroundStyle(HaloStyle.text)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                // One line, cut with an ellipsis: a long chapter name used to wrap and stop mid-word.
                                Text(tile.note).hand(20).foregroundStyle(HaloStyle.ink).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        // Every tile the same height (room for a two-line title), so icons and words line up across a row.
                        .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 78)
                        .background(HaloStyle.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).arrives(tile.id)
                }
            }
            Text("or just tell me: “go to page 12” · “find entropy” · “quiz me”")
                .hand(22).foregroundStyle(HaloStyle.ink.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(18).frame(maxWidth: 560)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 26, y: 12)
    }
}
