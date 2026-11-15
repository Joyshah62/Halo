import SwiftUI

// The session summary: a clean written record of the sitting. For every question, what was
// asked and how it was explained, with the sticky note Halo wrote beside it. Nothing is spoken.

enum RecapScope: String, CaseIterable, Hashable { case today = "Today", all = "All notes" }

@MainActor
struct RecapView: View {
    @ObservedObject var store: StudyStore
    private var sessions: [StudySession] { store.recapNotes(store.recapScope) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if sessions.isEmpty { empty } else { summary }
            }
            .padding(.horizontal, 36).padding(.top, 30).padding(.bottom, 60)
            .frame(maxWidth: 1160, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DeskPaper().ignoresSafeArea())
        .onChange(of: store.recapScope) { _, _ in store.makeRecap() }
    }

    // MARK: header
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(eyebrow: store.recapLoading ? "Halo is writing it up" : "Your session, written up",
                       title: store.recap?.headline ?? (sessions.isEmpty ? "Nothing here yet" : "Session summary"),
                       note: store.displayTitle, working: store.recapLoading, symbol: store.recapLoading ? nil : "list.clipboard") {
                HStack(spacing: 10) {
                    HStack(spacing: 0) {
                        ForEach(RecapScope.allCases, id: \.self) { scope in
                            let on = store.recapScope == scope
                            Button { withAnimation(.spring(duration: 0.3)) { store.recapScope = scope } } label: {
                                Text(scope.rawValue).font(HaloKit.text(14, .semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(on ? HaloStyle.ink : .clear, in: Capsule()).foregroundStyle(on ? .white : HaloStyle.ink)
                            }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(3).background(Color.white, in: Capsule()).overlay(Capsule().stroke(HaloStyle.ink.opacity(0.12)))
                    HomeButton { Task { await store.goHome() } }
                    CloseButton(label: "Done") { store.closeRecap() }
                }
            }
            if !sessions.isEmpty {
                FlowRow(spacing: 9) {
                    ScribbleChip(text: "\(questionCount) question\(questionCount == 1 ? "" : "s")", icon: "questionmark.bubble")
                    ScribbleChip(text: "\(pageCount) page\(pageCount == 1 ? "" : "s")", icon: "doc.text")
                    ScribbleChip(text: "\(sessions.count) note\(sessions.count == 1 ? "" : "s") from Halo", icon: "note.text")
                    ForEach(topics, id: \.self) { ScribbleChip(text: $0.lowercased(), icon: "tag", tint: HaloStyle.ink) }
                }
            }
            if let overview = store.recap?.overview, !overview.isEmpty {
                Sticky(label: "In short", tilt: -0.4) {
                    Text(overview).hand(27).foregroundStyle(HaloStyle.text).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 2).transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
    }
    private var questionCount: Int { sessions.reduce(0) { $0 + $1.messages.filter { $0.role == "user" }.count } }
    private var pageCount: Int { Set(sessions.map(\.pageIndex)).count }
    private var topics: [String] {
        var seen = Set<String>()
        return sessions.map(\.topic).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(4).map { $0 }
    }
    private var empty: some View {
        EmptyDesk(title: store.recapScope == .today ? "No questions from today" : "No questions yet",
                  note: store.recapScope == .today ? "switch to All notes to look back over earlier sessions" : "circle something on a page and ask: every question and how it was explained ends up here")
            .padding(.top, 60)
    }

    // MARK: what was asked, and how it was explained
    @ViewBuilder private var summary: some View {
        if let recap = store.recap {
            Group {
                if store.chapters.isEmpty {
                    group(title: nil, sessions, recap)
                } else {
                    ForEach(store.chapters) { chapter in
                        let mine = sessions.filter { chapter.contains($0.pageIndex) }
                        if !mine.isEmpty { group(title: chapter.title, mine, recap) }
                    }
                }
            }.transition(.opacity)
        } else if store.recapLoading {
            VStack(alignment: .leading, spacing: 14) {
                Text("Summarizing your questions…").hand(26).foregroundStyle(HaloStyle.ink)
                ForEach(0..<5, id: \.self) { row in
                    RoundedRectangle(cornerRadius: 5).fill(HaloStyle.ink.opacity(0.07)).frame(height: 13).frame(maxWidth: row % 3 == 2 ? 320 : .infinity, alignment: .leading)
                }
            }.haloCard().breathing()
        }
    }
    private func group(title: String?, _ notes: [StudySession], _ recap: SessionRecap) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(HaloKit.title(24, .semibold)).foregroundStyle(HaloStyle.text)
                    Text("\(notes.count) question\(notes.count == 1 ? "" : "s")").hand(22).foregroundStyle(HaloStyle.ink)
                }.padding(.top, 6)
            }
            ForEach(Array(notes.enumerated()), id: \.element.id) { order, session in
                RecapRow(session: session, item: recap.items.first { $0.note == session.number }, page: "Page \(session.pageIndex + 1)") { store.openFromRecap(session.id) }
                    .arrives(order)
            }
        }
    }
}

