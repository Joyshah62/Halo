import SwiftUI
import PencilKit

// The student's own notes for a document. They type (or Scribble) whatever they like; "Enhance"
// has Halo organize it, fill in what is missing and draw a diagram where one helps. Their own
// words are never overwritten: the enhanced version sits beside them.

@MainActor
struct NotebookView: View {
    @ObservedObject var store: StudyStore
    /// The list of notes can be folded away to give the page the whole width (remembered between visits).
    @AppStorage("halo.notebookList") private var showList = true

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if showList {
                    list.frame(width: 300).transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                Group {
                    if let entry = store.openNote { NotePage(store: store, entry: entry).id(entry.id) }
                    else { EmptyDesk(title: "No note open", note: "start a new note, or pick one from the list", symbol: "square.and.pencil") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DeskPaper().ignoresSafeArea())
            .navigationTitle(store.notebookIsLoose ? "Quick notes" : "My notes").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { withAnimation(.spring(duration: 0.35)) { showList.toggle() } } label: { Image(systemName: "sidebar.left") }
                        .accessibilityLabel(showList ? "Hide the list of notes" : "Show the list of notes")
                    Button { store.newNote() } label: { Label("New note", systemImage: "plus") }.labelStyle(.titleAndIcon)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { store.closeNotebook() }.fontWeight(.semibold) }
            }
        }
        .diveBoard(store)
    }

    private var list: some View {
        // A plain column rather than a List: a List sets its own margins, which on some iPads pushed the
        // header and the cards past the left edge of this fixed-width column.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(store.notebookIsLoose ? "Quick notes" : "Notes for")
                    Text(store.notebookIsLoose ? "not tied to a document" : store.displayTitle).font(HaloKit.hand(22)).foregroundStyle(HaloStyle.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4).padding(.bottom, 4)
                ForEach(store.notebook) { entry in
                    Button { store.selectNote(entry.id) } label: { row(entry) }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Delete note", systemImage: "trash", role: .destructive) { store.deleteNote(entry.id) } }
                }
            }
            .padding(.leading, 16).padding(.trailing, 14).padding(.top, 18).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .clipped()
    }
    private func row(_ entry: NotebookEntry) -> some View {
        let open = entry.id == store.noteID
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(entry.displayTitle).font(HaloKit.title(16, .semibold)).foregroundStyle(HaloStyle.text).lineLimit(1)
                Spacer(minLength: 2)
                if entry.enhanced != nil { Image(systemName: "sparkles").font(HaloKit.text(12)).foregroundStyle(HaloStyle.coral).accessibilityLabel("Enhanced") }
            }
            let body = entry.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            if !body.isEmpty { Text(body).font(HaloKit.text(13)).foregroundStyle(.secondary).lineLimit(2) }
            if entry.drawing != nil { Label(body.isEmpty ? "Handwritten" : "With handwriting", systemImage: "pencil.tip").font(HaloKit.text(12)).foregroundStyle(.secondary) }
            Text(store.notebookIsLoose ? entry.updatedAt.formatted(.relative(presentation: .named)) : "p. \(entry.pageIndex + 1) · \(entry.updatedAt.formatted(.relative(presentation: .named)))")
                .font(HaloKit.hand(17)).foregroundStyle(HaloStyle.ink.opacity(0.75))
        }
        .padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HaloStyle.coral.opacity(open ? 0.9 : 0), lineWidth: 2))
        .shadow(color: .black.opacity(open ? 0.1 : 0.05), radius: open ? 10 : 6, y: 3)
        .contentShape(Rectangle())
    }
}

/// One note: the student's own writing, and Halo's enhanced version of it once they ask for one.
@MainActor
private struct NotePage: View {
    @ObservedObject var store: StudyStore
    let entry: NotebookEntry
    @State private var title: String
    @State private var text: String
    @State private var pen: Bool
    /// Circle mode on the handwriting page: a loop asks Halo about what is inside it.
    @State private var circling = false
    @State private var loop: [CGPoint] = []
    @State private var scroll: CGPoint = .zero      // how far the handwriting page is scrolled
    @State private var openCards: Set<UUID> = []
    @State private var selected = ""

