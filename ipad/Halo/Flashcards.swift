import SwiftUI

// Flash cards from the student's notes: Halo writes the deck (the server), the student flips through it.
// Tap a card (or "Show answer") to turn it over, then say how it went: "Got it" puts it away, "Again" sends it
// to the back of the pile so it comes round once more. Swiping right or left does the same. At the end: how
// many they knew, and a go at just the ones they didn't.

@MainActor
struct FlashcardsView: View {
    @ObservedObject var store: StudyStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cards still to go, in order. "Again" puts a card back at the end.
    @State private var pile: [UUID] = []
    @State private var known: Set<UUID> = []
    @State private var missed: Set<UUID> = []
    @State private var flipped = false
    @State private var hint = false
    @State private var drag: CGSize = .zero
    @State private var dealt: FlashcardDeck?
    @State private var talking: Task<Void, Never>?
    @State private var cheers = 0

    private var deck: FlashcardDeck? { store.deck }
    private var cards: [Flashcard] { deck?.cards ?? [] }
    private var current: Flashcard? { pile.first.flatMap { id in cards.first { $0.id == id } } }
    private var finished: Bool { deck != nil && !cards.isEmpty && pile.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 8)
            Group {
                if store.deckLoading { making }
                else if let error = store.deckError { failed(error) }
                else if finished { summary }
                else if let card = current { practice(card) }
                else { making }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DeskPaper().ignoresSafeArea())
        .overlay { ConfettiBurst(trigger: cheers).allowsHitTesting(false) }
        .onChange(of: store.deck, initial: true) { _, deck in deal(deck) }
        .onDisappear { talking?.cancel(); store.player.stop() }
        .task { await script() }
    }
    /// `--flip "fk fa"`: f turns the card, k is "Got it", a is "Again", a space is a pause (for screenshots).
    private func script() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--flip"), i + 1 < args.count else { return }
        while store.deck == nil || pile.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        for step in args[i + 1] {
            try? await Task.sleep(for: .milliseconds(step == " " ? 1600 : 700))
            switch step { case "f": turn(); case "k": next(knew: true); case "a": next(knew: false); default: break }
        }
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            HaloRing(size: 42, working: store.deckLoading, symbol: "rectangle.on.rectangle.angled")
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow("Flash cards · \(store.deckScope)", color: HaloStyle.coral)
                Text(deck?.title ?? "Making your cards").font(HaloKit.title(28)).foregroundStyle(HaloStyle.text).lineLimit(2)
            }
            Spacer(minLength: 8)
            if deck != nil, !store.deckLoading {
                Button { store.remakeFlashcards() } label: {
                    Label("New cards", systemImage: "arrow.triangle.2.circlepath").font(HaloKit.text(14, .semibold))
                        .padding(.horizontal, 13).frame(height: 38).background(Color.white, in: Capsule())
                        .overlay(Capsule().stroke(HaloStyle.ink.opacity(0.12))).foregroundStyle(HaloStyle.ink)
                }.buttonStyle(.plain).accessibilityHint("Halo writes a fresh deck from the same notes")
            }
            HomeButton { Task { await store.goHome() } }
            CloseButton(label: "Back to my notes") { store.closeFlashcards() }
        }
    }

    // MARK: one card at a time
    private func practice(_ card: Flashcard) -> some View {
        VStack(spacing: 22) {
            progress
            ZStack {
                // The rest of the pile, peeking out from underneath.
                ForEach(0..<min(2, max(0, pile.count - 1)), id: \.self) { depth in
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.white)
                        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
                        .frame(maxWidth: 620).frame(height: 380)
                        .scaleEffect(1 - CGFloat(depth + 1) * 0.04).offset(y: CGFloat(depth + 1) * 14)
                }
                face(card)
                    .offset(x: drag.width, y: drag.height * 0.15)
                    .rotationEffect(.degrees(Double(drag.width) / 22))
                    .gesture(swipe)
                    .onTapGesture { turn() }
                    .id(card.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
            }
            .padding(.horizontal, 28)
            controls(card)
            Text(flipped ? "swipe right if you knew it, left to see it again" : "say the answer in your head, then tap the card")
                .font(HaloKit.hand(22)).foregroundStyle(HaloStyle.ink.opacity(0.75))
        }
        .padding(.bottom, 26)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.18), value: pile)
    }
    private var progress: some View {
        HStack(spacing: 10) {
            ScribbleChip(text: "\(known.count) of \(cards.count) known", icon: "checkmark.circle", tint: HaloKit.leaf)
            ScribbleChip(text: "\(pile.count) to go", icon: "rectangle.stack", tint: HaloStyle.ink)
        }
    }
    /// The card itself: the question on the front, the answer and the line of the notes it came from on the back.
    private func face(_ card: Flashcard) -> some View {
        let tint = drag.width > 40 ? HaloKit.leaf : drag.width < -40 ? HaloStyle.coral : Color.clear
        return ZStack {
            side(front: true, card).opacity(flipped ? 0 : 1)
            side(front: false, card).opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .frame(maxWidth: 620).frame(height: 380)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(tint.opacity(0.8), lineWidth: 3))
        .shadow(color: .black.opacity(0.1), radius: 22, y: 10)
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(flipped ? "Answer: \(card.back)" : "Question: \(card.front)")
        .accessibilityHint(flipped ? "" : "Double tap to see the answer")
        .accessibilityAddTraits(.isButton)
    }
    @ViewBuilder private func side(front: Bool, _ card: Flashcard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow(front ? "Question" : "Answer", color: front ? HaloStyle.ink : HaloStyle.coral)
                Spacer()
                Button { say(front ? card.front : card.back) } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 14, weight: .semibold)).foregroundStyle(HaloStyle.ink)
                        .frame(width: 34, height: 34).background(HaloStyle.ink.opacity(0.07), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Read it aloud")
            }
            Spacer(minLength: 0)
            if front {
                Text(card.front).font(HaloKit.title(31, .medium)).foregroundStyle(HaloStyle.text)
                    .multilineTextAlignment(.leading).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(card.back).font(HaloKit.hand(33)).foregroundStyle(HaloStyle.ink)
                    .multilineTextAlignment(.leading).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if front, !card.hint.isEmpty {
                if hint {
                    Label(card.hint, systemImage: "lightbulb").font(HaloKit.hand(23)).foregroundStyle(HaloKit.amber).transition(.opacity)
                } else {
                    Button { withAnimation(.spring(duration: 0.3)) { hint = true } } label: {
                        Label("A hint", systemImage: "lightbulb").font(HaloKit.text(13.5, .semibold)).foregroundStyle(HaloKit.amber)
                    }.buttonStyle(.plain)
                }
            }
            if !front, !card.source.isEmpty {
                Text("from your notes: “\(card.source)”").font(HaloKit.text(13)).foregroundStyle(HaloStyle.text.opacity(0.6))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(HaloKit.highlight.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    @ViewBuilder private func controls(_ card: Flashcard) -> some View {
        if flipped {
            HStack(spacing: 14) {
                Button { next(knew: false) } label: { Label("Again", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(PillButtonStyle(color: HaloStyle.coral, filled: false))
                Button { next(knew: true) } label: { Label("Got it", systemImage: "checkmark") }
                    .buttonStyle(PillButtonStyle(color: HaloKit.leaf))
            }
        } else {
            Button { turn() } label: { Label("Show answer", systemImage: "arrow.left.arrow.right") }
                .buttonStyle(PillButtonStyle(color: HaloStyle.ink))
        }
    }
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let far = value.translation.width + value.predictedEndTranslation.width * 0.2
                if far > 130 { next(knew: true) }
                else if far < -130 { next(knew: false) }
                else { withAnimation(.spring(duration: 0.35)) { drag = .zero } }
            }
    }

    // MARK: the end of the pile
    private var summary: some View {
        let all = cards.count, got = cards.filter { known.contains($0.id) && !missed.contains($0.id) }.count
        let practise = cards.filter { missed.contains($0.id) }
        return ScrollView {
            VStack(spacing: 18) {
                HaloRing(size: 84, symbol: got == all ? "star.fill" : "checkmark")
                Text(got == all ? "You knew every one." : "You knew \(got) of \(all) straight away.")
                    .font(HaloKit.title(36)).multilineTextAlignment(.center)
                Text(practise.isEmpty ? "come back tomorrow and they'll stick even better" : "these ones are worth another go")
                    .font(HaloKit.hand(25)).foregroundStyle(HaloStyle.ink)
                if !practise.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(practise) { card in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.front).font(HaloKit.text(15.5, .semibold)).foregroundStyle(HaloStyle.text)
                                Text(card.back).font(HaloKit.hand(22)).foregroundStyle(HaloStyle.ink)
                            }.frame(maxWidth: .infinity, alignment: .leading).haloCard(radius: 16, padding: 14)
                        }
                    }.frame(maxWidth: 560)
                }
                HStack(spacing: 12) {
                    if !practise.isEmpty {
                        Button { restart(practise.map(\.id)) } label: { Label(practise.count == 1 ? "Practise this one" : "Practise these \(practise.count)", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(PillButtonStyle(color: HaloStyle.coral))
                    }
                    Button { restart(cards.map(\.id).shuffled()) } label: { Label("Shuffle and start over", systemImage: "shuffle") }
                        .buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: practise.isEmpty))
                }
            }
            .padding(36).frame(maxWidth: .infinity)
        }
    }
    private var making: some View {
        VStack(spacing: 14) {
            HaloRing(size: 64, working: true)
            Text("Making your flash cards…").font(HaloKit.title(28))
            Text("one idea per card, straight from your notes").font(HaloKit.hand(24)).foregroundStyle(HaloStyle.ink)
        }.breathing()
    }
    private func failed(_ error: String) -> some View {
        VStack(spacing: 14) {
            EmptyDesk(title: "No cards this time", note: error, symbol: "exclamationmark")
            Button { store.remakeFlashcards() } label: { Label("Try again", systemImage: "arrow.clockwise") }.buttonStyle(PillButtonStyle(color: HaloStyle.ink))
        }
    }

    // MARK: moving through the pile
    private func deal(_ deck: FlashcardDeck?) {
        guard let deck, deck != dealt else { return }
        dealt = deck
        pile = deck.cards.map(\.id); known = []; missed = []; flipped = false; hint = false; drag = .zero
    }
    private func turn() {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15)) { flipped.toggle() }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
    private func next(knew: Bool) {
        guard let id = pile.first else { return }
        talking?.cancel(); store.player.stop()
        if knew { known.insert(id) } else { missed.insert(id) }
        UIImpactFeedbackGenerator(style: knew ? .medium : .light).impactOccurred()
        // Swiped away in the direction it was going, then the next card is dealt face up.
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) { drag = CGSize(width: knew ? 700 : -700, height: 40) }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 170))
            var rest = Array(pile.dropFirst())
            if !knew { rest.append(id) }
            flipped = false; hint = false; drag = .zero
            pile = rest
            if rest.isEmpty, missed.isEmpty { cheers += 1 }
        }
    }
    private func restart(_ ids: [UUID]) {
        known = known.subtracting(ids); missed = missed.subtracting(ids)
        flipped = false; hint = false; drag = .zero
        withAnimation(.spring(duration: 0.4)) { pile = ids }
    }
    /// Halo reads a side of the card aloud.
    private func say(_ text: String) {
        talking?.cancel(); store.player.stop()
        let server = store.serverURL, client = store.client, player = store.player, offline = store.demoMode
        talking = Task {
            let clip = offline ? nil : try? await client.speak(text, server: server)
            guard !Task.isCancelled else { return }
            try? await player.play(AnswerStep(index: 0, say: text, audio: clip))
        }
    }
}

/// The round white house in a page's corner: back to the start screen from anywhere.
struct HomeButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "house").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38)
                .background(Color.white, in: Circle()).overlay(Circle().stroke(HaloStyle.ink.opacity(0.12))).foregroundStyle(HaloStyle.text)
        }.buttonStyle(.plain).accessibilityLabel("Home").accessibilityHint("Back to the start screen")
    }
}