/// One question: what was asked, how it was explained, and the note Halo wrote for it.
@MainActor
struct RecapRow: View {
    let session: StudySession
    let item: RecapItem?
    let page: String
    let open: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 30) { text.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading); note.padding(.top, 6) }
            VStack(alignment: .leading, spacing: 22) { text; note }
        }
        .haloCard(padding: 26)
    }
    private var question: String {
        if let asked = item?.question, !asked.isEmpty { return asked }
        return session.messages.first { $0.role == "user" }?.text ?? session.title
    }
    private var text: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Text("\(session.number)").font(HaloKit.hand(40)).foregroundStyle(HaloStyle.coral).frame(minWidth: 24, alignment: .leading).offset(y: -9)
                VStack(alignment: .leading, spacing: 5) {
                    label("YOU ASKED · \(page.uppercased())")
                    Text(question).font(HaloKit.title(22, .semibold)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let points = item?.points, !points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    label("HOW IT WAS EXPLAINED")
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle().fill(HaloStyle.coral).frame(width: 5, height: 5).offset(y: -3)
                            Text(point).font(HaloKit.text(16.5)).foregroundStyle(HaloStyle.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Button(action: open) { Label("Open on \(page.lowercased())", systemImage: "arrow.up.right").font(HaloKit.text(13, .semibold)) }
                .buttonStyle(.plain).foregroundStyle(HaloStyle.ink).padding(.horizontal, 12).padding(.vertical, 7)
                .background(HaloStyle.ink.opacity(0.07), in: Capsule()).padding(.top, 2)
        }.padding(.leading, 0)
    }
    private var note: some View {
        Button(action: open) { RecapNoteCard(session: session, page: page).rotationEffect(.degrees(session.number % 2 == 0 ? 1.2 : -1.2)).shadow(color: .black.opacity(0.12), radius: 10, y: 6) }
            .buttonStyle(.plain).accessibilityLabel("Halo’s note for question \(session.number)").accessibilityHint("Opens it on its page")
    }
    private func label(_ text: String) -> some View {
        Text(text).font(HaloKit.text(10.5, .bold)).tracking(1.1).foregroundStyle(.secondary)
    }
}

/// A whole note, exactly as Halo wrote it, for reading back.
@MainActor
struct RecapNoteCard: View {
    let session: StudySession
    let page: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(session.number)").font(.custom("Caveat-Regular", size: 24)).foregroundStyle(HaloStyle.coral)
                    .frame(width: 22, height: 24)
                Text(session.topic.isEmpty ? page : "\(session.topic) · \(page)")
                    .font(HaloKit.text(11.5)).foregroundStyle(Color(uiColor: InkPalette.question)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(uiColor: InkPalette.question).opacity(0.55))
            }
            .padding(.leading, 12).padding(.trailing, 12).padding(.top, 8).padding(.bottom, 2)
            NotePaperStatic(session: session)
                .frame(height: max(40, InkLayout.height(of: session) * NoteMetrics.scale))
                .padding(.bottom, 14)
        }
        .frame(width: NoteMetrics.width, alignment: .leading)
        .background(NoteSheet(frosted: false))
        .contentShape(Rectangle())
    }
}
