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
    @State private var text = ""
    @FocusState private var focused: Bool
    init(store: StudyStore, atTop: Bool = false, wide: Bool = true) { self.store = store; self.speech = store.speech; self.atTop = atTop; self.wide = wide }

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if atTop { bar; extras } else { extras; bar }
        }
        .frame(maxWidth: 940, alignment: .leading)
        .padding(.horizontal, 16)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: focused)
        .onChange(of: store.showLauncher) { _, open in if open { focused = false } }
    }

    /// What opens out of the dock: the menu, ideas for what to ask, or a word from Halo.
    @ViewBuilder private var extras: some View {
        if store.showLauncher {
            HaloLauncher(store: store).transition(.scale(scale: 0.9, anchor: atTop ? .topLeading : .bottomLeading).combined(with: .opacity))
        } else if focused, typed.isEmpty {
            ideas.transition(.move(edge: atTop ? .top : .bottom).combined(with: .opacity))
        } else if let says = store.haloSays {
            Text(says).font(HaloKit.hand(25)).foregroundStyle(HaloStyle.text).lineLimit(2)
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
        HStack(spacing: 6) {
            TextField("Ask Halo anything…", text: $text)
                .font(HaloKit.text(16.5)).textFieldStyle(.plain).submitLabel(.send).focused($focused)
                .onSubmit(send).padding(.leading, 16).frame(minWidth: 120)
                .accessibilityHint("A question about this page, or something to do, like go to page 12 or quiz me")
            if typed.isEmpty {
                Button { focused = false; store.askAboutPage(store.pageIndex) } label: {
                    Image(systemName: "mic.fill").font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                        .background(HaloStyle.coral, in: Circle()).foregroundStyle(.white)
                }.buttonStyle(.plain).accessibilityLabel("Ask out loud")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38)
                        .background(HaloStyle.coral, in: Circle()).foregroundStyle(.white)
                }.buttonStyle(.plain).accessibilityLabel("Send to Halo")
            }
            Divider().frame(height: 24).padding(.horizontal, 2)
            tools
        }
        .padding(5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(focused ? HaloStyle.coral.opacity(0.55) : Color.clear, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var avatar: some View {
        Button { focused = false; store.pokeHalo() } label: {
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
        .buttonStyle(.plain)
        .accessibilityLabel(store.showDock ? "Put Halo’s bar away" : "Halo. Ask, tools and everything it can do")
    }

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(ReaderTool.allCases, id: \.self) { tool in
                let on = store.tool == tool
                Button { withAnimation(.spring(duration: 0.3)) { store.tool = tool } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tool == .circle ? "circle.dashed" : tool == .write ? "pencil.tip" : "book")
                        if on || wide { Text(tool.rawValue).lineLimit(1).fixedSize() }
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
                    if wide { Text("Hints").lineLimit(1).fixedSize() }
                }
                .font(HaloKit.text(13, .semibold)).padding(.horizontal, 10).frame(height: 38)
                .background(store.tutorMode ? HaloKit.amber : Color.clear, in: Capsule())
                .foregroundStyle(store.tutorMode ? .white : HaloStyle.text)
            }.buttonStyle(.plain).accessibilityLabel("Tutor mode: hints instead of answers").accessibilityAddTraits(store.tutorMode ? .isSelected : [])
            if store.tool == .circle {
                Button { store.circleWithFinger.toggle() } label: {
                    Image(systemName: store.circleWithFinger ? "hand.point.up.left.fill" : "hand.point.up.left").font(.system(size: 13, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(store.circleWithFinger ? HaloStyle.ink.opacity(0.15) : Color.clear, in: Circle()).foregroundStyle(HaloStyle.text)
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
                        Text(idea.hasSuffix(" ") ? idea + "…" : idea).font(HaloKit.hand(22)).lineLimit(1)
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
            Tile(id: 1, icon: "graduationcap", title: "Teach me this chapter", note: store.currentChapter.map { String($0.title.prefix(28)) } ?? "one idea at a time", tint: HaloStyle.ink) { store.openLesson() },
            Tile(id: 2, icon: "text.magnifyingglass", title: "Find anything", note: "chapters · notes · search", tint: HaloKit.leaf) { store.openNavigator(store.navigatorTab) },
            Tile(id: 3, icon: "square.and.pencil", title: "My notes", note: "write them, Halo improves them", tint: HaloKit.amber) { store.openNotebook() },
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
                                Text(tile.note).font(HaloKit.hand(20)).foregroundStyle(HaloStyle.ink)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(HaloStyle.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).arrives(tile.id)
                }
            }
            Text("or just tell me: “go to page 12” · “find entropy” · “quiz me”")
                .font(HaloKit.hand(22)).foregroundStyle(HaloStyle.ink.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(18).frame(maxWidth: 560)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 26, y: 12)
    }
}
