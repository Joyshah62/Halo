import SwiftUI

// The first screen, before a document is open: what Halo does, in the order a student meets it,
// and the two ways in (import a PDF, or try the sample lesson). Returning students get a
// "pick up where you left off" card first.

@MainActor
struct LandingView: View {
    @ObservedObject var store: StudyStore
    var importPDF: () -> Void
    @State private var question = ""

    private struct Feature: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let detail: String
        let scribble: String
        let accent: Color
    }
    private let features: [Feature] = [
        Feature(id: 0, icon: "sparkles", title: "It reads it first",
                detail: "Import slides or a book and Halo reads it before you do: the three ideas to keep, where it gets hard, and where to start. Books are briefed a chapter at a time.",
                scribble: "start at page 7", accent: HaloStyle.coral),
        Feature(id: 1, icon: "circle.dashed", title: "Circle and ask, out loud",
                detail: "Loop anything with the Pencil and just ask. Halo answers in its voice, writes beside your circle, and highlights the lines on the page it’s talking about.",
                scribble: "outside′ × inside′", accent: HaloStyle.ink),
        Feature(id: 2, icon: "pencil.and.scribble", title: "It watches you work",
                detail: "Solve by hand on the page. When you pause, Halo checks each line: a ✓ when it’s right, and a circle with a spoken hint (never the answer) when it isn’t.",
                scribble: "2x = 7 − 3  ✓", accent: Color(red: 0.13, green: 0.55, blue: 0.35)),
        Feature(id: 3, icon: "square.and.pencil", title: "Your notes, made better",
                detail: "Type or handwrite your own notes, however rough, with or without a PDF open. Enhance organizes them, fills the gaps, fixes what’s wrong and adds a diagram where one helps.",
                scribble: "✦ enhanced", accent: Color(red: 0.71, green: 0.33, blue: 0.04)),
        Feature(id: 4, icon: "list.clipboard", title: "A summary to revise from",
                detail: "Every question you asked and how it was explained, cleaned up and grouped by chapter. Tap any note to jump back to its page.",
                scribble: "today · 6 questions", accent: HaloStyle.ink),
        Feature(id: 5, icon: "person.crop.circle", title: "It knows you",
                detail: "Your course, your level, how you like things explained, and what you’ve been stuck on lately shape every answer. Turn on Tutor for hints instead of answers.",
                scribble: "same idea as last week", accent: HaloStyle.coral),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                hero.arrives(0)
                ask.arrives(1)
                actions.arrives(2)
                if !store.documents.isEmpty { shelf.arrives(3) }
                grid
                footer
            }
            .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 48)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .background(DeskPaper().ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .onAppear { greetedAt = Date() }
    }

    // MARK: hero: Halo says hello
    @State private var greetedAt = Date()
    @State private var pokes = 0
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let hello = hour < 5 ? "Up late" : hour < 12 ? "Morning" : hour < 18 ? "Hey" : "Evening"
        return store.learner.name.isEmpty ? "\(hello)! I’m Halo." : "\(hello), \(store.learner.name)."
    }
    private var hero: some View {
        VStack(spacing: 6) {
            // Halo greets you, and reacts when poked.
            Button { pokes += 1; greetedAt = Date() } label: {
                TutorAvatar(cue: TutorCue(base: .idle, reaction: pokes == 0 ? .happy : (pokes % 3 == 0 ? .proud : .wink), reactionUntil: greetedAt.addingTimeInterval(pokes == 0 ? 2.2 : 1.4),
                                          sleepAt: greetedAt.addingTimeInterval(90)), size: 190)
            }.buttonStyle(.plain).accessibilityLabel("Halo")
            Text(greeting).font(HaloKit.title(50)).foregroundStyle(HaloStyle.text).multilineTextAlignment(.center)
            Text("What are we learning today?").font(HaloKit.hand(34)).foregroundStyle(HaloStyle.ink).rotationEffect(.degrees(-1))
            if let error = store.error { Text(error).font(HaloKit.text(13)).foregroundStyle(.red).multilineTextAlignment(.center).padding(.top, 6) }
        }
    }

    // MARK: ask anything
    private static let ideas = ["Why is the sky blue?", "How does CRISPR edit a gene?", "Why does the chain rule multiply?", "Show me a video on black holes"]
    private var ask: some View {
        VStack(spacing: 12) {
            HaloComposer(text: $question, prompt: "Ask Halo…", send: look)
            FlowRow(spacing: 8) {
                ForEach(Self.ideas, id: \.self) { idea in
                    Button { store.askHalo(idea) } label: {
                        Text(idea).font(HaloKit.hand(22)).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Color.white.opacity(0.85), in: Capsule()).overlay(Capsule().stroke(HaloStyle.ink.opacity(0.12))).foregroundStyle(HaloStyle.ink)
                    }.buttonStyle(.plain)
                }
            }
            Text("I look it up, explain it with sources, pin up real pictures and find the right moment in a video.")
                .font(HaloKit.text(14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 720)
    }
    private func look() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        question = ""; store.askHalo(asked)
    }

    // MARK: the ways in
    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
            way("plus", "Import a document", "PDF, PowerPoint or Word", HaloStyle.coral, filled: true, action: importPDF)
            way("play.fill", "Try a sample lesson", "two minutes, no setup", HaloStyle.ink) { Task { await store.openSample() } }
            way("square.and.pencil", "Start a note", store.looseNotes.isEmpty ? "rough is fine, I’ll tidy it" : "\(store.looseNotes.count) quick note\(store.looseNotes.count == 1 ? "" : "s")", HaloKit.amber) { store.openQuickNotes(new: store.looseNotes.isEmpty) }
        }
        .frame(maxWidth: 760)
    }
    private func way(_ icon: String, _ title: String, _ note: String, _ tint: Color, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(filled ? tint : .white)
                    .frame(width: 42, height: 42).background(filled ? Color.white : tint, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    // Three cards share a row on a 10.5-inch iPad (about 240pt each): wrap rather than cut words off.
                    Text(title).font(HaloKit.text(16.5, .semibold)).foregroundStyle(filled ? .white : HaloStyle.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(note).font(HaloKit.hand(21)).foregroundStyle(filled ? Color.white.opacity(0.92) : HaloStyle.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(filled ? tint : Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: (filled ? tint : Color.black).opacity(filled ? 0.25 : 0.06), radius: 14, y: 6)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: your shelf
    private var shelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow("Your shelf")
                Text("tap one to pick up where you left off").font(HaloKit.hand(21)).foregroundStyle(HaloStyle.ink.opacity(0.8))
            }.padding(.leading, 4)
            // As many across as fit whole (four on a 10.5-inch iPad), then onto the next row: no card is cut off by the edge.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 166), spacing: 18, alignment: .top)], alignment: .leading, spacing: 28) {
                ForEach(Array(shelfItems.prefix(8).enumerated()), id: \.element.id) { index, item in
                    Button { Task { await store.open(item) } } label: { book(item, latest: index == 0, tilt: [-1.4, 1.1, -0.6, 1.6][index % 4]) }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 12)
        }
    }
    /// Your documents, with the sample lesson only once however many times it was opened (newest copy).
    private var shelfItems: [LibraryDocument] {
        var sampleShown = false
        return store.documents.filter { item in
            guard item.name == "A little calculus" else { return true }
            defer { sampleShown = true }
            return !sampleShown
        }
    }
    private func book(_ item: LibraryDocument, latest: Bool, tilt: Double) -> some View {
        Taped(tilt: tilt) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "book.pages").font(.system(size: 20)).foregroundStyle(HaloStyle.coral)
                    .frame(width: 42, height: 42).background(HaloStyle.coral.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(item.displayName).font(HaloKit.title(15.5, .semibold)).foregroundStyle(HaloStyle.text).lineLimit(5).minimumScaleFactor(0.85).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                Text("\(item.pageCount) pages").font(HaloKit.text(12)).foregroundStyle(.secondary)
                Text(latest ? "continue →" : item.lastOpenedAt.formatted(.relative(presentation: .named))).font(HaloKit.hand(21)).foregroundStyle(latest ? HaloStyle.coral : HaloStyle.ink).lineLimit(1)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine).accessibilityHint("Opens this document")
    }

    // MARK: what it does
    private var grid: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("What Halo does").padding(.leading, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], spacing: 16) {
                ForEach(features) { feature in
                    Group {
                        if feature.id == 3 {
                            Button { store.openQuickNotes() } label: { card(feature) }.buttonStyle(.plain).accessibilityHint("Opens your quick notes")
                        } else { card(feature) }
                    }.arrives(4 + feature.id)
                }
            }
        }
    }
    private func card(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Image(systemName: feature.icon).font(.system(size: 18, weight: .medium)).foregroundStyle(feature.accent)
                    .frame(width: 40, height: 40).background(feature.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Spacer(minLength: 6)
                Text("\(feature.id + 1)").font(HaloKit.hand(34)).foregroundStyle(feature.accent.opacity(0.55))
            }
            Text(feature.title).font(HaloKit.title(19, .semibold)).foregroundStyle(HaloStyle.text)
            Text(feature.detail).font(HaloKit.text(14.5)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(feature.scribble).font(.custom("Caveat-Regular", size: 23)).foregroundStyle(HaloStyle.ink).rotationEffect(.degrees(-1.5))
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 7)
        .accessibilityElement(children: .combine)
    }

    // MARK: footer
    private var footer: some View {
        VStack(spacing: 6) {
            Text("Works best with Apple Pencil. A finger works too: tap Halo, then the hand in its bar.")
            Text("Your documents and notes stay on this iPad. What you circle or ask about is sent to your Halo server.")
        }
        .font(HaloKit.text(12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
    }
}