    init(store: StudyStore, entry: NotebookEntry) {
        self.store = store; self.entry = entry
        _title = State(initialValue: entry.title); _text = State(initialValue: entry.text)
        // A note that is only handwriting opens ready for the Pencil.
        _pen = State(initialValue: entry.drawing != nil && entry.text.isEmpty)
    }
    private var busy: Bool { store.enhancingNote == entry.id }
    private var hasText: Bool { entry.drawing != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var stale: Bool { entry.enhanced.map { $0.source != entry.signature } ?? false }
    private var showsEnhanced: Bool { store.noteShowsEnhanced && entry.enhanced != nil }
    private var askingHalo: Bool { if let draft = store.refine, draft.noteID == entry.id, case .enhanced = draft.target { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 34).padding(.top, 22).padding(.bottom, 14)
            if let error = store.noteError {
                Text(error).font(HaloKit.text(13)).foregroundStyle(.red).padding(.horizontal, 34).padding(.bottom, 10)
            }
            if showsEnhanced, let enhanced = entry.enhanced {
                ZStack(alignment: .bottom) {
                    // While Halo's card is up, the notes get room underneath so every part can be scrolled clear of it.
                    ScrollView { EnhancedNoteView(store: store, entry: entry, note: enhanced, stale: stale, circling: $circling).padding(.horizontal, 34).padding(.bottom, askingHalo ? 460 : 60) }
                        .scrollDisabled(circling)
                    if let draft = store.refine, draft.noteID == entry.id, case .enhanced = draft.target {
                        RefineCard(store: store, draft: draft, keepTitle: "Replace", keep: { store.applyEnhancedRefine(below: false) },
                                   addBelow: { store.applyEnhancedRefine(below: true) }, width: 560)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                    .transition(.opacity)
            } else {
                editor.transition(.opacity)
            }
        }
        .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        .onChange(of: title) { _, _ in store.editNote(entry.id, title: title, text: text) }
        .onChange(of: text) { _, _ in store.editNote(entry.id, title: title, text: text) }
        .onDisappear { store.dismissRefine() }
        // A card that was just kept stays open beside its circle.
        .onChange(of: entry.refinements?.last?.id) { old, new in if let new, new != old { openCards.insert(new) } }
        .onChange(of: pen) { _, _ in circling = false; store.dismissRefine() }
        .onChange(of: showsEnhanced) { _, _ in circling = false; store.dismissRefine() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(entry.enhanced?.title ?? "Title", text: $title).font(HaloKit.title(30)).foregroundStyle(HaloStyle.text)
            // One row when there is room; otherwise two (with the notes list open, on a smaller iPad).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { pageLink; Spacer(minLength: 8); writingTools; versionTools }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) { pageLink; Spacer(minLength: 8); writingTools }
                    HStack(spacing: 12) { Spacer(minLength: 0); versionTools }
                }
                // The last choice must always fit: ViewThatFits falls back to it even when it doesn't, and an
                // overflowing row here made the whole screen wider than the iPad (the notes list slid off the left).
                VStack(alignment: .leading, spacing: 10) {
                    pageLink
                    HStack(spacing: 10) { writingTools }
                    FlowRow(spacing: 10) { versionTools }
                }
            }
        }
    }
    @ViewBuilder private var pageLink: some View {
        if !store.notebookIsLoose {
            Button { store.openPage(ofNote: entry.id) } label: { Label(store.pageLabel(entry.pageIndex), systemImage: "arrow.up.right").lineLimit(1) }
                .font(HaloKit.text(13, .semibold)).buttonStyle(.plain).foregroundStyle(HaloStyle.ink).fixedSize()
        }
    }
    @ViewBuilder private var writingTools: some View {
                if !showsEnhanced {
                    Picker("Write with", selection: $pen) {
                        Image(systemName: "keyboard").accessibilityLabel("Type").tag(false)
                        Image(systemName: "pencil.tip").accessibilityLabel("Write by hand").tag(true)
                    }.pickerStyle(.segmented).frame(width: 104)
                }
    }
    @ViewBuilder private var versionTools: some View {
                if showsEnhanced {
                    Button { withAnimation(.spring(duration: 0.3)) { circling.toggle(); if circling { store.dismissRefine() } } } label: {
                        Label("Circle & ask", systemImage: "circle.dashed").font(HaloKit.text(13, .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(circling ? HaloStyle.coral : HaloStyle.coral.opacity(0.1), in: Capsule())
                            .foregroundStyle(circling ? .white : HaloStyle.coral)
                    }.buttonStyle(.plain).fixedSize().accessibilityHint("Circle part of Halo’s notes and ask about it")
                }
                if entry.enhanced != nil {
                    Picker("Version", selection: $store.noteShowsEnhanced) {
                        Text("My notes").tag(false)
                        Text("Enhanced").tag(true)
                    }.pickerStyle(.segmented).frame(width: 220)
                }
                enhanceButton
    }
    private var enhanceButton: some View {
        Button { store.enhanceNote(entry.id) } label: {
            HStack(spacing: 7) {
                if busy { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "sparkles") }
                Text(busy ? "Enhancing…" : entry.enhanced == nil ? "Enhance with AI" : "Enhance again")
            }
            .font(HaloKit.text(14, .semibold)).padding(.horizontal, 14).padding(.vertical, 8)
            .background(HaloStyle.coral.opacity(hasText ? 1 : 0.35), in: Capsule()).foregroundStyle(.white)
        }
        .buttonStyle(.plain).fixedSize().disabled(busy || !hasText)
        .accessibilityHint("Halo organizes your note, adds detail and draws diagrams. Your own words are kept.")
    }
    @ViewBuilder private var editor: some View {
        if pen { paper } else { typed }
    }
    /// A page to write on by hand. It grows as it fills; the typed text is kept alongside it.
    private var paper: some View {
        ZStack(alignment: .topLeading) {
            NoteCanvas(drawing: entry.drawing, changed: { store.drawNote(entry.id, drawing: $0) }, scrolled: { scroll = $0 })
            GeometryReader { geometry in inkLayer(width: geometry.size.width) }
            if entry.drawing == nil {
                Text("Write or sketch with your Pencil. Tap Enhance and Halo reads your handwriting, organizes it, fills in the gaps and adds a diagram where it helps.")
                    .font(HaloKit.text(18)).lineSpacing(5).foregroundStyle(.secondary.opacity(0.7))
                    .padding(.horizontal, 34).padding(.top, 8).allowsHitTesting(false)
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
        .padding(.horizontal, 22).padding(.bottom, 14)
    }
    // MARK: circle and ask (handwriting)
    /// Everything Halo puts on the handwriting page: kept cards, the circle being drawn, and the open question.
    @ViewBuilder private func inkLayer(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(entry.refinements ?? []) { kept in keptCard(kept, width: width) }
            if circling {
                Color.white.opacity(0.001).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { loop.append($0.location) }
                        .onEnded { _ in finishCircle() })
                Text("Circle the part you want Halo to look at").font(HaloKit.text(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(HaloStyle.coral, in: Capsule())
                    .frame(maxWidth: .infinity).padding(.top, 12).allowsHitTesting(false)
                LoopShape(points: loop).stroke(HaloStyle.coral, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)).allowsHitTesting(false)
            }
            if let draft = store.refine, draft.noteID == entry.id, case .ink(let area, let points) = draft.target {
                let shown = area.offsetBy(dx: -scroll.x, dy: -scroll.y)
                if !draft.asked {
                    LoopShape(points: points.map { CGPoint(x: $0.x - scroll.x, y: $0.y - scroll.y) }, closed: true)
                        .stroke(HaloStyle.coral, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)).allowsHitTesting(false)
                        .transition(.opacity)
                }
                RefineCard(store: store, draft: draft, keepTitle: "Keep on my note", keep: { store.keepRefinement() })
                    .offset(place(shown, width: width))
                    .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func finishCircle() {
        defer { loop = [] }
        let xs = loop.map(\.x), ys = loop.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(), maxX - minX > 24, maxY - minY > 18 else { return }
        let onPage = loop.map { CGPoint(x: $0.x + scroll.x, y: $0.y + scroll.y) }
        circling = false
        store.startRefine(.ink(area: CGRect(x: minX + scroll.x, y: minY + scroll.y, width: maxX - minX, height: maxY - minY), loop: onPage), on: entry.id)
    }
    /// Beside the circle when there is room, otherwise under it.
    private func place(_ area: CGRect, width: CGFloat) -> CGSize {
        let card: CGFloat = 330, gap: CGFloat = 16
        if width - area.maxX >= card + gap + 8 { return CGSize(width: area.maxX + gap, height: max(8, area.minY - 6)) }
        if area.minX >= card + gap + 8 { return CGSize(width: area.minX - gap - card, height: max(8, area.minY - 6)) }
        return CGSize(width: min(max(8, area.minX), max(8, width - card - 8)), height: area.maxY + gap)
    }
    /// A refinement the student kept: its circle stays, with a numbered tab that opens Halo's card.
    @ViewBuilder private func keptCard(_ kept: NoteRefinement, width: CGFloat) -> some View {
        let area = CGRect(x: kept.x - scroll.x, y: kept.y - scroll.y, width: kept.width, height: kept.height)
        let number = ((entry.refinements ?? []).firstIndex(of: kept) ?? 0) + 1
        LoopShape(points: kept.loop.map { CGPoint(x: $0.x - scroll.x, y: $0.y - scroll.y) }, closed: true)
            .stroke(HaloStyle.coral.opacity(0.55), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)).allowsHitTesting(false)
        Button { withAnimation(.spring(duration: 0.3)) { if openCards.contains(kept.id) { openCards.remove(kept.id) } else { openCards.insert(kept.id) } } } label: {
            Text("\(number)").font(.custom("Caveat-Regular", size: 20)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(HaloStyle.coral, in: Circle()).shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
        .buttonStyle(.plain).offset(x: area.maxX - 13, y: area.minY - 13)
        .accessibilityLabel(openCards.contains(kept.id) ? "Hide Halo’s note \(number)" : "Show Halo’s note \(number)")
        if openCards.contains(kept.id) {
            RefinementView(title: kept.title, points: kept.points, picture: kept.picture, drawing: false)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 2) {
                        Button { store.removeRefinement(kept.id, from: entry.id) } label: { Image(systemName: "trash").frame(width: 30, height: 30) }.accessibilityLabel("Remove Halo’s note")
                        Button { withAnimation { _ = openCards.remove(kept.id) } } label: { Image(systemName: "chevron.up").frame(width: 30, height: 30) }.accessibilityLabel("Fold away")
                    }.font(HaloKit.text(12, .semibold)).foregroundStyle(.secondary).buttonStyle(.plain).padding(6)
                }
                .padding(16).frame(width: 330, alignment: .leading)
                .background(NoteSheet(frosted: true)).shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                .offset(place(area, width: width))
                .transition(.opacity)
        }
    }

    private var typed: some View {
        ZStack(alignment: .topLeading) {
            SelectableEditor(text: $text, selected: $selected, autofocus: entry.isEmpty, dismissKeyboard: busy)
                .padding(.horizontal, 29)
            if text.isEmpty {
                Text("Write your notes however they come to you: fragments, shorthand, half-finished thoughts. Then tap Enhance and Halo organizes them, fills in the gaps and adds a diagram where it helps.")
                    .font(HaloKit.text(18)).lineSpacing(5).foregroundStyle(.secondary.opacity(0.7))
                    .padding(.horizontal, 34).padding(.top, 8).allowsHitTesting(false)
            }
        }
        .padding(.top, 14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
        .padding(.horizontal, 22).padding(.bottom, 14)
    }
}

/// Halo's version of a note: organized under headings, with what it added marked, and diagrams.
@MainActor
private struct EnhancedNoteView: View {
    @ObservedObject var store: StudyStore
    let entry: NotebookEntry
    let note: EnhancedNote
    let stale: Bool
    @Binding var circling: Bool
    @State private var frames: [NotePointRef: CGRect] = [:]      // where each point sits, for circling
    @State private var headings: [Int: CGRect] = [:]
    @State private var pictures: [Int: CGRect] = [:]
    @State private var loop: [CGPoint] = []
    @State private var missed = false
    private var diagramCount: Int { note.sections.enumerated().filter { $0.element.picture != nil || store.drawingPictures.contains("\(entry.id)#\($0.offset)") }.count }
    private var addedCount: Int { note.sections.reduce(0) { $0 + $1.points.filter(\.added).count } }
    private static let space = "enhanced"
    /// The points being asked about right now, shown highlighted.
    private var asked: Set<NotePointRef> {
        guard let draft = store.refine, draft.noteID == entry.id, case .enhanced(let refs, _, _, _) = draft.target else { return [] }
        return Set(refs)
    }

    var body: some View {
        content
            .coordinateSpace(name: Self.space)
            .overlay(alignment: .topLeading) { GeometryReader { geometry in circleLayer(width: geometry.size.width) } }
    }

    // MARK: circle and ask
    @ViewBuilder private func circleLayer(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if circling {
                Color.white.opacity(0.001).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { loop.append($0.location); missed = false }
                        .onEnded { _ in finishCircle() })
                LoopShape(points: loop).stroke(HaloStyle.coral, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)).allowsHitTesting(false)
            }
            // The circle stays only until the question is asked.
            if let draft = store.refine, draft.noteID == entry.id, !draft.asked, case .enhanced(_, _, _, let points) = draft.target {
                LoopShape(points: points, closed: true)
                    .stroke(HaloStyle.coral, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    /// Works out which points the circle went around: a circled heading or diagram brings its whole section.
    private func finishCircle() {
        defer { loop = [] }
        let xs = loop.map(\.x), ys = loop.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(), maxX - minX > 24, maxY - minY > 14 else { return }
        let area = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        func inside(_ frame: CGRect) -> Bool {
            let overlap = frame.intersection(area)
            return !overlap.isNull && overlap.height >= min(frame.height * 0.4, 18)
        }
        var refs = Set(frames.filter { inside($0.value) }.map(\.key))
        for (section, frame) in headings.merging(pictures, uniquingKeysWith: { a, b in a.union(b) }) where inside(frame) && note.sections.indices.contains(section) {
            refs.formUnion(note.sections[section].points.indices.map { NotePointRef(section: section, point: $0) })
        }
        let ordered = refs.filter { note.sections.indices.contains($0.section) && note.sections[$0.section].points.indices.contains($0.point) }
            .sorted { ($0.section, $0.point) < ($1.section, $1.point) }
        guard !ordered.isEmpty else { withAnimation { missed = true }; return }
        // The text Halo is asked about, under its headings.
        var lines: [String] = [], last = -1
        for ref in ordered {
            if ref.section != last { lines.append(note.sections[ref.section].heading); last = ref.section }
            lines.append("• " + note.sections[ref.section].points[ref.point].text)
        }
        circling = false
        store.startRefine(.enhanced(points: ordered, text: lines.joined(separator: "\n"), area: area, loop: loop), on: entry.id)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            if circling {
                Label(missed ? "That circle didn’t go around any of the notes. Try again." : "Circle the points you want Halo to look at", systemImage: "circle.dashed")
                    .font(HaloKit.text(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(HaloStyle.coral, in: Capsule())
                    .frame(maxWidth: .infinity)
            }
            if stale {
                Label("You’ve changed your notes since Halo wrote this. Tap Enhance again to bring it up to date.", systemImage: "arrow.triangle.2.circlepath")
                    .font(HaloKit.text(13)).foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 12) {
                HaloRing(size: 34, symbol: "sparkles")
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow("Halo’s version of your notes", color: HaloStyle.coral)
                    FlowRow(spacing: 8) {
                        ScribbleChip(text: "\(note.sections.count) section\(note.sections.count == 1 ? "" : "s")", icon: "list.bullet")
                        if addedCount > 0 { ScribbleChip(text: "\(addedCount) added by Halo", icon: "sparkle", tint: HaloStyle.ink) }
                        if let fixes = note.corrections, !fixes.isEmpty { ScribbleChip(text: "\(fixes.count) to look at again", icon: "exclamationmark.circle") }
                        if diagramCount > 0 { ScribbleChip(text: "\(diagramCount) diagram\(diagramCount == 1 ? "" : "s")", icon: "scribble.variable") }
                    }
                }
            }
            if !note.summary.isEmpty {
                Sticky(label: "In short", tilt: -0.4) {
                    Text(note.summary).font(HaloKit.hand(25)).foregroundStyle(HaloStyle.text).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let corrections = note.corrections, !corrections.isEmpty { fixes(corrections) }
            ForEach(Array(note.sections.enumerated()), id: \.offset) { index, section in self.section(section, index) }
            if let terms = note.terms, !terms.isEmpty { glossary(terms) }
            HStack(spacing: 14) {
                if addedCount > 0 {
                    HStack(spacing: 5) { Image(systemName: "sparkle").foregroundStyle(HaloStyle.ink); Text("added by Halo · everything else is yours, tidied up") }
                        .font(HaloKit.text(12)).foregroundStyle(.secondary)
                }
                Spacer()
                ShareLink(item: note.plainText) { Label("Share", systemImage: "square.and.arrow.up") }.font(HaloKit.text(13, .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ section: NoteSection, _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if !section.heading.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)").font(HaloKit.hand(34)).foregroundStyle(HaloStyle.coral)
                    Text(section.heading).font(HaloKit.title(22, .semibold)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
                }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { headings[index] = $0 }
            }
            ForEach(Array(section.points.enumerated()), id: \.offset) { number, point in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Group {
                        if point.added { Image(systemName: "sparkle").font(.system(size: 11, weight: .bold)).foregroundStyle(HaloStyle.coral) }
                        else { Circle().fill(HaloStyle.coral).frame(width: 5, height: 5).offset(y: -3) }
                    }.frame(width: 12)
                    Text(point.text).font(HaloKit.text(16.5)).foregroundStyle(HaloStyle.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(asked.contains(NotePointRef(section: index, point: number)) ? HaloStyle.coral.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[NotePointRef(section: index, point: number)] = $0 }
                .accessibilityElement(children: .combine).accessibilityLabel(point.added ? "Added by Halo: \(point.text)" : point.text)
            }
            if let data = section.picture, let image = UIImage(data: data) {
                Taped(tilt: index % 2 == 0 ? -1.2 : 1.1) {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 440, maxHeight: 300)
                        Text("Halo drew this").font(HaloKit.hand(19)).foregroundStyle(HaloStyle.ink)
                    }
                }
                    .padding(.top, 14).padding(.leading, 22)
                    .accessibilityLabel("Diagram: \(section.image ?? section.heading)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { pictures[index] = $0 }
                    .transition(.opacity)
            } else if store.drawingPictures.contains("\(entry.id)#\(index)") {
                HStack(spacing: 9) { ProgressView().controlSize(.small); Text("Halo is drawing a diagram…").font(HaloKit.text(13)).foregroundStyle(.secondary) }
                    .frame(width: 300, height: 110)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HaloStyle.ink.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .padding(.top, 4).padding(.leading, 22)
            }
        }
        .haloCard()
    }
    private func fixes(_ corrections: [NoteCorrection]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label("WORTH A SECOND LOOK")
            ForEach(Array(corrections.enumerated()), id: \.offset) { _, fix in
                VStack(alignment: .leading, spacing: 3) {
                    Text("You wrote: “\(fix.wrote)”").font(HaloKit.text(14)).foregroundStyle(.secondary).strikethrough(color: HaloStyle.coral.opacity(0.7))
                    Text(fix.correct).font(HaloKit.text(16, .medium)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(HaloStyle.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HaloStyle.coral.opacity(0.35)))
    }
    private func glossary(_ terms: [NoteTerm]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Key terms").padding(.leading, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(Array(terms.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.term).font(HaloKit.hand(26)).foregroundStyle(HaloStyle.ink)
                        Text(item.meaning).font(HaloKit.text(14.5)).foregroundStyle(HaloStyle.text.opacity(0.8)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14).frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
                }
            }
        }
    }
    private func label(_ text: String) -> some View {
        Text(text).font(HaloKit.text(10.5, .bold)).tracking(1.1).foregroundStyle(.secondary)
    }
}

/// The handwriting page: a PencilKit canvas with the system tool palette, taller than the screen
/// and growing as the student writes down it.
@MainActor
private struct NoteCanvas: UIViewRepresentable {
    let drawing: Data?
    let changed: (Data?) -> Void
    var scrolled: (CGPoint) -> Void = { _ in }

    final class Page: PKCanvasView {
        /// Called when the page gets a new width. PencilKit doesn't draw strokes it was given while it had no size.
        var resized: (() -> Void)?
        private var drawnWidth: CGFloat = 0
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.width > 0, bounds.width != drawnWidth {
                drawnWidth = bounds.width
                if !drawing.strokes.isEmpty { DispatchQueue.main.async { [weak self] in self?.resized?() } }
            }
            let written = drawing.strokes.isEmpty ? CGRect.zero : drawing.bounds
            let size = CGSize(width: max(bounds.width, written.maxX + 40), height: max(bounds.height + 1, written.maxY + 600))
            if abs(contentSize.height - size.height) > 1 || contentSize.width != size.width { contentSize = size }
        }
    }
    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var changed: (Data?) -> Void
        var scrolled: (CGPoint) -> Void = { _ in }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { scrolled(scrollView.contentOffset) }
        var shown: Data?
        var loading = false
        let picker = PKToolPicker()
        init(_ changed: @escaping (Data?) -> Void) { self.changed = changed }
        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            guard !loading else { return }
            shown = canvas.drawing.strokes.isEmpty ? nil : canvas.drawing.dataRepresentation()
            changed(shown); canvas.setNeedsLayout()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(changed) }
    func makeUIView(context: Context) -> Page {
        let canvas = Page()
        canvas.backgroundColor = .clear; canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.alwaysBounceVertical = true
        // The Pencil writes and a finger scrolls, unless "draw with finger" is switched on in the palette.
        canvas.drawingPolicy = .default
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.16, green: 0.16, blue: 0.22, alpha: 1), width: 3)
        canvas.delegate = context.coordinator
        load(drawing, into: canvas, context.coordinator)
        canvas.resized = { [weak canvas, coordinator = context.coordinator] in
            guard let canvas else { return }
            coordinator.loading = true
            let strokes = canvas.drawing; canvas.drawing = PKDrawing(); canvas.drawing = strokes
            coordinator.loading = false
        }
        let picker = context.coordinator.picker
        // The page is always white paper, so the palette and its colours stay light even in Dark Mode
        // (otherwise "black" ink is offered as white).
        picker.overrideUserInterfaceStyle = .light
        picker.colorUserInterfaceStyle = .light
        picker.addObserver(canvas); picker.setVisible(true, forFirstResponder: canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }
    func updateUIView(_ canvas: Page, context: Context) {
        context.coordinator.changed = changed
        context.coordinator.scrolled = scrolled
        if drawing != context.coordinator.shown { load(drawing, into: canvas, context.coordinator) }
    }
    static func dismantleUIView(_ canvas: Page, coordinator: Coordinator) {
        coordinator.picker.setVisible(false, forFirstResponder: canvas); coordinator.picker.removeObserver(canvas)
        canvas.resignFirstResponder()
    }
    private func load(_ data: Data?, into canvas: Page, _ coordinator: Coordinator) {
        coordinator.loading = true
        canvas.drawing = data.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        coordinator.shown = data; coordinator.loading = false
        canvas.setNeedsLayout()
    }
}

/// Halo's question card: what to do with the part that was circled or selected, then Halo's refined version.
@MainActor
private struct RefineCard: View {
    @ObservedObject var store: StudyStore
    let draft: RefineDraft
    let keepTitle: String
    let keep: () -> Void
    var addBelow: (() -> Void)?
    var width: CGFloat = 330
    private static let chips = ["Clean it up", "Add detail", "Explain it", "Check it", "Add a diagram"]
    private var ask: Binding<String> { Binding(get: { store.refine?.ask ?? "" }, set: { store.refine?.ask = $0 }) }
    private var looksUp: Bool { if case .ink = draft.target { return false }; return true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().stroke(HaloStyle.coral, lineWidth: 2.5).frame(width: 14, height: 14)
                Text(draft.reply == nil ? "Ask Halo about this part" : (draft.ask.isEmpty ? "Halo’s version" : draft.ask.capitalizedFirst))
                    .font(HaloKit.text(13, .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button { store.dismissRefine() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close")
            }
            if let reply = draft.reply {
                let answer = RefinementView(title: reply.title, points: reply.points, picture: draft.picture, drawing: draft.drawing)
                // A long answer scrolls inside the card, so the buttons below it are always on screen.
                ViewThatFits(in: .vertical) {
                    answer
                    ScrollView { answer.frame(maxWidth: .infinity, alignment: .leading) }
                }
                .frame(maxHeight: 360)
                HStack(spacing: 8) {
                    Button(action: keep) { Text(keepTitle).font(HaloKit.text(14, .semibold)).lineLimit(1).fixedSize().padding(.horizontal, 14).padding(.vertical, 8)
                        .background(HaloStyle.coral, in: Capsule()).foregroundStyle(.white) }.buttonStyle(.plain)
                    if let addBelow { Button("Add below", action: addBelow).font(HaloKit.text(14, .semibold)).foregroundStyle(HaloStyle.ink) }
                    Spacer(minLength: 4)
                    Button { store.retryRefine() } label: { Label("Ask again", systemImage: "arrow.uturn.backward").font(HaloKit.text(13, .semibold)).lineLimit(1).fixedSize() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            } else if draft.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(draft.ask.isEmpty ? "Halo is reading it…" : "\(draft.ask.capitalizedFirst)…").font(HaloKit.text(15)).foregroundStyle(HaloStyle.text).lineLimit(2)
                }.padding(.vertical, 6)
            } else {
                FlowRow(spacing: 7) {
                    ForEach(Self.chips, id: \.self) { chip in
                        Button { store.runRefine(chip.lowercased()) } label: {
                            Text(chip).font(HaloKit.text(13.5, .medium)).padding(.horizontal, 11).padding(.vertical, 6)
                                .background(HaloStyle.ink.opacity(0.07), in: Capsule()).foregroundStyle(HaloStyle.ink)
                        }.buttonStyle(.plain)
                    }
                    // Typed and enhanced notes can be looked up on the web: videos, pictures and sources.
                    if looksUp {
                        Button { store.diveFromRefine() } label: {
                            Label("Look it up", systemImage: "globe").font(HaloKit.text(13.5, .semibold)).padding(.horizontal, 11).padding(.vertical, 6)
                                .background(HaloStyle.coral, in: Capsule()).foregroundStyle(.white)
                        }.buttonStyle(.plain)
                    }
                }
                HaloComposer(text: ask, recording: draft.listening,
                             microphone: { store.listenForRefine() }, send: { store.runRefine() })
            }
            if let error = draft.error { Text(error).font(HaloKit.text(13)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16)
        .frame(maxWidth: width, alignment: .leading)
        .background(NoteSheet(frosted: true))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 7)
    }
}

/// Halo's refined version of a part of the note, in its handwriting.
@MainActor
private struct RefinementView: View {
    let title: String
    let points: [NotePoint]
    let picture: Data?
    let drawing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !title.isEmpty { Text(title).font(HaloKit.title(16, .semibold)).foregroundStyle(HaloStyle.text).padding(.trailing, 60) }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(point.added ? "✦" : "–").font(HaloKit.text(point.added ? 11 : 15, .bold)).foregroundStyle(point.added ? HaloStyle.coral : HaloStyle.ink.opacity(0.6))
                    Text(point.text).font(.custom("Caveat-Regular", size: 23)).foregroundStyle(HaloStyle.ink).lineSpacing(-2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let picture, let image = UIImage(data: picture) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).padding(.top, 4)
            } else if drawing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Halo is drawing a diagram…").font(HaloKit.text(13)).foregroundStyle(.secondary) }.padding(.top, 4)
            }
        }
    }
}

/// The student's circle, as drawn.
private struct LoopShape: Shape {
    let points: [CGPoint]
    var closed = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        return path
    }
}

/// Chips that wrap onto as many lines as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, bounds.width), height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

/// The typed-notes editor. A UIKit text view so it can report what the student has selected on iPadOS 17 too.
@MainActor
private struct SelectableEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selected: String
    var autofocus = false
    var dismissKeyboard = false

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableEditor
        init(_ parent: SelectableEditor) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text; report(view) }
        func textViewDidChangeSelection(_ view: UITextView) { report(view) }
        private func report(_ view: UITextView) {
            let range = view.selectedRange
            let part = range.length > 0 ? (view.text as NSString).substring(with: range) : ""
            if parent.selected != part { parent.selected = part }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.overrideUserInterfaceStyle = .light
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        view.typingAttributes = [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor(HaloStyle.text), .paragraphStyle: paragraph]
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 120, right: 0)
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        set(text, on: view)
        if autofocus { DispatchQueue.main.async { view.becomeFirstResponder() } }
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        // Text changed from outside (Halo replaced the selection): show it, and drop the old selection.
        if view.text != text { set(text, on: view); if !selected.isEmpty { selected = "" } }
        if dismissKeyboard, view.isFirstResponder { view.resignFirstResponder() }
    }
    private func set(_ text: String, on view: UITextView) {
        view.attributedText = NSAttributedString(string: text, attributes: view.typingAttributes)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
