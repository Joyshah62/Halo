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
                lookup.arrives(2)
                if let recent = store.documents.first { resume(recent).arrives(3) }
                grid
                footer
            }
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 48)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .background(DeskPaper().ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: hero
    private var hero: some View {
        VStack(spacing: 18) {
            ZStack {
                HaloRing(size: 72)
                Text("halo.").font(HaloKit.hand(28)).foregroundStyle(HaloStyle.ink).offset(x: 58, y: 28)
            }.padding(.bottom, 6)
            Text(store.learner.name.isEmpty ? "A tutor that lives\nin your reading." : "Hey \(store.learner.name).\nWhat are we working on?")
                .font(.system(size: 50, design: .serif)).foregroundStyle(HaloStyle.text).multilineTextAlignment(.center)
            Text("Bring your lecture slides, a textbook or a problem set. Halo reads it with you, answers out loud when you circle something, checks your working, looks things up on the web, and turns your notes into ones worth revising from.")
                .font(.system(size: 17)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 680)
            HStack(spacing: 12) {
                Button(action: importPDF) { Label("Import a PDF", systemImage: "plus").frame(minWidth: 150) }.buttonStyle(PillButtonStyle())
                Button { store.openQuickNotes(new: true) } label: { Label("Start a note", systemImage: "square.and.pencil").frame(minWidth: 150) }
                    .buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: false))
                Button { Task { await store.openSample() } } label: { Label("Try a sample lesson", systemImage: "play.fill").frame(minWidth: 150) }
                    .buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: false))
            }.padding(.top, 8)
            Text("circle anything · ask out loud · watch it answer").font(HaloKit.hand(24)).foregroundStyle(HaloStyle.ink.opacity(0.8)).rotationEffect(.degrees(-1))
            if let error = store.error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
        }
    }

    // MARK: ask the web
    private static let ideas = ["Why is the sky blue?", "How does CRISPR edit a gene?", "Why does the chain rule multiply?"]
    private var lookup: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("NEW").font(.system(size: 10.5, weight: .bold)).tracking(1.1).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3).background(HaloStyle.coral, in: Capsule())
                Text("Halo goes and finds out").font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(HaloStyle.text)
                Spacer(minLength: 0)
                Text("it even watches the video").font(.custom("Caveat-Regular", size: 23)).foregroundStyle(HaloStyle.ink).rotationEffect(.degrees(-1.5)).lineLimit(1)
            }
            Text("Ask anything, or say “show me a video” after you circle. Halo searches the web, explains it with sources you can open, pins up real pictures, and watches the best video so it can skip you to the part that answers your question.")
                .font(.system(size: 14.5)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: "globe").font(.system(size: 17, weight: .medium)).foregroundStyle(HaloStyle.coral)
                TextField("Look something up…", text: $question).font(.system(size: 17)).textFieldStyle(.plain).submitLabel(.search).onSubmit(look)
                Button(action: look) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).frame(width: 34, height: 34)
                        .background(question.trimmingCharacters(in: .whitespaces).isEmpty ? HaloStyle.ink.opacity(0.2) : HaloStyle.coral, in: Circle()).foregroundStyle(.white)
                }.buttonStyle(.plain).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityLabel("Look it up")
            }
            .padding(.leading, 16).padding(.trailing, 8).frame(height: 52)
            .background(HaloStyle.paper, in: Capsule()).overlay(Capsule().stroke(HaloStyle.ink.opacity(0.14)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.ideas, id: \.self) { idea in
                        Button { store.startDive(idea) } label: {
                            Text(idea).font(.system(size: 13.5, weight: .medium)).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 7)
                                .background(HaloStyle.ink.opacity(0.07), in: Capsule()).foregroundStyle(HaloStyle.ink)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(22)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(HaloStyle.coral.opacity(0.35), lineWidth: 1.5))
        .shadow(color: HaloStyle.coral.opacity(0.1), radius: 18, y: 8)
    }
    private func look() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        question = ""; store.startDive(asked)
    }

    // MARK: pick up where you left off
    private func resume(_ item: LibraryDocument) -> some View {
        Button { Task { await store.open(item) } } label: {
            HStack(spacing: 14) {
                Image(systemName: "book.pages").font(.system(size: 22)).foregroundStyle(HaloStyle.coral)
                    .frame(width: 46, height: 46).background(HaloStyle.coral.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("PICK UP WHERE YOU LEFT OFF").font(.system(size: 10.5, weight: .bold)).tracking(1.1).foregroundStyle(.secondary)
                    Text(item.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(HaloStyle.text).lineLimit(1)
                    Text("\(item.pageCount) pages · opened \(item.lastOpenedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(HaloStyle.ink)
            }
            .padding(16).frame(maxWidth: 560)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
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
            Text(feature.title).font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(HaloStyle.text)
            Text(feature.detail).font(.system(size: 14.5)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
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
            Text("Works best with Apple Pencil. A finger works too: switch it on in the bottom bar.")
            Text("Your documents and notes stay on this iPad. What you circle or ask about is sent to your Halo server.")
        }
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
    }
}
