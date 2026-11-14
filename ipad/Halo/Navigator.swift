import SwiftUI
import PDFKit

// Finding your way around a long document: chapters, every sticky note you've collected
// (grouped by chapter), and search across both the book's text and your notes.

struct Chapter: Identifiable, Equatable {
    struct Section: Identifiable, Equatable { let id: Int; var title: String; var page: Int }
    let id: Int
    var title: String
    var start: Int          // page index, inclusive
    var end: Int            // page index, inclusive
    var sections: [Section] = []
    func contains(_ page: Int) -> Bool { page >= start && page <= end }
}

extension Array where Element == Chapter {
    func containing(_ page: Int) -> Chapter? { last { $0.start <= page } }
    /// The first chapter that is actual content, skipping the cover, copyright, contents, foreword and preface.
    var firstSubstantial: Chapter? {
        let frontMatter = ["cover", "copyright", "contents", "foreword", "preface", "front matter", "title", "dedication", "acknowledg", "about the"]
        return first { chapter in
            let title = chapter.title.lowercased()
            return chapter.end - chapter.start >= 3 && !frontMatter.contains { title.contains($0) }
        }
    }
}

extension Chapter {
    /// Chapters from the PDF's own outline, which real books almost always carry.
    @MainActor
    static func outline(of pdf: PDFDocument) -> [Chapter] {
        guard let root = pdf.outlineRoot, root.numberOfChildren > 0 else { return [] }
        func page(_ item: PDFOutline) -> Int? {
            guard let page = item.destination?.page ?? (item.action as? PDFActionGoTo)?.destination.page else { return nil }
            let index = pdf.index(for: page)
            return index == NSNotFound ? nil : index
        }
        func children(_ item: PDFOutline) -> [PDFOutline] { (0..<item.numberOfChildren).compactMap { item.child(at: $0) } }
        func clean(_ label: String?) -> String {
            (label ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var top = children(root)
        // Some files wrap everything in a single entry named after the book.
        if top.count == 1, top[0].numberOfChildren > 1 { top = children(top[0]) }
        var entries: [(title: String, page: Int, sections: [Section])] = []
        for item in top {
            let title = clean(item.label)
            let kids = children(item)
            // "Part II" is a shelf, not a chapter: its children are the chapters.
            if title.lowercased().hasPrefix("part "), kids.count > 0 {
                for kid in kids {
                    guard let p = page(kid), !clean(kid.label).isEmpty else { continue }
                    entries.append((clean(kid.label), p, sections(of: kid, page: page, clean: clean)))
                }
            } else if let p = page(item), !title.isEmpty {
                entries.append((title, p, sections(of: item, page: page, clean: clean)))
            }
        }
        return assemble(entries.map { ($0.title, $0.page, $0.sections) }, pageCount: pdf.pageCount)
    }
    @MainActor
    private static func sections(of item: PDFOutline, page: (PDFOutline) -> Int?, clean: (String?) -> String) -> [Section] {
        (0..<item.numberOfChildren).compactMap { item.child(at: $0) }.prefix(40).enumerated().compactMap { offset, kid in
            guard let p = page(kid), !clean(kid.label).isEmpty else { return nil }
            return Section(id: offset, title: clean(kid.label), page: p)
        }
    }
    private static func assemble(_ raw: [(String, Int, [Section])], pageCount: Int) -> [Chapter] {
        let sorted = raw.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element)
        guard sorted.count >= 2 else { return [] }
        var chapters: [Chapter] = []
        if let first = sorted.first, first.1 > 0 { chapters.append(Chapter(id: 0, title: "Front matter", start: 0, end: first.1 - 1)) }
        for (index, entry) in sorted.enumerated() {
            let next = index + 1 < sorted.count ? sorted[index + 1].1 : pageCount
            chapters.append(Chapter(id: chapters.count, title: entry.0, start: entry.1, end: max(entry.1, next - 1), sections: entry.2))
        }
        return chapters
    }

    /// No outline: look for pages that open with "Chapter 3", "Lecture 12", "Part II"…
    @MainActor
    static func scan(_ pdf: PDFDocument) async -> [Chapter] {
        guard let pattern = try? NSRegularExpression(pattern: #"^\s*(chapter|part|lecture|unit|module|week|appendix)\s+(\d{1,3}|[ivxlc]{1,6})\b[\s:.\-–—|]*([^\n]{0,60})"#, options: [.caseInsensitive]) else { return [] }
        var found: [(String, Int, [Section])] = []
        var seen = Set<String>()
        for index in 0..<min(pdf.pageCount, 1500) {
            if Task.isCancelled { return [] }
            await Task.yield()
            guard let text = pdf.page(at: index)?.string.map({ String($0.prefix(180)) }) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.firstMatch(in: text, range: range),
                  let kind = Range(match.range(at: 1), in: text), let number = Range(match.range(at: 2), in: text) else { continue }
            // A running header repeats on every page of the chapter; only its first page counts.
            let key = "\(text[kind].lowercased()) \(text[number].lowercased())"
            guard seen.insert(key).inserted else { continue }
            let rest = Range(match.range(at: 3), in: text).map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let head = "\(text[kind].capitalized) \(text[number].uppercased())"
            found.append((rest.count >= 3 ? "\(head): \(rest)" : head, index, []))
        }
        return assemble(found, pageCount: pdf.pageCount)
    }
}

/// Full-text search of the book, streamed in as PDFKit finds matches.
@MainActor
final class BookSearch: ObservableObject {
    struct Hit: Identifiable { let id = UUID(); let page: Int; let snippet: String; let selection: PDFSelection }
    static let limit = 200
    @Published var hits: [Hit] = []
    @Published var searching = false
    private weak var pdf: PDFDocument?
    private var observers: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?

    func search(_ query: String, in pdf: PDFDocument?) {
        stop()
        hits = []
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, let pdf else { return }
        searching = true
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            self?.begin(text, in: pdf)
        }
    }
    func stop() {
        debounce?.cancel(); debounce = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        if let pdf, pdf.isFinding { pdf.cancelFindString() }
        pdf = nil; searching = false
    }
    private func begin(_ text: String, in pdf: PDFDocument) {
        self.pdf = pdf
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFDocumentDidFindMatch, object: pdf, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
                self.found(selection)
            }
        })
        observers.append(center.addObserver(forName: .PDFDocumentDidEndFind, object: pdf, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.searching = false }
        })
        pdf.beginFindString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }
    private func found(_ selection: PDFSelection) {
        guard let pdf, let page = selection.pages.first, hits.count < Self.limit else { return }
        hits.append(Hit(page: pdf.index(for: page), snippet: Self.snippet(around: selection, on: page), selection: selection))
        if hits.count >= Self.limit { pdf.cancelFindString(); searching = false }
    }
    /// The words around a match, starting and ending on whole words ("…the power by one" rather than "he power by one").
    private static func snippet(around selection: PDFSelection, on page: PDFPage) -> String {
        let tidy = { (text: Substring) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard let text = page.string, let match = Range(selection.range(at: 0, on: page), in: text) else {
            return tidy(Substring(selection.string ?? ""))
        }
        var start = text.index(match.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        if start > text.startIndex, let space = text[start..<match.lowerBound].firstIndex(where: \.isWhitespace) { start = text.index(after: space) }
        var end = text.index(match.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        if end < text.endIndex, let space = text[match.upperBound..<end].lastIndex(where: \.isWhitespace) { end = space }
        return (start > text.startIndex ? "…" : "") + tidy(text[start..<end]) + (end < text.endIndex ? "…" : "")
    }
}

enum NavigatorTab: String, CaseIterable, Hashable { case chapters = "Chapters", notes = "Notes" }

@MainActor
struct NavigatorView: View {
    @ObservedObject var store: StudyStore
    @StateObject private var search = BookSearch()
    @State private var expanded: Set<Int> = []
    @FocusState private var searchFocused: Bool
    private var query: String { store.navigatorQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var notes: [StudySession] {
        store.notes.sessions.filter { !$0.messages.isEmpty }.sorted { ($0.pageIndex, $0.number) < ($1.pageIndex, $1.number) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search the book and your notes", text: $store.navigatorQuery)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .focused($searchFocused).accessibilityLabel("Search the book and your notes")
                    if !store.navigatorQuery.isEmpty {
                        Button { store.navigatorQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.black.opacity(0.1)))
                .padding(.horizontal, 16).padding(.vertical, 8)
                List {
                    if query.count >= 2 { results }
                    else if store.navigatorTab == .chapters { chapterList }
                    else { noteList }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .background(DeskPaper())
            .padding(.bottom, 16)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $store.navigatorTab) {
                        Text("Chapters").tag(NavigatorTab.chapters)
                        // "Halo’s answers", not "Notes": your own notes are "My notes" in the top bar.
                        Text(notes.isEmpty ? "Halo’s answers" : "Halo’s answers (\(notes.count))").tag(NavigatorTab.notes)
                    }.pickerStyle(.segmented).frame(width: 240)
                }
            }
        }
        .onChange(of: store.navigatorQuery, initial: true) { _, text in search.search(text, in: store.pdf) }
        .onAppear { if let current = store.currentChapter { expanded.insert(current.id) } }
        .onDisappear { search.stop() }
    }

    // MARK: chapters
    @ViewBuilder private var chapterList: some View {
        Section {
            Button { store.openLesson() } label: {
                Label("Teach me this chapter", systemImage: "graduationcap").font(HaloKit.text(17, .semibold)).foregroundStyle(HaloStyle.ink)
            }
        } footer: { Text("A roadmap from your book, one concept at a time, with questions and room to ask why.") }
        if !store.chapters.isEmpty {
            Section {
                ForEach(store.chapters) { chapter in
                    chapterRow(chapter)
                    if expanded.contains(chapter.id) {
                        ForEach(chapter.sections) { section in
                            Button { go(section.page) } label: {
                                HStack {
                                    Text(section.title).font(HaloKit.text(13)).foregroundStyle(HaloStyle.text).lineLimit(2)
                                    Spacer()
                                    Text("\(section.page + 1)").font(HaloKit.text(12).monospacedDigit()).foregroundStyle(.secondary)
                                }.padding(.leading, 22).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } footer: {
                if store.isBook { Text("tap ✦ on a chapter and Halo reads it first").font(HaloKit.hand(20)).foregroundStyle(HaloStyle.ink) }
            }
        } else if let map = store.notes.map, map.pages.contains(where: { !$0.topic.isEmpty }) {
            // No chapters, but Halo read the document: its page-by-page map does the same job.
            Section("Pages") {
                ForEach(map.pages, id: \.page) { page in
                    Button { go(page.page - 1) } label: {
                        HStack(spacing: 10) {
                            Text("\(page.page)").font(HaloKit.text(12).monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                            Text(page.topic.isEmpty ? "Page \(page.page)" : page.topic.capitalized).font(HaloKit.text(15)).foregroundStyle(HaloStyle.text)
                            Spacer()
                            if page.difficulty >= 3 { Text("tricky").font(HaloKit.hand(19)).foregroundStyle(HaloStyle.coral) }
                            noteBadge(notes.filter { $0.pageIndex == page.page - 1 }.count)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .listRowBackground(page.page - 1 == store.pageIndex ? HaloStyle.ink.opacity(0.07) : nil)
                }
            }
        } else {
            EmptyDesk(title: "No chapters found", note: "this PDF has no outline, but search still works and your notes are listed by page", symbol: "book.closed").listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
    }
    private func chapterRow(_ chapter: Chapter) -> some View {
        let current = store.currentChapter?.id == chapter.id
        let count = notes.filter { chapter.contains($0.pageIndex) }.count
        let read = store.notes.chapterMaps?[chapter.start] != nil
        return HStack(spacing: 8) {
            Button { go(chapter.start) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title).font(HaloKit.text(15).weight(current ? .semibold : .regular)).foregroundStyle(current ? HaloStyle.ink : HaloStyle.text).lineLimit(2)
                        Text(chapter.start == chapter.end ? "Page \(chapter.start + 1)" : "Pages \(chapter.start + 1)–\(chapter.end + 1)").font(HaloKit.text(12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    noteBadge(count)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { store.openLesson(chapter) } label: { Image(systemName: "graduationcap").frame(width: 36, height: 36) }
                .buttonStyle(.borderless).tint(HaloStyle.ink).accessibilityLabel("Teach me \(chapter.title)")
            if store.isBook {
                Button { store.brief(chapter) } label: { Image(systemName: read ? "sparkles" : "sparkle").font(.system(size: 14, weight: .medium)).frame(width: 30, height: 30) }
                    .buttonStyle(.borderless).tint(read ? HaloStyle.coral : .secondary).accessibilityLabel(read ? "Halo’s brief for this chapter" : "Have Halo read this chapter")
            }
            if !chapter.sections.isEmpty {
                Button { if expanded.contains(chapter.id) { expanded.remove(chapter.id) } else { expanded.insert(chapter.id) } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).rotationEffect(.degrees(expanded.contains(chapter.id) ? 90 : 0)).frame(width: 30, height: 30)
                }.buttonStyle(.borderless).tint(.secondary).accessibilityLabel("Sections")
            }
        }
        .listRowBackground(current ? HaloStyle.ink.opacity(0.07) : nil)
    }
    @ViewBuilder private func noteBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)").font(.custom("Caveat-Regular", size: 18)).foregroundStyle(HaloStyle.ink)
                .frame(minWidth: 22, minHeight: 22).background(Color(uiColor: InkPalette.note), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(uiColor: InkPalette.noteEdge)))
                .accessibilityLabel("\(count) notes")
        }
    }

    // MARK: notes
    @ViewBuilder private var noteList: some View {
        if notes.isEmpty {
            EmptyDesk(title: "No notes yet", note: "circle something on a page and ask: Halo’s answers collect here as sticky notes").listRowBackground(Color.clear).listRowSeparator(.hidden)
        } else if store.chapters.isEmpty {
            Section("All notes") { noteRows(notes) }
        } else {
            ForEach(store.chapters) { chapter in
                let mine = notes.filter { chapter.contains($0.pageIndex) }
                if !mine.isEmpty { Section(chapter.title) { noteRows(mine) } }
            }
        }
    }
    private func noteRows(_ sessions: [StudySession]) -> some View {
        ForEach(sessions) { session in
            Button { store.showNavigator = false; store.reopen(session.id) } label: { NoteRow(session: session, chapterless: true) }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) { Button("Delete", role: .destructive) { store.deleteSession(session.id) } }
        }
    }

    // MARK: search
    @ViewBuilder private var results: some View {
        let matching = notes.filter { $0.matches(query) }
        if !matching.isEmpty {
            Section("In your notes") { noteRows(matching) }
        }
        if !search.hits.isEmpty {
            Section("In the book · \(search.hits.count)\(search.hits.count >= BookSearch.limit ? "+" : "") matches") {
                ForEach(search.hits) { hit in
                    Button { store.showNavigator = false; store.jump(to: hit.selection) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.emphasize(query, in: hit.snippet)).font(HaloKit.text(15)).foregroundStyle(HaloStyle.text).lineLimit(2)
                            Text(store.pageLabel(hit.page)).font(HaloKit.text(12)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        if search.searching && search.hits.isEmpty {
            HStack(spacing: 10) { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
        } else if matching.isEmpty && search.hits.isEmpty {
            EmptyDesk(title: "Nothing for “\(query)”", note: "try another word, or part of one", symbol: "magnifyingglass").listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
    }
    private func go(_ page: Int) { store.showNavigator = false; store.jump(to: page) }
    private static func emphasize(_ query: String, in text: String) -> AttributedString {
        var attributed = AttributedString(text)
        if let range = attributed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].font = .subheadline.bold()
            attributed[range].backgroundColor = Color(red: 1, green: 0.84, blue: 0.2).opacity(0.45)
        }
        return attributed
    }
}

/// A note as it appears in a list: its number, the question, and the first line Halo wrote.
@MainActor
struct NoteRow: View {
    let session: StudySession
    var chapterless = false
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(session.number)").font(.custom("Caveat-Regular", size: 23)).foregroundStyle(HaloStyle.ink)
                .frame(width: 32, height: 32).background(Color(uiColor: InkPalette.note), in: NoteShape(fold: 8))
                .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(HaloKit.text(15, .medium)).foregroundStyle(HaloStyle.text).lineLimit(2)
                if let written = session.firstWritten { Text(written).font(.custom("Caveat-Regular", size: 20)).foregroundStyle(HaloStyle.ink).lineLimit(2) }
                Text(caption).font(HaloKit.text(12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 3).contentShape(Rectangle())
    }
    private var caption: String {
        var parts = ["p. \(session.pageIndex + 1)"]
        if !session.topic.isEmpty { parts.append(session.topic) }
        let questions = session.messages.filter { $0.role == "user" }.count
        if questions > 1 { parts.append("\(questions) questions") }
        parts.append(session.createdAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

extension StudySession {
    /// What Halo wrote on the note, as plain text.
    var writtenLines: [String] { messages.flatMap { $0.ink.compactMap { $0.type == "text" ? $0.value : nil } } }
    var firstWritten: String? { writtenLines.prefix(2).joined(separator: "  ·  ").nilIfEmpty }
    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) || topic.localizedCaseInsensitiveContains(query)
            || messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
            || writtenLines.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
