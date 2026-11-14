import SwiftUI
import PDFKit
import PencilKit

enum ReaderTool: String, CaseIterable, Hashable { case circle = "Circle", write = "Write", read = "Read" }

/// A mark on the printed page that goes with one spoken step.
struct PagePointing: Equatable {
    let id = UUID()
    let page: Int
    let regions: [PageRegion]
    let style: String       // highlight | underline | circle
}

/// The store drives the page view through this.
@MainActor
protocol ReaderControlling: AnyObject {
    func refresh()
    func show(_ selection: PDFSelection?)
    /// Scrolls just enough that the active circle is on screen.
    func revealCircle()
}

@MainActor
final class StudyStore: ObservableObject {
    let lesson = LessonCoach()
    @Published var showLesson = false
    // Library
    @Published var documents: [LibraryDocument] = []
    @Published var document: LibraryDocument?
    @Published var pdf: PDFDocument?
    @Published var notes = DocumentNotes()
    @Published var loading = false
    @Published var error: String?
    // Reading
    @Published var tool: ReaderTool = .circle
    @Published var circleWithFinger = false
    @Published var selectedSessionID: UUID?
    @Published var anchorFrame: CGRect?          // the active circle, in reader coordinates
    @Published var pill: PillState = .hidden
    @Published var busy = false
    @Published var noteOffset: CGSize = .zero    // where the student dragged the open note
    // Finding your way around
    @Published var chapters: [Chapter] = []
    @Published var showNavigator = false
    @Published var navigatorTab: NavigatorTab = .chapters
    @Published var navigatorQuery = ""
    // Looking back
    @Published var showRecap = false
    @Published var recapScope: RecapScope = .today
    @Published var recap: SessionRecap?
    @Published var recapLoading = false
    private var recapTask: Task<Void, Never>?
    // The student's own notes
    @Published var showNotebook = false
    @Published var notebookIsLoose = false
    /// Quick notes: the student's own notes that don't belong to any document.
    @Published var looseNotes: [NotebookEntry] = []
    private var looseSaveTask: Task<Void, Never>?
    @Published var noteID: UUID?
    @Published var noteShowsEnhanced = false
    @Published var enhancingNote: UUID?
    @Published var drawingPictures: Set<String> = []     // "<note id>#<section>" for diagrams still on their way
    @Published var noteError: String?
    private var enhanceTask: Task<Void, Never>?
    /// Circle (or select) part of a note and ask Halo to refine it.
    @Published var refine: RefineDraft?
    /// "Go deeper": what Halo found on the web for a question (nil when the board is closed).
    @Published var dive: DeepDive?
    /// The way down: the dives that led to this one (oldest first), and any the student has come back up from.
    @Published var diveBack: [DeepDive] = []
    @Published var diveAhead: [DeepDive] = []
    /// A follow-up being asked out loud on the web board, and what has been heard of it so far.
    @Published var diveListening = false
    @Published var diveHeard = ""
    private var refineTask: Task<Void, Never>?
    private var pendingPictures: [UUID: (loose: Bool, noteID: UUID, section: Int)] = [:]
    // Upload moment
    @Published var welcome: DocumentMap?
    @Published var reading: String?
    // Person
    @Published var learner: LearnerProfile { didSet { persistLearner() } }
    @Published var needsOnboarding: Bool
    // Settings
    @Published var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: "halo.serverURL") } }
    @Published var voiceOut: Bool { didSet { UserDefaults.standard.set(voiceOut, forKey: "halo.voiceOut") } }
    @Published var tutorMode: Bool { didSet { UserDefaults.standard.set(tutorMode, forKey: "halo.tutorMode") } }
    @Published var demoMode = false
    private var scripted = false
    // Halo watches you work
    @Published var watchWork: Bool { didSet { UserDefaults.standard.set(watchWork, forKey: "halo.watchWork") } }
    /// Listen for "Sup Halo" while a document is open. Off until the student switches it on (it keeps the microphone open).
    @Published var wakeWord: Bool {
        didSet {
            UserDefaults.standard.set(wakeWord, forKey: "halo.wakeWord")
            if wakeWord, !oldValue { Task { await speech.requestPermissions(); wake.retry() } }
        }
    }
    /// The working Halo is looking at right now (a small mark shows on the page while it checks).
    @Published var glance: (page: Int, region: PageRegion)?
    /// Printed text Halo is pointing at while it speaks the current step (it fades when the step ends).
    @Published var pointer: PagePointing?
    // Halo, the companion: the avatar that sits by the page, reacts to what happens and takes any request.
    @Published var haloReaction: TutorMood?
    @Published var haloReactionUntil = Date.distantPast
    /// A short line in a bubble by the avatar ("3 in a row!"); it clears itself.
    @Published var haloSays: String?
    @Published var haloAwakeAt = Date()
    @Published var showLauncher = false
    /// The bar beside the avatar (ask field and page tools). Put away until the avatar is tapped.
    @Published var showDock = false
    /// Steps of working Halo has ticked in a row, and a counter that fires confetti.
    @Published var streak = 0
    @Published var confetti = 0
    private var haloSaysTask: Task<Void, Never>?
    /// "Why am I stuck?": the plan the deep agent wrote for itself, and what it is doing right now.
    @Published var agentTodos: [AgentTodo] = []
    @Published var agentStage = ""
    private var pauseTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var checkGeneration = UUID()
    private var lastChecked: [Int: String] = [:]     // per page: the working as it was when last checked
    private var lastFlagged: [Int: String] = [:]     // per page: the line Halo last spoke up about

    let speech = SpeechInput()
    weak var ink: ReaderControlling?
    weak var notePaper: NoteAnimating?
    let player = AnswerPlayer()
    let wake = WakeListener()
    private let client = HaloClient()
    private var repository: DocumentRepository?
    private var answerTask: Task<Void, Never>?
    private var diveTask: Task<Void, Never>?
    private var diveVoice: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var generation = UUID()
    private var openGeneration = UUID()

    var activeSession: StudySession? { notes.sessions.first { $0.id == selectedSessionID } }
    /// Halo's own title for the document once it has read it; the file name until then.
    var displayTitle: String { notes.map?.title ?? document?.name ?? "Halo" }
    var currentChapter: Chapter? { chapters.containing(pageIndex) }
    /// Long documents with chapters are read (and briefed) one chapter at a time.
    var isBook: Bool { (pdf?.pageCount ?? 0) > Self.digestLimit && !chapters.isEmpty }
    static let digestLimit = 80
    /// Halo's map of what the student is looking at: this chapter of a book, or the whole document.
    func map(for page: Int) -> DocumentMap? {
        if let chapter = chapters.containing(page), let map = notes.chapterMaps?[chapter.start] { return map }
        return notes.map
    }
    func insight(for page: Int) -> PageInsight? { map(for: page)?.insight(for: page) }
    func pageLabel(_ page: Int) -> String {
        if let chapter = chapters.containing(page) { return "p. \(page + 1) · \(chapter.title)" }
        return "Page \(page + 1)"
    }
    var pageIndex: Int { notes.pageIndex }
    var draft: String { activeSession?.draft ?? "" }
    func sessions(on page: Int) -> [StudySession] { notes.sessions.filter { $0.pageIndex == page } }

    init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: "halo.serverURL") ?? "http://localhost:8787"
        voiceOut = defaults.object(forKey: "halo.voiceOut") as? Bool ?? true
        tutorMode = defaults.bool(forKey: "halo.tutorMode")
        watchWork = defaults.object(forKey: "halo.watchWork") as? Bool ?? true
        wakeWord = defaults.bool(forKey: "halo.wakeWord")
        learner = (defaults.data(forKey: "halo.learner")).flatMap { try? JSONDecoder().decode(LearnerProfile.self, from: $0) } ?? LearnerProfile()
        needsOnboarding = !defaults.bool(forKey: "halo.onboarded")
        do { repository = try DocumentRepository() } catch { self.error = "Halo couldn’t open its local library: \(error.localizedDescription)" }
        speech.onTranscript = { [weak self] text in self?.heard(text) }
        speech.onStopped = { [weak self] in self?.listeningStopped() }
        speech.onActive = { [weak wake] in wake?.hold("speech", $0) }
        player.onActive = { [weak wake] in wake?.hold("player", $0) }
        wake.onWake = { [weak self] in self?.heardWakeWord($0) }
    }
    /// "Sup Halo" is only listened for on the bare page: not while a conversation, lesson, summary or notebook is open.
    var wakeAllowed: Bool {
        wakeWord && pdf != nil && pill == .hidden && !showLesson && !showRecap && !showNotebook && dive == nil && refine == nil
    }
    /// "Sup Halo" on its own starts a spoken question about this page; anything said after it goes straight to Halo.
    private func heardWakeWord(_ rest: String) {
        guard wakeAllowed else { return }
        haloAwakeAt = Date()
        withAnimation(.spring(duration: 0.3)) { showDock = false; showLauncher = false }
        showNavigator = false
        if rest.isEmpty { askAboutPage(pageIndex) } else { askHalo(rest) }
    }

    func openLesson(_ chapter: Chapter? = nil) {
        guard let pdf else { return }
        cancelAnswer(); speech.stop(); closeDive(); welcome = nil
        showNavigator = false
        let selected = chapter ?? currentChapter ?? Chapter(id: -1, title: displayTitle, start: 0, end: pdf.pageCount - 1)
        if lesson.chapter != selected || lesson.plan == nil {
            lesson.reset()
            lesson.chapter = selected
            lesson.sourceTitle = displayTitle
        }
        showLesson = true
    }
    func beginLesson() {
        guard let pdf, let chapter = lesson.chapter else { return }
        guard !demoMode || document?.name == "A little calculus" else {
            lesson.error = "Offline lessons use the calculus sample. Turn off Offline sample answers in Settings to teach this chapter from your book."
            return
        }
        let pages = (chapter.start...chapter.end).compactMap { index -> DigestPage? in
            guard let text = pdf.page(at: index)?.string else { return nil }
            return DigestPage(page: index + 1, text: String(text.prefix(12000)), image: nil)
        }
        lesson.start(DigestRequest(title: displayTitle, pages: pages, learner: learner, chapter: chapter.title), server: serverURL, demo: demoMode, voice: voiceOut)
    }
    func saveLesson() {
        guard let plan = lesson.plan, !lesson.saved else { return }
        var entry = NotebookEntry(pageIndex: lesson.chapter?.start ?? pageIndex)
        entry.title = "Lesson · \(plan.title)"
        entry.text = lesson.noteText
        modify(false) { list, _ in list.append(entry) }
        lesson.saved = true
    }

    // MARK: - Person
    private func persistLearner() { if let data = try? JSONEncoder().encode(learner) { UserDefaults.standard.set(data, forKey: "halo.learner") } }
    func finishOnboarding(_ profile: LearnerProfile?) {
        if let profile { learner = profile }
        UserDefaults.standard.set(true, forKey: "halo.onboarded"); needsOnboarding = false
        // Ask for the mic now, so the first circle isn't interrupted by a permission dialog.
        Task { await speech.requestPermissions() }
    }
    /// The profile that travels with a request: what they told us, plus what they've been asking about lately.
    private func learnerSnapshot() async -> LearnerProfile {
        var profile = learner
        if let repository { profile.struggles = await repository.recentTopics() }
        return profile
    }

    // MARK: - Library
    func loadLibrary() async {
        guard let repository else { return }
        do { documents = try await repository.library() } catch { self.error = "Couldn’t read your library: \(error.localizedDescription)" }
        if looseNotes.isEmpty, let saved = try? await repository.quickNotes() { looseNotes = saved }
    }
    func open(_ item: LibraryDocument) async {
        guard let repository else { return }
        let token = UUID(); openGeneration = token
        lesson.reset(); showLesson = false
        cancelAnswer(); speech.stop(); readTask?.cancel(); stopWatching(); await flush()
        if !notebookIsLoose { enhanceTask?.cancel(); enhancingNote = nil; drawingPictures = []; noteID = nil; showNotebook = false }
        loading = true; welcome = nil; reading = nil
        do {
            let url = await repository.fileURL(for: item.id)
            let saved = try await repository.notes(for: item.id)
            guard openGeneration == token else { return }
            guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { throw HaloError.unreadableDocument }
            document = item; self.pdf = pdf; notes = saved
            notes.pageIndex = min(max(0, saved.pageIndex), pdf.pageCount - 1)
            selectedSessionID = nil; pill = .hidden; anchorFrame = nil; error = nil; noteOffset = .zero
            chapters = Chapter.outline(of: pdf)
            if chapters.isEmpty { findChapters(in: pdf, for: item.id) }
            try await repository.markOpened(item.id)
            guard openGeneration == token else { return }
            await loadLibrary()
            if map(for: notes.pageIndex) == nil { if !notes.welcomed || !isBook { readDocument() } } else if !notes.welcomed { welcome = map(for: notes.pageIndex) }
        } catch { if openGeneration == token { self.error = error.localizedDescription } }
        if openGeneration == token { loading = false }
    }
    /// PDF imports work offline; Office imports need the configured Halo server once.
    @Published var importError: String?
    @Published var openingMessage = "Opening your document…"
    private var importingDocument = false
    func importPDF(_ url: URL) async { await importDocument(url) }
    func importDocument(_ url: URL) async {
        guard let repository, !importingDocument else { return }
        importingDocument = true; loading = true; importError = nil
        openingMessage = "Opening your document…"
        let scoped = url.startAccessingSecurityScopedResource()
        var converted: URL?
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let converted { try? FileManager.default.removeItem(at: converted) }
            importingDocument = false; loading = false; openingMessage = "Opening your document…"
        }
        do {
            let ext = url.pathExtension.lowercased()
            guard ["pdf", "ppt", "pptx", "doc", "docx"].contains(ext) else {
                throw HaloError.importFailed("Choose a PDF, PowerPoint (.ppt or .pptx), or Word (.doc or .docx) document.")
            }
            var source = url
            if ext != "pdf" {
                openingMessage = "Preparing your \(ext.hasPrefix("ppt") ? "slides" : "Word document")…"
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 25 * 1024 * 1024 {
                    throw HaloError.importFailed("Choose a document smaller than 25 MB.")
                }
                let pdf = try await client.convertOffice(Data(contentsOf: url), extension: ext, server: serverURL)
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
                converted = temporary
                try pdf.write(to: temporary, options: .atomic)
                source = temporary
            }
            guard let pdf = PDFDocument(url: source), !pdf.isLocked, pdf.pageCount > 0 else { throw HaloError.unreadableDocument }
            let item = try await repository.importPDF(from: source, name: url.deletingPathExtension().lastPathComponent, pageCount: pdf.pageCount)
            await loadLibrary(); await open(item)
        } catch { importError = error.localizedDescription }
    }
    func openSample() async {
        do {
            let url = try SampleLesson.create()
            demoMode = true
            await importPDF(url)
            try? FileManager.default.removeItem(at: url)
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ item: LibraryDocument) async {
        guard let repository else { return }
        do {
            if document?.id == item.id { recap = nil; cancelAnswer(); speech.stop(); saveTask?.cancel(); readTask?.cancel(); document = nil; pdf = nil; selectedSessionID = nil; notes = DocumentNotes(); pill = .hidden; chapters = []; reading = nil; welcome = nil }
            try await repository.delete(item.id); await loadLibrary()
        } catch { self.error = error.localizedDescription }
    }
    func changePage(_ index: Int) {
        stir()
        guard let pdf, index >= 0, index < pdf.pageCount, index != notes.pageIndex else { return }
        notes.pageIndex = index
        saveLater()
    }

    // MARK: - Finding your way around
    /// PDFs without an outline: look for "Chapter 3" style headings in the background.
    private func findChapters(in pdf: PDFDocument, for id: UUID) {
        guard pdf.pageCount >= 12 else { return }
        Task { [weak self] in
            let found = await Chapter.scan(pdf)
            guard let self, self.document?.id == id, self.chapters.isEmpty else { return }
            self.chapters = found
        }
    }
    func jump(to page: Int) {
        ink?.show(nil)
        changePage(page)
    }
    func jump(to selection: PDFSelection) { ink?.show(selection) }
    func openNavigator(_ tab: NavigatorTab) { navigatorTab = tab; showNavigator = true }
    /// The sparkles button: Halo's brief for where you are, reading the chapter first if it hasn't yet.
    func showBrief() {
        if let map = map(for: pageIndex) { withAnimation(.spring(duration: 0.5)) { welcome = map } } else { readDocument() }
    }
    func brief(_ chapter: Chapter) {
        showNavigator = false
        jump(to: chapter.start)
        if let map = notes.chapterMaps?[chapter.start] { withAnimation(.spring(duration: 0.5)) { welcome = map } } else { readDocument(chapter) }
    }

    // MARK: - Session summary
    /// The notes a summary covers: today's sitting, or everything in this document.
    func recapNotes(_ scope: RecapScope) -> [StudySession] {
        let written = notes.sessions.filter { !$0.messages.isEmpty }.sorted { ($0.pageIndex, $0.number) < ($1.pageIndex, $1.number) }
        return scope == .all ? written : written.filter { Calendar.current.isDateInToday($0.createdAt) }
    }
    func openRecap() {
        dismissPill(); dismissWelcome()
        if recapNotes(.today).isEmpty { recapScope = .all }
        showRecap = true
        makeRecap()
    }
    func closeRecap() { recapTask?.cancel(); recapLoading = false; showRecap = false }
    func openFromRecap(_ id: UUID) { closeRecap(); reopen(id) }
    /// Asks Halo to look back over the notes. Reuses the saved summary when the notes haven't changed.
    func makeRecap() {
        recapTask?.cancel()
        let sessions = recapNotes(recapScope)
        guard !sessions.isEmpty, let document else { recap = nil; recapLoading = false; return }
        let signature = recapScope.rawValue + "|" + sessions.map { "\($0.number):\($0.messages.count)" }.joined(separator: ",")
        if let saved = notes.summary, saved.signature == signature { recap = saved; recapLoading = false; return }
        let local = Self.localRecap(sessions, signature: signature)
        let payload = sessions.map { session in
            RecapNote(n: session.number, page: session.pageIndex + 1, chapter: chapters.containing(session.pageIndex)?.title ?? "", topic: session.topic,
                      questions: session.messages.filter { $0.role == "user" }.map { String($0.text.prefix(300)) },
                      written: session.writtenLines.map { String($0.prefix(120)) },
                      said: String(session.messages.filter { $0.role == "assistant" }.map(\.text).joined(separator: " ").prefix(900)))
        }
        let useDemo = demoMode, server = serverURL, title = displayTitle, documentID = document.id
        recap = nil; recapLoading = true
        recapTask = Task { [weak self] in
            guard let self else { return }
            var result = local
            if useDemo { try? await Task.sleep(for: .seconds(0.9)) }
            else if var remote = try? await client.recap(RecapRequest(title: title, notes: payload, learner: await learnerSnapshot()), server: server) {
                remote.signature = signature; result = remote
            }
            guard !Task.isCancelled, self.document?.id == documentID, showRecap else { return }
            withAnimation(.easeOut(duration: 0.35)) { recap = result; recapLoading = false }
            // Only a summary Halo actually wrote is worth keeping; the offline one is rebuilt for free.
            if result != local { notes.summary = result; saveLater() }
        }
    }
    /// Built on the iPad from the notes themselves: used offline, in demo mode, and if the server can't be reached.
    private static func localRecap(_ sessions: [StudySession], signature: String) -> SessionRecap {
        var topics: [String] = []
        for session in sessions where !session.topic.isEmpty && !topics.contains(session.topic) { topics.append(session.topic) }
        let pages = Set(sessions.map(\.pageIndex)).count
        let items = sessions.map { session -> RecapItem in
            let questions = session.messages.filter { $0.role == "user" }.map(\.text)
            var points = session.writtenLines.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            // A note with only a drawing still deserves a line: fall back to what Halo said.
            if points.isEmpty, let said = session.messages.first(where: { $0.role == "assistant" })?.text { points = [said] }
            return RecapItem(note: session.number, question: questions.joined(separator: " Then: "), points: Array(points.prefix(5)))
        }
        return SessionRecap(headline: topics.isEmpty ? "\(sessions.count) question\(sessions.count == 1 ? "" : "s") from \(pages) page\(pages == 1 ? "" : "s")" : topics.prefix(3).map(\.capitalized).joined(separator: ", "),
                            overview: "", items: items, signature: signature)
    }

    // MARK: - The student's own notes
    /// Notes either belong to the open document, or are free-standing ("quick notes", no PDF needed).
    var notebook: [NotebookEntry] { (entries(notebookIsLoose) ?? []).sorted { $0.updatedAt > $1.updatedAt } }
    var openNote: NotebookEntry? { entries(notebookIsLoose)?.first { $0.id == noteID } }
    private func entries(_ loose: Bool) -> [NotebookEntry]? { loose ? looseNotes : notes.notebook }
    /// Changes one notebook and saves it. Returns false when the note is gone.
    @discardableResult
    private func modify(_ loose: Bool, _ id: UUID? = nil, _ body: (inout [NotebookEntry], Int?) -> Void) -> Bool {
        var list = entries(loose) ?? []
        let index = id.flatMap { id in list.firstIndex { $0.id == id } }
        if id != nil && index == nil { return false }
        body(&list, index)
        if loose { looseNotes = list; saveLooseLater() } else { notes.notebook = list; saveLater() }
        return true
    }
    /// The notebook for the open document.
    func openNotebook() {
        dismissPill(); dismissWelcome()
        notebookIsLoose = false
        if let latest = notebook.first { selectNote(latest.id) } else { newNote() }
        showNotebook = true
    }
    /// Notes without a document: straight from the start screen or the library.
    func openQuickNotes(new: Bool = false) {
        if document != nil { dismissPill(); dismissWelcome() }
        notebookIsLoose = true
        if !new, let latest = notebook.first { selectNote(latest.id) } else { newNote() }
        showNotebook = true
    }
    func closeNotebook() {
        showNotebook = false; noteError = nil
        // A note that never got a word is not worth keeping.
        if entries(notebookIsLoose)?.contains(where: \.isEmpty) == true { modify(notebookIsLoose) { list, _ in list.removeAll(where: \.isEmpty) } }
        noteID = nil
    }
    func newNote() {
        if let blank = entries(notebookIsLoose)?.first(where: \.isEmpty) { selectNote(blank.id); return }
        let entry = NotebookEntry(pageIndex: notebookIsLoose ? 0 : pageIndex)
        modify(notebookIsLoose) { list, _ in list.append(entry) }
        selectNote(entry.id)
    }
    func selectNote(_ id: UUID) {
        noteID = id; noteError = nil
        noteShowsEnhanced = openNote?.enhanced != nil
    }
    func editNote(_ id: UUID, title: String, text: String) {
        guard let entry = entries(notebookIsLoose)?.first(where: { $0.id == id }), entry.title != title || entry.text != text else { return }
        modify(notebookIsLoose, id) { list, i in list[i!].title = title; list[i!].text = text; list[i!].updatedAt = Date() }
    }
    /// The handwriting on a note changed. An emptied canvas is stored as no handwriting at all.
    func drawNote(_ id: UUID, drawing: Data?) {
        guard let entry = entries(notebookIsLoose)?.first(where: { $0.id == id }), entry.drawing != drawing else { return }
        modify(notebookIsLoose, id) { list, i in
            list[i!].drawing = drawing; list[i!].inkVersion = (list[i!].inkVersion ?? 0) + 1; list[i!].updatedAt = Date()
        }
    }
    func deleteNote(_ id: UUID) {
        if enhancingNote == id { enhanceTask?.cancel(); enhancingNote = nil }
        modify(notebookIsLoose) { list, _ in list.removeAll { $0.id == id } }
        if noteID == id { if let next = notebook.first { selectNote(next.id) } else { noteID = nil } }
    }
    func openPage(ofNote id: UUID) {
        guard !notebookIsLoose, let page = notes.notebook?.first(where: { $0.id == id })?.pageIndex else { return }
        closeNotebook(); jump(to: page)
    }
    /// Halo organizes the note, fills in what is missing and draws a diagram where one helps.
    /// The student's own text is never changed; the enhanced version is kept beside it.
    func enhanceNote(_ id: UUID) {
        let loose = notebookIsLoose
        guard enhancingNote == nil, let entry = entries(loose)?.first(where: { $0.id == id }),
              entry.drawing != nil || !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard loose || document != nil else { return }
        // Quick notes have no page behind them, so Halo works from the notes alone.
        let useDemo = demoMode && !loose, server = serverURL
        // What Halo already refined on this note (and the student kept) is part of the notes too.
        var sent = entry
        let kept = (entry.refinements ?? []).flatMap { r in r.points.map { "• \($0.text)" } }
        if !kept.isEmpty { sent.text += "\n\nHalo's refinements of parts of these notes, which the student kept:\n" + kept.joined(separator: "\n") }
        let request = EnhanceRequest(entry: sent, document: loose ? "" : displayTitle, chapter: loose ? "" : chapters.containing(entry.pageIndex)?.title ?? "",
                                     pageText: loose ? "" : pdf?.page(at: entry.pageIndex)?.string ?? "", image: Self.inkImage(entry.drawing))
        noteError = nil; enhancingNote = id
        enhanceTask = Task { [weak self] in
            guard let self else { return }
            do {
                var result: EnhancedNote
                if useDemo { try await Task.sleep(for: .seconds(1.1)); result = Self.localEnhanced(entry) }
                else { var payload = request; payload.learner = await notesLearner(); result = try await client.enhance(payload, server: server) }
                // The note must still be there (a different document may be open by now, whose notebook won't have it).
                guard !Task.isCancelled, entries(loose)?.contains(where: { $0.id == id }) == true else { enhancingNote = nil; return }
                result.source = entry.signature
                // The writing goes on screen now; the diagrams are drawn into it as each one is ready.
                // (Marked as on their way before the note appears, so its first frame already shows them.)
                let wanted = useDemo ? [] : result.sections.enumerated().filter { !($0.element.image ?? "").isEmpty }
                drawingPictures = Set(wanted.map { "\(id)#\($0.offset)" })
                let enhanced = result
                modify(loose, id) { list, i in list[i!].enhanced = enhanced }
                enhancingNote = nil
                if noteID == id { withAnimation(.easeOut(duration: 0.35)) { self.noteShowsEnhanced = true } }
                await withTaskGroup(of: (Int, Data?).self) { group in
                    for (section, item) in wanted { group.addTask { [client = self.client] in (section, try? await client.noteImage(item.image ?? "", server: server)) } }
                    for await (section, data) in group {
                        self.drawingPictures.remove("\(id)#\(section)")
                        guard let data, let picture = Self.notePicture(data),
                              let current = self.entries(loose)?.first(where: { $0.id == id })?.enhanced,
                              current.source == entry.signature, current.sections.indices.contains(section) else { continue }
                        withAnimation(.easeOut(duration: 0.4)) { self.modify(loose, id) { list, i in list[i!].enhanced?.sections[section].picture = picture } }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                enhancingNote = nil
                noteError = "Halo couldn’t enhance this note: \(error.localizedDescription)"
            }
        }
    }
    /// Who is studying, for notes: without the "recently asked about" topics, which pulled unrelated subjects into notes.
    private func notesLearner() async -> LearnerProfile? {
        var profile = learner; profile.struggles = []
        return profile.isEmpty ? nil : profile
    }
    // MARK: Circle and refine
    func startRefine(_ target: RefineDraft.Target, on noteID: UUID) {
        refineTask?.cancel(); stopRefineListening()
        withAnimation(.spring(duration: 0.3)) { refine = RefineDraft(noteID: noteID, target: target) }
    }
    func dismissRefine() {
        refineTask?.cancel(); stopRefineListening()
        withAnimation(.easeOut(duration: 0.2)) { refine = nil }
    }
    /// Back to the question, to ask for something else about the same part.
    func retryRefine() {
        refineTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { refine?.reply = nil; refine?.picture = nil; refine?.error = nil; refine?.busy = false; refine?.ask = "" }
    }
    func runRefine(_ ask: String? = nil) {
        if let ask { refine?.ask = ask }
        stopRefineListening()
        let loose = notebookIsLoose
        guard let draft = refine, !draft.busy, let entry = entries(loose)?.first(where: { $0.id == draft.noteID }) else { return }
        let server = serverURL, useDemo = demoMode && !loose, id = draft.id, noteID = draft.noteID
        var request = RefineRequest(ask: draft.ask.trimmingCharacters(in: .whitespacesAndNewlines), text: entry.text, title: entry.displayTitle,
                                    document: loose ? "" : displayTitle, pageText: loose ? "" : pdf?.page(at: entry.pageIndex)?.string ?? "")
        switch draft.target {
        case .ink(let area, _):
            request.image = Self.inkImage(entry.drawing, in: area, maxSide: 1400)
            request.overview = Self.inkImage(entry.drawing, maxSide: 900)
        case .text(let selected): request.selected = selected
        case .enhanced(_, let selected, _, _):
            request.selected = selected
            // The whole enhanced note is the context for the part they circled.
            if let enhanced = entry.enhanced { request.text = String(enhanced.plainText.prefix(6000)) }
        }
        guard request.image != nil || !request.selected.isEmpty else { refine?.error = "There’s nothing written inside that circle."; return }
        refine?.busy = true; refine?.error = nil; refine?.reply = nil; refine?.picture = nil
        refineTask = Task { [weak self] in
            guard let self else { return }
            do {
                var payload = request; payload.learner = await notesLearner()
                let reply: RefineReply
                if useDemo { try await Task.sleep(for: .seconds(0.9)); reply = Self.localRefine(request) }
                else { reply = try await client.refine(payload, server: server) }
                guard !Task.isCancelled, refine?.id == id else { return }
                withAnimation(.easeOut(duration: 0.3)) { refine?.busy = false; refine?.reply = reply; refine?.drawing = !useDemo && !reply.image.isEmpty }
                guard !useDemo, !reply.image.isEmpty else { return }
                // The words come first; the diagram is drawn into the card when it arrives (even if the card was kept meanwhile).
                let picture = (try? await client.noteImage(reply.image, server: server)).flatMap { $0.flatMap(Self.notePicture) }
                guard !Task.isCancelled else { return }
                if refine?.id == id { withAnimation(.easeOut(duration: 0.4)) { refine?.drawing = false; refine?.picture = picture } }
                if let picture, let target = pendingPictures.removeValue(forKey: id) {
                    modify(target.loose, target.noteID) { list, i in
                        guard list[i!].enhanced?.sections.indices.contains(target.section) == true else { return }
                        list[i!].enhanced?.sections[target.section].picture = picture
                        list[i!].enhanced?.sections[target.section].image = reply.image
                    }
                }
                if let picture, entries(loose)?.first(where: { $0.id == noteID })?.refinements?.contains(where: { $0.id == id }) == true {
                    modify(loose, noteID) { list, i in
                        if let r = list[i!].refinements?.firstIndex(where: { $0.id == id }) { list[i!].refinements?[r].picture = picture }
                    }
                }
            } catch {
                guard !Task.isCancelled, refine?.id == id else { return }
                refine?.busy = false; refine?.error = "Halo couldn’t do that: \(error.localizedDescription)"
            }
        }
    }
    /// Keeps Halo's card on the handwritten page, beside the circle.
    func keepRefinement() {
        guard let draft = refine, let reply = draft.reply, case .ink(let area, let loop) = draft.target else { return }
        let kept = NoteRefinement(id: draft.id, ask: draft.ask, x: area.minX, y: area.minY, width: area.width, height: area.height,
                                  loop: loop.map { LassoPoint(x: $0.x, y: $0.y) }, title: reply.title, points: reply.points,
                                  image: reply.image.isEmpty ? nil : reply.image, picture: draft.picture)
        modify(notebookIsLoose, draft.noteID) { list, i in list[i!].refinements = (list[i!].refinements ?? []) + [kept]; list[i!].updatedAt = Date() }
        stopRefineListening()
        // The task keeps running if a diagram is still on its way: it lands in the kept card.
        withAnimation(.easeOut(duration: 0.25)) { refine = nil }
    }
    /// Puts Halo's answer into the enhanced note: in place of the circled points, or under them.
    func applyEnhancedRefine(below: Bool) {
        guard let draft = refine, let reply = draft.reply, case .enhanced(let refs, _, _, _) = draft.target, !refs.isEmpty else { return }
        let loose = notebookIsLoose
        let sorted = refs.sorted { ($0.section, $0.point) < ($1.section, $1.point) }
        var pictureSection = below ? sorted.last!.section : sorted[0].section
        modify(loose, draft.noteID) { list, i in
            guard var note = list[i!].enhanced else { return }
            if below {
                let last = sorted.last!
                guard note.sections.indices.contains(last.section) else { return }
                // Halo's answer restates what was circled before adding to it; under the circled points only the new ones go in.
                let added = reply.points.filter(\.added)
                note.sections[last.section].points.insert(contentsOf: added.isEmpty ? reply.points : added, at: min(last.point + 1, note.sections[last.section].points.count))
            } else {
                let first = sorted[0]
                guard note.sections.indices.contains(first.section) else { return }
                for ref in sorted.reversed() where note.sections.indices.contains(ref.section) && note.sections[ref.section].points.indices.contains(ref.point) {
                    note.sections[ref.section].points.remove(at: ref.point)
                }
                note.sections[first.section].points.insert(contentsOf: reply.points, at: min(first.point, note.sections[first.section].points.count))
                // A later section whose every point was circled has been folded into the first one.
                for index in note.sections.indices.reversed() where index > first.section && note.sections[index].points.isEmpty && note.sections[index].picture == nil {
                    note.sections.remove(at: index)
                }
                pictureSection = first.section
            }
            if let picture = draft.picture, note.sections.indices.contains(pictureSection) {
                note.sections[pictureSection].picture = picture; note.sections[pictureSection].image = reply.image
            }
            list[i!].enhanced = note
        }
        // A diagram still on its way lands in that section when it arrives.
        if draft.picture == nil, !reply.image.isEmpty { pendingPictures[draft.id] = (loose, draft.noteID, pictureSection) }
        withAnimation(.easeOut(duration: 0.3)) { refine = nil }
    }
    func removeRefinement(_ id: UUID, from noteID: UUID) {
        modify(notebookIsLoose, noteID) { list, i in list[i!].refinements?.removeAll { $0.id == id } }
    }
    /// Asking out loud: the mic is borrowed from circle-and-ask on the book, and handed back afterwards.
    func listenForRefine() {
        guard refine != nil else { return }
        if refine?.listening == true { speech.stop(); return }
        player.stop()
        speech.onTranscript = { [weak self] text in self?.refineHeard(text) }
        speech.onStopped = { [weak self] in self?.refineListeningStopped() }
        refine?.listening = true
        Task { [weak self] in
            guard let self else { return }
            do { try await speech.start() } catch { refineListeningStopped() }
        }
    }
    private func refineHeard(_ text: String) {
        guard refine?.listening == true else { return }
        refine?.ask = text
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self, !Task.isCancelled, refine?.listening == true, !(refine?.ask ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return }
            speech.stop()
        }
    }
    private func refineListeningStopped() {
        restoreSpeech()
        let was = refine?.listening == true
        refine?.listening = false
        if was, !(refine?.ask ?? "").trimmingCharacters(in: .whitespaces).isEmpty { runRefine() }
    }
    private func stopRefineListening() {
        guard refine?.listening == true else { return }
        refine?.listening = false; silenceTask?.cancel()
        restoreSpeech(); speech.stop()
    }
    private func restoreSpeech() {
        speech.onTranscript = { [weak self] text in self?.heard(text) }
        speech.onStopped = { [weak self] in self?.listeningStopped() }
    }
    /// Demo mode: no server, so the part comes back tidied but not refined.
    private static func localRefine(_ request: RefineRequest) -> RefineReply {
        let lines = request.selected.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let points = lines.isEmpty ? [NotePoint(text: "Demo mode: connect to your Halo server and Halo reads what you circled and refines it.")] : lines.map { NotePoint(text: $0) }
        return RefineReply(title: "Demo", points: points, replacement: request.selected)
    }

    private func saveLooseLater() {
        looseSaveTask?.cancel()
        looseSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation(); await self?.flushLoose() } catch {}
        }
    }
    func flushLoose() async {
        guard let repository else { return }
        do { try await repository.saveQuickNotes(looseNotes) }
        catch { noteError = "Couldn’t save your notes: \(error.localizedDescription)" }
    }
    /// The handwriting as a picture Halo can read: dark ink on white, cropped to what was written.
    private static func inkImage(_ data: Data?, in area: CGRect? = nil, maxSide: CGFloat = 1800) -> String? {
        guard let data, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return nil }
        let box = (area ?? drawing.bounds).insetBy(dx: -24, dy: -24)
        let scale = min(2, maxSide / max(box.width, box.height))
        var ink = UIImage()
        // Rendered as on light paper whatever the system appearance, or dark ink would come out white.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { ink = drawing.image(from: box, scale: scale) }
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.8)?.base64EncodedString()
    }
    /// Diagrams are saved with the notes, so they are kept small.
    private static func notePicture(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, 900 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.82)
    }
    /// Demo mode has no server: paragraphs become sections and lines become points, nothing is added.
    private static func localEnhanced(_ entry: NotebookEntry) -> EnhancedNote {
        let blocks = entry.text.components(separatedBy: "\n\n").map { block in
            block.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•*· \t")) }.filter { !$0.isEmpty }
        }.filter { !$0.isEmpty }
        let sections = blocks.enumerated().map { index, lines -> NoteSection in
            let headed = lines.count > 1 && lines[0].count <= 40
            let heading = headed ? lines[0].trimmingCharacters(in: CharacterSet(charactersIn: ":")) : blocks.count > 1 ? "Part \(index + 1)" : "Notes"
            return NoteSection(heading: heading, points: (headed ? Array(lines.dropFirst()) : lines).map { NotePoint(text: $0) })
        }
        let shown = sections.isEmpty ? [NoteSection(heading: "Handwritten notes", points: [NotePoint(text: "Halo reads handwriting on your Halo server. Connect to it and tap Enhance again.")])] : sections
        return EnhancedNote(title: entry.displayTitle, summary: "Demo mode: connect to your Halo server and Halo reads your handwriting, fills in detail and draws diagrams.", sections: shown)
    }

    // MARK: - The upload moment
    /// Reads the document (or, for a book, the chapter you are in), asks the server for Halo's map of it, and greets the student.
    func readDocument(_ requested: Chapter? = nil) {
        guard let pdf, let document else { return }
        readTask?.cancel()
        let documentID = document.id, useDemo = demoMode, server = serverURL, name = document.name
        // A freshly imported book opens on its cover; the first thing worth reading is the first real chapter.
        let chapter = isBook ? (requested ?? (pageIndex == 0 ? chapters.firstSubstantial : nil) ?? currentChapter) : nil
        let first = chapter?.start ?? 0
        let last = min((chapter?.end ?? pdf.pageCount - 1), first + Self.digestLimit - 1, pdf.pageCount - 1)
        readTask = Task { [weak self] in
            guard let self else { return }
            var pages: [DigestPage] = []
            var thumbnails = 0
            for index in first...max(first, last) {
                guard !Task.isCancelled, let page = pdf.page(at: index) else { return }
                reading = chapter == nil ? "Reading page \(index + 1) of \(pdf.pageCount)…" : "Reading “\(chapter!.title)”… page \(index + 1)"
                let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var image: String?
                if text.count < 200, thumbnails < 8 {
                    thumbnails += 1
                    image = page.thumbnail(of: CGSize(width: 520, height: 520), for: .cropBox).jpegData(compressionQuality: 0.7)?.base64EncodedString()
                }
                pages.append(DigestPage(page: index + 1, text: String(text.prefix(2500)), image: image))
                await Task.yield()
            }
            reading = "Halo is reading it with you…"
            do {
                let map: DocumentMap
                if useDemo { try? await Task.sleep(for: .seconds(1.2)); map = SampleLesson.map(pageCount: pdf.pageCount) }
                else { map = try await client.digest(DigestRequest(title: name, pages: pages, learner: await learnerSnapshot(), chapter: chapter?.title), server: server) }
                guard !Task.isCancelled, self.document?.id == documentID else { return }
                if let chapter { var maps = notes.chapterMaps ?? [:]; maps[chapter.start] = map; notes.chapterMaps = maps } else { notes.map = map }
                notes.welcomed = true; reading = nil
                withAnimation(.spring(duration: 0.5)) { welcome = map }
                ink?.refresh(); saveLater()
                if voiceOut, let audio = map.audio ?? nil, !audio.isEmpty {
                    try? await player.play(AnswerStep(index: 0, say: map.say, audio: audio))
                } else if voiceOut {
                    try? await player.play(AnswerStep(index: 0, say: map.say, audio: nil))
                }
            } catch {
                guard !Task.isCancelled else { return }
                reading = nil
                // Reading is a bonus, never a blocker: the document stays fully usable.
                notes.welcomed = true; saveLater()
                if requested != nil { self.error = "Halo couldn’t read that chapter: \(error.localizedDescription)" }
            }
        }
    }
    func startFromWelcome(page: Int) {
        player.stop()
        withAnimation(.easeOut(duration: 0.25)) { welcome = nil }
        changePage(page)
    }
    func dismissWelcome() { player.stop(); withAnimation(.easeOut(duration: 0.25)) { welcome = nil } }

    // MARK: - Circles and threads
    /// The student circled something with the Pencil. Either it's a new thread, or they circled
    /// part of an earlier answer and want to go deeper on it.
    func circled(_ lasso: [LassoPoint], region: PageRegion, on page: Int) {
        cancelAnswer(); speech.stop(); dismissWelcome(); discardEmptyNotes()
        changePage(page)
        let session = StudySession(number: (notes.sessions.map(\.number).max() ?? 0) + 1, pageIndex: page, region: region, lasso: lasso)
        notes.sessions.append(session); selectedSessionID = session.id; noteOffset = .zero
        error = nil; saveLater(); ink?.refresh()
        if scripted { pill = .typing } else { startListening() }
    }
    /// A coral mark on a tricky page was tapped, or "ask about this page".
    func askAboutPage(_ page: Int, question: String? = nil) {
        cancelAnswer(); speech.stop(); dismissWelcome(); discardEmptyNotes()
        changePage(page)
        let session = StudySession(number: (notes.sessions.map(\.number).max() ?? 0) + 1, pageIndex: page, region: nil)
        notes.sessions.append(session); selectedSessionID = session.id; noteOffset = .zero; saveLater(); ink?.refresh()
        if let question { setDraft(question); ask() } else if scripted { pill = .typing } else { startListening() }
    }
    func reopen(_ id: UUID) {
        guard let session = notes.sessions.first(where: { $0.id == id }) else { return }
        cancelAnswer(); speech.stop(); dismissWelcome()
        if selectedSessionID != id { discardEmptyNotes(keeping: id); noteOffset = .zero }
        ink?.show(nil)
        notes.pageIndex = session.pageIndex; selectedSessionID = id
        withAnimation(.spring(duration: 0.35)) { pill = session.messages.isEmpty ? .typing : .ready }
        ink?.refresh(); saveLater()
    }
    /// Puts the note away. Its numbered tab stays on the page; a circle that never got a question is erased.
    func dismissPill() {
        cancelAnswer(); speech.stop(); silenceTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { pill = .hidden }
        selectedSessionID = nil; anchorFrame = nil; discardEmptyNotes(); ink?.refresh()
    }
    func deleteSession(_ id: UUID) {
        if selectedSessionID == id { cancelAnswer(); speech.stop(); pill = .hidden; selectedSessionID = nil; anchorFrame = nil }
        notes.sessions.removeAll { $0.id == id }
        saveLater(); ink?.refresh()
    }
    /// A circle that never got a question is just a stray mark; erase it when the student moves on.
    private func discardEmptyNotes(keeping keep: UUID? = nil) {
        let before = notes.sessions.count
        notes.sessions.removeAll { $0.messages.isEmpty && $0.id != keep }
        if notes.sessions.count != before { saveLater() }
    }
    func setDraft(_ value: String) { updateSession { $0.draft = value } }
    func saveDrawing(_ data: Data, page: Int) { stir(); notes.drawings[page] = data; saveLater(); workChanged(on: page) }
    private func updateSession(_ update: (inout StudySession) -> Void) {
        guard let index = notes.sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        update(&notes.sessions[index]); saveLater()
    }

    // MARK: - Voice in (hands-free)
    func toggleListening() {
        if speech.isRecording { speech.stop(); pill = .typing; return }
        startListening()
    }
    func typeInstead() {
        silenceTask?.cancel()
        pill = .typing
        speech.stop()
    }
    func startListening() {
        guard activeSession != nil else { return }
        player.stop(); silenceTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { pill = .listening("") }
        Task { [weak self] in
            guard let self else { return }
            do { try await speech.start() }
            catch { withAnimation { pill = .typing } }
        }
    }
    private func heard(_ text: String) {
        guard case .listening = pill else { return }
        pill = .listening(text); setDraft(text)
        // A pause after speech means the question is finished. No button to press.
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self, !Task.isCancelled, case .listening(let heard) = pill, !heard.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            speech.stop(); ask()
        }
    }
    private func listeningStopped() {
        if case .listening(let heard) = pill {
            if heard.trimmingCharacters(in: .whitespaces).isEmpty { pill = .typing } else if !busy { ask() }
        }
    }

    // MARK: - Ask
    func cancelAnswer() {
        generation = UUID(); answerTask?.cancel(); answerTask = nil; player.stop(); silenceTask?.cancel()
        point(at: [], page: pageIndex)
        if busy { busy = false; if case .speaking = pill { pill = .ready } }
    }
    /// Marks the printed text a step talks about (a "point" ink item), replacing the previous step's mark.
    /// `lines` resolves points at lines of checked working; `near` picks between repeated matches.
    private func point(at items: [InkItem], page: Int, near: PageRegion? = nil, lines: [Int: PageRegion] = [:]) {
        var next: PagePointing?
        if let item = items.first(where: { $0.type == "point" }), let pdfPage = pdf?.page(at: page) {
            let regions = item.line.flatMap { lines[$0] }.map { [$0] } ?? item.quote.map { PagePointer.find($0, on: pdfPage, near: near) } ?? []
            if !regions.isEmpty { next = PagePointing(page: page, regions: regions, style: item.style ?? "highlight") }
        }
        guard next != nil || pointer != nil else { return }
        pointer = next; ink?.refresh()
    }
    func ask() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !question.isEmpty, let session = activeSession, let document, let page = pdf?.page(at: session.pageIndex) else { return }
        speech.stop(); silenceTask?.cancel(); cancelAnswer()
        // "Show me a video", "explain it in detail", "look it up": Halo goes to the web instead of answering from the page.
        if Self.wantsWeb(question) {
            setDraft(""); withAnimation(.easeOut(duration: 0.2)) { pill = .typing }
            let circled = (try? PDFCapture.make(page: page, region: session.region, lasso: session.lasso, drawing: nil))?.selectedText ?? ""
            startDive(question, context: circled.isEmpty ? String((page.string ?? "").prefix(1800)) : "They circled: \(circled)\n\nThe page says: \(String((page.string ?? "").prefix(1400)))")
            return
        }
        let token = generation, sessionID = session.id
        let useDemo = demoMode, shouldSpeak = voiceOut, hintsOnly = tutorMode, server = serverURL
        error = nil; busy = true
        withAnimation(.easeOut(duration: 0.2)) { pill = .thinking(question) }
        updateSession {
            if $0.conversation.isEmpty { $0.title = String(question.prefix(70)) }
            $0.messages.append(StudyMessage(role: "user", text: question, isDemo: useDemo)); $0.draft = ""
        }
        answerTask = Task { [weak self] in
            guard let self else { return }
            var answer: [String] = [], parentID: Int?, didFinish = false
            do {
                let capture = try PDFCapture.make(page: page, region: session.region, lasso: session.lasso, drawing: notes.drawings[session.pageIndex])
                let payload = AskRequest(question: question, session: session, image: capture.crop, contextImage: capture.page,
                                         selectedText: capture.selectedText, pageText: page.string ?? "", title: document.name, documentID: document.id,
                                         tutorMode: hintsOnly, learner: await learnerSnapshot())
                let events = useDemo ? SampleLesson.answers(tutorMode: hintsOnly, followUp: !session.conversation.isEmpty) : client.ask(payload, server: server)
                for try await event in events {
                    try Task.checkCancellation()
                    guard generation == token, selectedSessionID == sessionID else { return }
                    switch event {
                    case .start(let id): parentID = id
                    case .meta(let mode, let topic):
                        updateSession { $0.topic = topic; if $0.messages.filter({ $0.role == "assistant" }).isEmpty { $0.mode = mode } }
                    case .step(let step):
                        answer.append(step.say)
                        updateSession { $0.messages.append(StudyMessage(role: "assistant", text: step.say, ink: step.ink, isDemo: useDemo)) }
                        withAnimation(.easeOut(duration: 0.2)) { pill = .speaking(step.say) }
                        guard let current = activeSession else { return }
                        point(at: step.ink, page: current.pageIndex, near: current.region)
                        let duration = shouldSpeak ? player.duration(of: step) : AnswerPlayer.estimate(step.say)
                        // Voice and ink run together; the step is over when both are.
                        async let drawing: Void = notePaper?.animate(session: current, duration: duration) ?? ()
                        if shouldSpeak {
                            do { try await player.play(step) }
                            catch is CancellationError { throw CancellationError() }
                            catch { /* voice trouble: keep going silently */ }
                        } else { try await Task.sleep(for: .seconds(duration)) }
                        await drawing
                        guard generation == token else { return }
                        try await Task.sleep(for: .milliseconds(200))
                    case .done: didFinish = true
                    case .verdict, .lesson, .agent: break
                    case .failure(let message): throw NSError(domain: "HaloServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                    }
                }
                guard didFinish else { throw HaloError.incompleteStream }
                guard generation == token else { return }
                updateSession {
                    $0.conversation += [ConversationTurn(role: "user", text: question), ConversationTurn(role: "assistant", text: answer.joined(separator: " "))]
                    $0.conversation = Array($0.conversation.suffix(20)); $0.parentID = parentID
                }
                withAnimation(.easeOut(duration: 0.25)) { pill = .ready }
            } catch is CancellationError { return }
            catch {
                guard generation == token else { return }
                withAnimation { pill = .error(error.localizedDescription) }
                updateSession { $0.draft = question }
            }
            guard generation == token else { return }
            pointer = nil; busy = false; ink?.refresh(); await flush()
        }
    }

    // MARK: - Halo watches you work
    /// The student wrote (or erased) something. When they stop for a moment, Halo takes a look.
    private func workChanged(on page: Int) {
        pauseTask?.cancel()
        // A check that is still looking is now out of date; one that is already talking gets to finish.
        if glance != nil { checkGeneration = UUID(); checkTask?.cancel(); glance = nil }
        guard watchWork, !demoMode, tool == .write else { return }
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            // Never talk over an answer or a question in progress.
            while let self, !Task.isCancelled, self.busy || self.speech.isRecording { try? await Task.sleep(for: .milliseconds(500)) }
            guard let self, !Task.isCancelled else { return }
            self.checkWork(on: page)
        }
    }
    private func stopWatching() {
        pauseTask?.cancel(); checkGeneration = UUID(); checkTask?.cancel(); glance = nil
        lastChecked.removeAll(); lastFlagged.removeAll()
    }
    private func checkWork(on page: Int) {
        guard let document, let pdfPage = pdf?.page(at: page), let work = WorkCapture.make(page: pdfPage, drawing: notes.drawings[page]) else { return }
        guard lastChecked[page] != work.signature else { return }
        lastChecked[page] = work.signature
        let token = UUID(); checkGeneration = token
        let server = serverURL, documentID = document.id, name = document.name
        withAnimation(.easeOut(duration: 0.2)) { glance = (page, work.work) }
        ink?.refresh()
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self else { return }
            var verdict: CheckVerdict?, steps: [AnswerStep] = []
            do {
                let payload = CheckRequest(image: work.image, pageText: pdfPage.string ?? "", title: name, documentID: documentID, page: page, learner: await learnerSnapshot())
                for try await event in client.check(payload, server: server) {
                    try Task.checkCancellation()
                    switch event {
                    case .verdict(let value): verdict = value
                    case .step(let step): steps.append(step)
                    case .failure(let message): throw NSError(domain: "HaloServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                    default: break
                    }
                }
            } catch {
                // Watching is a bonus, never a blocker: if the check fails, say nothing and look again after the next line.
                if self.checkGeneration == token { self.lastChecked[page] = nil }
            }
            guard self.checkGeneration == token, !Task.isCancelled, self.document?.id == documentID else { return }
            self.glance = nil; self.ink?.refresh()
            if let verdict { self.apply(verdict, steps: steps, work: work, page: page) }
        }
    }
    private func apply(_ verdict: CheckVerdict, steps: [AnswerStep], work: WorkCapture, page: Int) {
        guard let region = verdict.box.flatMap(work.region) else { return }
        // Where every line Halo read sits on the page, so a hint can point back at one of them.
        let lines = Dictionary((verdict.lines ?? []).compactMap { l in l.box.flatMap(work.region).map { (l.n, $0) } }, uniquingKeysWith: { a, _ in a })
        switch verdict.status {
        case "correct":
            lastFlagged[page] = nil
            // One ✓ per line: checking again after the next line shouldn't stack them up.
            var ticks = notes.ticks ?? [:]
            if !(ticks[page] ?? []).contains(where: { abs($0.y - region.y) < max(0.012, region.height * 0.6) }) {
                ticks[page, default: []].append(region); notes.ticks = ticks; saveLater()
                cheer()
            }
            // They fixed it: the hint has done its job.
            if let open = activeSession, open.origin == "check", open.pageIndex == page, !busy { dismissPill() }
            ink?.refresh()
        case "wrong":
            let line = verdict.text(ofLine: verdict.line)
            // Say it once. If they carry on without fixing it, don't nag after every line.
            guard !steps.isEmpty, lastFlagged[page] != line else { return }
            // A question of their own comes first.
            if !busy, !speech.isRecording, pill == .hidden || activeSession?.origin == "check" { flag(region, line: line, verdict: verdict, steps: steps, page: page, lines: lines) }
            else { lastChecked[page] = nil }
        default: break
        }
    }
    /// Circles the line, opens a note beside it and gives the hint out loud, exactly as an answer is given.
    private func flag(_ region: PageRegion, line: String, verdict: CheckVerdict, steps: [AnswerStep], page: Int, lines: [Int: PageRegion] = [:]) {
        let size = pdf?.page(at: page)?.bounds(for: .cropBox).size ?? CGSize(width: 1, height: 1.3)
        guard let ring = WorkCapture.ring(around: region, aspect: Double(size.height / max(1, size.width))) else { return }
        cancelAnswer(); dismissWelcome(); discardEmptyNotes()
        lastFlagged[page] = line
        streak = 0; react(.unsure, seconds: 2)
        var session = StudySession(number: (notes.sessions.map(\.number).max() ?? 0) + 1, pageIndex: page, region: ring.region, lasso: ring.lasso)
        session.origin = "check"; session.mode = "hint"; session.topic = verdict.topic ?? ""; session.check = verdict
        session.title = line.isEmpty ? "A step to check" : "Check: \(line.prefix(60))"
        let asked = line.isEmpty ? "Halo was checking my working" : "Halo was checking my working: \(line)"
        session.messages.append(StudyMessage(role: "user", text: asked))
        notes.sessions.append(session); selectedSessionID = session.id; noteOffset = .zero
        let token = generation, sessionID = session.id, shouldSpeak = voiceOut
        error = nil; busy = true
        withAnimation(.spring(duration: 0.35)) { pill = .speaking("") }
        saveLater(); ink?.refresh()
        answerTask = Task { [weak self] in
            guard let self else { return }
            // Let the circle finish drawing itself, and the note appear, before the pen starts.
            try? await Task.sleep(for: .milliseconds(650))
            var said: [String] = []
            for step in steps {
                guard generation == token, selectedSessionID == sessionID, !Task.isCancelled else { return }
                said.append(step.say)
                updateSession { $0.messages.append(StudyMessage(role: "assistant", text: step.say, ink: step.ink)) }
                withAnimation(.easeOut(duration: 0.2)) { self.pill = .speaking(step.say) }
                guard let current = activeSession else { return }
                point(at: step.ink, page: page, near: region, lines: lines)
                let duration = shouldSpeak ? player.duration(of: step) : AnswerPlayer.estimate(step.say)
                async let drawing: Void = notePaper?.animate(session: current, duration: duration) ?? ()
                if shouldSpeak { try? await player.play(step) } else { try? await Task.sleep(for: .seconds(duration)) }
                await drawing
            }
            guard generation == token, selectedSessionID == sessionID else { return }
            // The mark stays a beat after the voice stops, then fades.
            try? await Task.sleep(for: .milliseconds(700))
            guard generation == token else { return }
            pointer = nil
            // The hint becomes the start of a conversation: "why?" on this note just works.
            updateSession { $0.conversation += [ConversationTurn(role: "user", text: asked), ConversationTurn(role: "assistant", text: said.joined(separator: " "))] }
            withAnimation(.easeOut(duration: 0.25)) { self.pill = .ready }
            busy = false; ink?.refresh(); await flush()
        }
    }

    // MARK: - Halo, the companion
    /// What the avatar is doing, read off what the app is doing.
    var haloCue: TutorCue {
        var cue = TutorCue(reaction: haloReaction, reactionUntil: haloReactionUntil)
        if speech.isRecording { cue.base = .listening }
        else if case .speaking = pill { cue.speakingUntil = .distantFuture }
        else if busy || reading != nil || loading { cue.base = .thinking }
        else if glance != nil || tool == .write { cue.base = .attentive }
        else { cue.sleepAt = haloAwakeAt.addingTimeInterval(75) }
        return cue
    }
    /// The student did something: Halo is awake and watching.
    func stir() { if Date().timeIntervalSince(haloAwakeAt) > 5 { haloAwakeAt = Date() } }
    /// A moment of feeling on the avatar's face, optionally with a few words beside it.
    func react(_ mood: TutorMood, say: String? = nil, seconds: Double = 2.4) {
        haloAwakeAt = Date(); haloReaction = mood; haloReactionUntil = Date().addingTimeInterval(seconds)
        guard let say else { return }
        haloSaysTask?.cancel()
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { haloSays = say }
        haloSaysTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(seconds, 3.2)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.haloSays = nil }
        }
    }
    /// Tapping the avatar: it wakes up, winks, and offers what it can do.
    func pokeHalo() {
        let asleep = haloCue.mood(at: Date()) == .sleepy
        react(.wink, say: asleep ? "I'm up! What do you need?" : nil, seconds: 1.1)
        // The avatar opens the bar and the menu together, and puts both away again.
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { showDock.toggle(); showLauncher = showDock }
    }
    /// Puts the bar and the menu away, leaving only the avatar.
    func tuckDock() {
        withAnimation(.spring(duration: 0.3)) { showDock = false; showLauncher = false }
    }
    /// A step of working was right: the streak grows, and Halo makes a fuss at 3, 5 and every 5 after.
    private func cheer() {
        streak += 1
        let milestone = streak == 3 || (streak >= 5 && streak % 5 == 0)
        if milestone { confetti += 1 }
        react(.proud, say: milestone ? "\(streak) in a row! You're flying." : streak > 1 ? "\(streak) in a row" : ["Yes!", "That's right", "Nice step"].randomElement(), seconds: milestone ? 3.2 : 2)
    }

    /// Anything typed (or said) to Halo, with or without a circle. Halo works out what was meant:
    /// a place to go, something to open, something to look up, or a question about the page in front of them.
    func askHalo(_ text: String) {
        let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        showLauncher = false
        func matches(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let found = regex.firstMatch(in: asked, range: NSRange(asked.startIndex..., in: asked)) else { return nil }
            return (0..<found.numberOfRanges).map { Range(found.range(at: $0), in: asked).map { String(asked[$0]) } ?? "" }
        }
        guard let pdf else {
            // Nothing open: notes, or the web.
            if matches(#"^(open |start |take |new |write )?(a |my )?(quick )?notes?\b"#) != nil { openQuickNotes(new: true) } else { startDive(asked) }
            return
        }
        if let page = matches(#"^(?:go to|open|jump to|turn to|show me|take me to)?\s*(?:page|p\.?)\s*(\d+)\W*$"#)?[1], let number = Int(page) {
            guard number >= 1, number <= pdf.pageCount else { react(.unsure, say: "This one has \(pdf.pageCount) pages"); return }
            dismissPill(); jump(to: number - 1); react(.happy, say: "Page \(number)")
        } else if matches(#"^(go to (the )?)?next( page)?\W*$"#) != nil {
            dismissPill(); jump(to: min(pageIndex + 1, pdf.pageCount - 1)); react(.happy)
        } else if matches(#"^(go (to (the )?)?)?(previous|last|back)( a| one)?( page)?\W*$"#) != nil {
            dismissPill(); jump(to: max(pageIndex - 1, 0)); react(.happy)
        } else if matches(#"\b(teach me|start (a |the )?lesson|quiz me|test me|walk me through (this|the) chapter)\b"#) != nil {
            dismissPill(); react(.happy, say: "Let's do it"); openLesson()
        } else if matches(#"\b(recap|summar(y|ise|ize) (of )?(my|the|this|our) (session|notes|questions)|what (did|have) (i|we) (ask|cover|learn)\w*)\b"#) != nil {
            dismissPill(); openRecap()
        } else if matches(#"^(open|show|see)( me)? (my )?(notes|notebook)\W*$|^(take|start|write|new) (a )?note\b"#) != nil {
            dismissPill(); openNotebook()
        } else if matches(#"^(show( me)?|open)? ?(the )?(chapters?|contents|table of contents|outline)\W*$"#) != nil {
            dismissPill(); openNavigator(.chapters)
        } else if matches(#"^(what('s| is) (this|the) (chapter|document|book|pdf|lecture) about|brief me|give me (the|an) overview|overview)\W*$"#) != nil {
            dismissPill(); showBrief()
        } else if let query = matches(#"^(?:find|search for|search|look for|where (?:is|are|does it (?:say|mention|talk about)))\s+(.+?)\W*$"#)?[1], !Self.wantsWeb(asked) {
            dismissPill(); navigatorQuery = query; openNavigator(.chapters); react(.happy, say: "Looking for “\(query.prefix(24))”")
        } else {
            // A question. With a note open it is a follow-up there; otherwise it is about this page.
            if activeSession != nil, pill != .hidden { setDraft(asked); ask() } else { askAboutPage(pageIndex, question: asked) }
        }
    }

    // MARK: - Why am I stuck? (deep agent)
    /// Offered on a note Halo opened for a mistake, until it has been answered once.
    var canAskWhyStuck: Bool {
        guard let session = activeSession else { return false }
        return !demoMode && !busy && session.origin == "check" && session.check != nil && session.stuck == nil
    }
    /// The hint said where the mistake is. This asks what is behind it: a deep agent on the server searches the
    /// student's own book for the idea they are missing, and the answer arrives on the same note.
    func whyStuck() {
        guard canAskWhyStuck, let session = activeSession, let verdict = session.check, let pdf else { return }
        speech.stop(); silenceTask?.cancel(); cancelAnswer()
        let question = "Why am I stuck?"
        let token = generation, sessionID = session.id, shouldSpeak = voiceOut, server = serverURL, title = displayTitle
        // The agent searches the chapter the student is in; a short document is searched whole.
        let chapter = isBook ? chapters.containing(session.pageIndex) : nil
        let first = chapter?.start ?? 0, last = min(chapter?.end ?? pdf.pageCount - 1, first + 399, pdf.pageCount - 1)
        let pages = (first...max(first, last)).compactMap { index -> DigestPage? in
            guard let text = pdf.page(at: index)?.string, !text.isEmpty else { return nil }
            return DigestPage(page: index + 1, text: String(text.prefix(6000)), image: nil)
        }
        let hint = session.messages.filter { $0.role == "assistant" }.map(\.text).joined(separator: " ")
        error = nil; busy = true; agentTodos = []; agentStage = ""
        withAnimation(.easeOut(duration: 0.2)) { pill = .thinking(question) }
        updateSession { $0.messages.append(StudyMessage(role: "user", text: question)) }
        answerTask = Task { [weak self] in
            guard let self else { return }
            var answer: [String] = [], didFinish = false
            do {
                let payload = StuckRequest(verdict: verdict, hint: hint, title: title, chapter: chapter?.title, pages: pages, learner: await learnerSnapshot())
                for try await event in client.stuck(payload, server: server) {
                    try Task.checkCancellation()
                    guard generation == token, selectedSessionID == sessionID else { return }
                    switch event {
                    case .agent(.todos(let todos)): withAnimation(.easeOut(duration: 0.2)) { agentTodos = todos }
                    case .agent(.stage(let doing)): withAnimation(.easeOut(duration: 0.15)) { agentStage = doing }
                    case .agent(.diagnosis(let found)): updateSession { $0.stuck = found; if !found.gap.isEmpty { $0.topic = found.gap } }
                    case .step(let step):
                        answer.append(step.say)
                        updateSession { $0.messages.append(StudyMessage(role: "assistant", text: step.say, ink: step.ink)) }
                        withAnimation(.easeOut(duration: 0.2)) { pill = .speaking(step.say) }
                        guard let current = activeSession else { return }
                        // A quote on this page is marked while it is spoken; one on another page waits for "Open page".
                        let target = step.ink.first { $0.type == "point" }?.page.map { $0 - 1 } ?? current.pageIndex
                        if target == current.pageIndex { point(at: step.ink, page: target) }
                        let duration = shouldSpeak ? player.duration(of: step) : AnswerPlayer.estimate(step.say)
                        async let drawing: Void = notePaper?.animate(session: current, duration: duration) ?? ()
                        if shouldSpeak {
                            do { try await player.play(step) }
                            catch is CancellationError { throw CancellationError() }
                            catch { /* voice trouble: keep going silently */ }
                        } else { try await Task.sleep(for: .seconds(duration)) }
                        await drawing
                        guard generation == token else { return }
                        try await Task.sleep(for: .milliseconds(200))
                    case .done: didFinish = true
                    case .failure(let message): throw NSError(domain: "HaloServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                    default: break
                    }
                }
                guard didFinish else { throw HaloError.incompleteStream }
                guard generation == token else { return }
                updateSession {
                    $0.conversation += [ConversationTurn(role: "user", text: question), ConversationTurn(role: "assistant", text: answer.joined(separator: " "))]
                    $0.conversation = Array($0.conversation.suffix(20))
                }
                withAnimation(.easeOut(duration: 0.25)) { pill = .ready }
            } catch is CancellationError { return }
            catch {
                guard generation == token else { return }
                withAnimation { pill = .error(error.localizedDescription) }
            }
            guard generation == token else { return }
            pointer = nil; busy = false; agentTodos = []; agentStage = ""; ink?.refresh(); await flush()
        }
    }
    /// Turns to the page the agent found and highlights the sentence it quoted.
    func openStuckPage() {
        guard let found = activeSession?.stuck, found.page > 0, let pdfPage = pdf?.page(at: found.page - 1) else { return }
        jump(to: found.page - 1)
        let regions = found.quote.isEmpty ? [] : PagePointer.find(found.quote, on: pdfPage, near: nil)
        if !regions.isEmpty { pointer = PagePointing(page: found.page - 1, regions: regions, style: "highlight"); ink?.refresh() }
    }

    // MARK: - Go deeper (the web)
    /// Did the student ask for something only the web has: a video, pictures, sources, or the long version?
    static func wantsWeb(_ question: String) -> Bool {
        question.range(of: #"\b(videos?|youtube|look (it|this|that) up|search (it|this|that|for|the web|online)|google|sources?|references?|in (more |greater )?detail|more detail|go(ing)? deeper|deep dive|(pictures?|photos?|images?) of|show me (a |an |some |the )?(picture|photo|image|real)|from the (web|internet)|online)\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Halo looks the question up: a cited explanation, videos (one of which it watches to find the right moment) and pictures.
    /// `deeper` keeps the dive on show as a step on the way down, so the student can come back up to it.
    func startDive(_ question: String, context: String = "", deeper: Bool = false) {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        stopDiveListening()
        diveTask?.cancel(); diveVoice?.cancel(); diveVoice = nil; player.stop(); speech.stop()
        let fresh = DeepDive(question: asked, context: context)
        let earlier = deeper ? diveBack + [dive?.settled].compactMap { $0 } : []
        withAnimation(.spring(duration: 0.5, bounce: 0.12)) { diveBack = earlier; diveAhead = []; dive = fresh }
        let id = fresh.id, server = serverURL, title = document == nil ? "" : displayTitle
        diveTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = DiveRequest(question: asked, context: context, document: title, learner: await notesLearner())
                let plan = try await client.divePlan(request, server: server)
                guard dive?.id == id else { return }
                withAnimation(.spring(duration: 0.4)) { self.dive?.plan = plan }
                narrate(plan.say, for: id)
                request.topic = plan.title
                let grounded = request
                async let answered: Void = diveAnswer(grounded, id: id, server: server)
                async let watched: Void = diveVideos(plan.video, question: asked, id: id, server: server)
                async let pictured: Void = diveImages(plan, question: asked, id: id, server: server)
                _ = await (answered, watched, pictured)
            } catch {
                guard !Task.isCancelled, dive?.id == id else { return }
                withAnimation { self.dive?.error = "Halo couldn’t reach the web: \(error.localizedDescription)" }
            }
        }
    }
    private func diveAnswer(_ request: DiveRequest, id: UUID, server: String) async {
        do {
            let answer = try await client.diveAnswer(request, server: server)
            guard dive?.id == id else { return }
            withAnimation(.spring(duration: 0.55, bounce: 0.15)) { self.dive?.answer = answer }
            react(.happy, seconds: 1.8)
            if !answer.say.isEmpty { narrate(answer.say, audio: answer.audio, for: id) }
        } catch {
            guard !Task.isCancelled, dive?.id == id else { return }
            withAnimation { self.dive?.error = "Halo couldn’t finish reading: \(error.localizedDescription)" }
        }
    }
    private func diveVideos(_ query: String, question: String, id: UUID, server: String) async {
        let found = (try? await client.diveVideos(query, server: server)) ?? []
        guard dive?.id == id else { return }
        withAnimation(.spring(duration: 0.55, bounce: 0.2)) { self.dive?.videos = found; self.dive?.selected = found.first?.id }
        // Halo watches the best one straight away, so the "skip to the part you need" is ready when they look.
        if let first = found.first { await watchVideo(first, id: id, announce: true) }
    }
    private func diveImages(_ plan: DivePlan, question: String, id: UUID, server: String) async {
        let found = (try? await client.diveImages(wiki: plan.wiki, query: plan.image, question: question, server: server)) ?? []
        guard dive?.id == id else { return }
        withAnimation(.spring(duration: 0.6, bounce: 0.25)) { self.dive?.images = found }
    }
    private func watchVideo(_ video: DiveVideo, id: UUID, announce: Bool = false) async {
        guard let current = dive, current.id == id, !current.watching.contains(video.id), !current.watched.contains(video.id) else { return }
        withAnimation { self.dive?.watching.insert(video.id) }
        let moment = try? await client.diveMoment(video: video, question: current.question, server: serverURL)
        guard dive?.id == id else { return }
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
            self.dive?.watching.remove(video.id); self.dive?.watched.insert(video.id)
            if let moment { self.dive?.moments[video.id] = moment }
        }
        if announce, let moment, dive?.playing == false {
            narrate("I watched \(video.channel.isEmpty ? "the first video" : "the \(video.channel) video") for you. The part you need starts \(Self.spokenTime(moment.start)).", for: id)
        }
    }
    /// "about two minutes in", "right at the start", "at 1 minute 5": how a person would say a time in a video.
    static func spokenTime(_ seconds: Int) -> String {
        if seconds < 20 { return "right at the start" }
        let minutes = seconds / 60, rest = seconds % 60
        if minutes == 0 { return "\(rest) seconds in" }
        let unit = minutes == 1 ? "minute" : "minutes"
        return rest == 0 ? "\(minutes) \(unit) in" : "at \(minutes) \(unit) \(rest)"
    }
    /// Says a line in Halo's voice, after whatever it is already saying.
    private func narrate(_ text: String, audio: String? = nil, for id: UUID) {
        guard voiceOut, !text.isEmpty else { return }
        let earlier = diveVoice, server = serverURL
        diveVoice = Task { [weak self] in
            await earlier?.value
            guard let self, !Task.isCancelled, dive?.id == id, dive?.playing == false else { return }
            var clip = audio
            if clip == nil { clip = try? await client.speak(text, server: server) }
            guard !Task.isCancelled, dive?.id == id, dive?.playing == false else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.dive?.caption = text }
            try? await player.play(AnswerStep(index: 0, say: text, audio: clip))
            if dive?.id == id, dive?.caption == text { withAnimation(.easeOut(duration: 0.3)) { self.dive?.caption = nil } }
        }
    }
    private func hushDive() { diveVoice?.cancel(); diveVoice = nil; player.stop(); dive?.caption = nil }
    func closeDive() {
        stopDiveListening(); diveTask?.cancel(); hushDive()
        withAnimation(.easeInOut(duration: 0.3)) { dive = nil; diveBack = []; diveAhead = [] }
    }
    /// One level further down from the dive on show: a follow-up, a suggestion, or one part of the answer (`about`).
    func diveDeeper(_ question: String, about part: String = "") {
        guard let current = dive else { startDive(question); return }
        var lines = ["This follows an earlier question, “\(current.question)” (about \(current.plan?.title ?? "the same topic"))."]
        if let takeaway = current.answer?.takeaway, !takeaway.isEmpty { lines.append("Halo already told them: \(takeaway)") }
        if !part.isEmpty { lines.append("The part they want to dig into:\n\(String(part.prefix(900)))") }
        startDive(question, context: lines.joined(separator: "\n\n"), deeper: true)
    }
    /// Back up (or down again) to a dive already made on this trip. Nothing is looked up again.
    func revisitDive(_ id: UUID) {
        let all = diveBack + [dive?.settled].compactMap { $0 } + diveAhead
        guard dive?.id != id, let index = all.firstIndex(where: { $0.id == id }) else { return }
        stopDiveListening(); diveTask?.cancel(); hushDive()
        withAnimation(.spring(duration: 0.5, bounce: 0.12)) {
            diveBack = Array(all[..<index]); diveAhead = Array(all[(index + 1)...]); dive = all[index]
        }
    }
    /// Asking the next question out loud: the mic is borrowed from circle-and-ask, and handed back afterwards.
    func listenForDive() {
        guard dive != nil else { return }
        if diveListening { speech.stop(); return }
        hushDive()
        speech.onTranscript = { [weak self] text in self?.diveHeardMore(text) }
        speech.onStopped = { [weak self] in self?.diveListeningStopped() }
        diveHeard = ""
        withAnimation(.spring(duration: 0.3)) { diveListening = true }
        Task { [weak self] in
            guard let self else { return }
            do { try await speech.start() } catch { diveListeningStopped() }
        }
    }
    private func diveHeardMore(_ text: String) {
        guard diveListening else { return }
        diveHeard = text
        // A pause after speech means the question is finished.
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self, !Task.isCancelled, diveListening, !diveHeard.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            speech.stop()
        }
    }
    private func diveListeningStopped() {
        restoreSpeech(); silenceTask?.cancel()
        let was = diveListening, heard = diveHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.spring(duration: 0.3)) { diveListening = false }
        diveHeard = ""
        if was, !heard.isEmpty { diveDeeper(heard) }
    }
    func stopDiveListening() {
        guard diveListening else { return }
        diveListening = false; diveHeard = ""; silenceTask?.cancel()
        restoreSpeech(); speech.stop()
    }
    /// Halo's face on the web board: listening, saying what it found, searching, or pleased with what it brought back.
    var diveCue: TutorCue {
        var cue = TutorCue(base: .attentive, reaction: haloReaction, reactionUntil: haloReactionUntil)
        if diveListening { cue.base = .listening }
        else if dive?.caption != nil { cue.speakingUntil = .distantFuture }
        else if dive?.searching == true, dive?.answer == nil { cue.base = .thinking }
        return cue
    }
    /// Shows another of the videos, and has Halo watch that one too.
    func selectVideo(_ video: DiveVideo) {
        guard let id = dive?.id, dive?.selected != video.id else { return }
        withAnimation(.spring(duration: 0.35)) { dive?.selected = video.id; dive?.playing = false; dive?.playFrom = 0 }
        Task { await watchVideo(video, id: id) }
    }
    func playVideo(from start: Int = 0) {
        hushDive()
        withAnimation(.easeOut(duration: 0.25)) { dive?.playFrom = start; dive?.playing = true }
    }
    /// Keeps what Halo found as a note of the student's own: in this document's notebook, or in quick notes.
    func saveDive() {
        guard let dive, let answer = dive.answer, !dive.saved else { return }
        let loose = showNotebook ? notebookIsLoose : document == nil
        var lines = answer.sections.flatMap { [$0.heading, $0.text, ""] }
        if !answer.takeaway.isEmpty { lines += ["Remember: \(answer.takeaway)", ""] }
        let videos = (dive.videos ?? []).prefix(2).map { video -> String in
            let at = dive.moments[video.id].map { " (the part to watch starts at \($0.clock))" } ?? ""
            return "• \(video.title), \(video.channel)\(at): \(video.link?.absoluteString ?? "")"
        }
        if !videos.isEmpty { lines += ["Watch"] + videos + [""] }
        if !answer.sources.isEmpty { lines += ["Sources"] + answer.sources.enumerated().map { "\($0.offset + 1). \($0.element.title): \($0.element.url)" } }
        var entry = NotebookEntry(pageIndex: loose ? 0 : pageIndex)
        entry.title = dive.plan?.title ?? String(dive.question.prefix(60))
        entry.text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        modify(loose) { list, _ in list.append(entry) }
        withAnimation(.spring(duration: 0.35)) { self.dive?.saved = true }
    }
    /// "Go deeper" on a sticky note: the question they asked there, with what Halo already told them.
    func diveFromSession() {
        guard let session = activeSession else { return }
        let question = session.messages.last(where: { $0.role == "user" })?.text ?? session.title
        let said = session.messages.filter { $0.role == "assistant" }.map(\.text).joined(separator: " ")
        let page = pdf?.page(at: session.pageIndex)?.string ?? ""
        cancelAnswer()
        startDive(question.isEmpty ? "Explain \(session.topic) in detail" : question,
                  context: [session.topic.isEmpty ? "" : "Topic: \(session.topic)", said.isEmpty ? "" : "Halo already told them: \(String(said.prefix(700)))", "The page says: \(String(page.prefix(1200)))"].filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
    /// "Look it up" on the part of a note the student circled or selected.
    func diveFromRefine() {
        guard let draft = refine else { return }
        let part: String
        switch draft.target {
        case .text(let text): part = text
        case .enhanced(_, let text, _, _): part = text
        case .ink: return
        }
        stopRefineListening()
        let ask = draft.ask.trimmingCharacters(in: .whitespacesAndNewlines)
        startDive(ask.isEmpty ? "Explain this in detail" : ask, context: "From their notes\(openNote.map { " (“\($0.displayTitle)”)" } ?? ""):\n\(part)")
    }

    // MARK: - Automation (screenshots, demos, CI)
    /// `--sample | --open /path/to.pdf  [--live] [--page N] [--circle x,y,w,h] [--ask "question"] [--close] [--panel chapters|notes] [--search "text"] [--notebook "line|line" | --notebook-ink "2x = 4|x = 2" [--enhance]]`
    func runLaunchScript() async {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let question = value("--dive") {
            // `--dive "why is the sky blue?" [--dive-play]`: straight to the web board from the start screen.
            scripted = true; startDive(question)
            // `--dive-then "a follow-up|another"`: goes a level deeper each time an answer lands. `--dive-up` then comes back to the first.
            for next in (value("--dive-then") ?? "").split(separator: "|").map(String.init) {
                for _ in 0..<180 where dive?.answer == nil && dive?.error == nil { try? await Task.sleep(for: .seconds(0.5)) }
                try? await Task.sleep(for: .seconds(1)); diveDeeper(next)
            }
            if args.contains("--dive-up"), let first = diveBack.first {
                for _ in 0..<180 where dive?.answer == nil && dive?.error == nil { try? await Task.sleep(for: .seconds(0.5)) }
                try? await Task.sleep(for: .seconds(1)); revisitDive(first.id)
            }
            if args.contains("--dive-play") {
                for _ in 0..<60 where dive?.moments.isEmpty != false && dive?.watched.isEmpty != false { try? await Task.sleep(for: .seconds(0.5)) }
                playVideo(from: dive?.selected.flatMap { dive?.moments[$0]?.start } ?? 0)
            }
            return
        }
        if let text = value("--quick-note") {
            // `--quick-note "line one|line two" [--enhance]`: a note with no document open, from the start screen.
            scripted = true; openQuickNotes(new: true)
            if let id = noteID {
                editNote(id, title: "", text: text.replacingOccurrences(of: "|", with: "\n")); if args.contains("--enhance") { enhanceNote(id) }
                if args.contains("--enhance") { await scriptCircleEnhanced(id) }
                // `--select "part of the text" --refine "add detail"`: asks Halo about a typed selection.
                if let part = value("--select") {
                    try? await Task.sleep(for: .seconds(1)); startRefine(.text(part), on: id)
                    if let ask = value("--refine"), !ask.isEmpty { try? await Task.sleep(for: .seconds(0.6)); runRefine(ask) }
                }
            }
            return
        }
        guard args.contains("--sample") || value("--open") != nil else { return }
        scripted = true
        if let path = value("--open") {
            demoMode = !args.contains("--live")
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if let existing = documents.first(where: { $0.name == name }) { await open(existing) } else { await importPDF(URL(fileURLWithPath: path)) }
        } else { await openSample() }
        if args.contains("--live") { demoMode = false; notes.map = nil; notes.welcomed = false; readDocument() }
        try? await Task.sleep(for: .seconds(args.contains("--live") ? 9 : 2.5))
        if args.contains("--stay") { return }
        if let script = value("--write") {
            // `--write "2x = 7 + 3|2x = 10" --at 0.13,0.30 [--page N]`: writes lines the way a Pencil would, pausing between them.
            if let page = value("--page").flatMap(Int.init) { startFromWelcome(page: page - 1) } else { dismissWelcome() }
            try? await Task.sleep(for: .milliseconds(900))
            tool = .write
            let at = (value("--at") ?? "0.13,0.30").split(separator: ",").compactMap { Double($0) }
            guard at.count == 2, let size = pdf?.page(at: pageIndex)?.bounds(for: .cropBox).size else { return }
            let height = size.height * 0.022
            for (row, line) in script.split(separator: "|").enumerated() {
                let origin = CGPoint(x: size.width * at[0], y: size.height * at[1] + CGFloat(row) * height * 2.1)
                saveDrawing(WorkScript.write(String(line), at: origin, height: height, onto: notes.drawings[pageIndex]), page: pageIndex)
                ink?.refresh()
                try? await Task.sleep(for: .seconds(Double(value("--gap") ?? "") ?? 0.7))
            }
            return
        }
        if value("--tool") == "write" { dismissWelcome(); tool = .write; return }
        if let page = value("--page").flatMap(Int.init) { startFromWelcome(page: page - 1) } else { dismissWelcome() }
        try? await Task.sleep(for: .milliseconds(900))
        if args.contains("--lesson") {
            needsOnboarding = false
            openLesson()
            if args.contains("--silent") { voiceOut = false }
            if !args.contains("--lesson-intro") {
                beginLesson()
                for answer in (value("--lesson-replies") ?? "").split(separator: "|") {
                    while lesson.busy { try? await Task.sleep(for: .milliseconds(100)) }
                    lesson.draft = String(answer); lesson.reply()
                }
                if let phase = value("--lesson-phase"), ["source", "visual", "example"].contains(phase) {
                    while lesson.busy { try? await Task.sleep(for: .milliseconds(100)) }
                    lesson.phase = phase
                    lesson.exampleMoves = Int(value("--lesson-moves") ?? "0") ?? 0
                }
            }
            return
        }
        if let spec = value("--circle") {
            let n = spec.split(separator: ",").compactMap { Double($0) }
            if n.count == 4, let region = PageRegion(x: n[0], y: n[1], width: n[2], height: n[3]) {
                // An ellipse standing in for a Pencil stroke.
                let lasso = (0...40).map { i -> LassoPoint in
                    let a = Double(i) / 40 * 2 * .pi
                    return LassoPoint(x: region.x + region.width / 2 + cos(a) * region.width / 2, y: region.y + region.height / 2 + sin(a) * region.height / 2)
                }
                circled(lasso, region: region, on: pageIndex)
            }
        }
        // `--say "go to page 2"`: anything typed into Halo's bar. `--launcher` opens the avatar's menu. `--cheer N` ticks N steps.
        if args.contains("--launcher") { pokeHalo() }
        if let count = value("--cheer").flatMap(Int.init) { for _ in 0..<count { cheer(); try? await Task.sleep(for: .milliseconds(250)) } }
        if let said = value("--say") { try? await Task.sleep(for: .milliseconds(400)); askHalo(said) }
        if let question = value("--ask") {
            try? await Task.sleep(for: .milliseconds(400))
            if activeSession == nil { askAboutPage(pageIndex) }
            setDraft(question); ask()
            if args.contains("--close") || value("--panel") != nil || value("--search") != nil {
                while busy { try? await Task.sleep(for: .milliseconds(300)) }
                try? await Task.sleep(for: .milliseconds(600))
                dismissPill()
            }
        }
        if let text = value("--notebook") {
            // `--notebook "line one|line two" [--enhance]`: writes a note of your own, and has Halo enhance it.
            dismissPill(); openNotebook(); newNote()
            if let id = noteID { editNote(id, title: "", text: text.replacingOccurrences(of: "|", with: "\n")); if args.contains("--enhance") { enhanceNote(id) } }
        }
        else if let script = value("--notebook-ink") {
            // `--notebook-ink "2x + 3 = 7|2x = 4" [--enhance | --refine "check it"]`: the same, written by hand (digits, x and = + - ( ) only).
            // `--refine` circles every line but the first and asks Halo about them.
            dismissPill(); openNotebook(); newNote()
            if let id = noteID {
                var drawing: Data?
                let lines = script.split(separator: "|")
                for (row, line) in lines.enumerated() { drawing = WorkScript.write(String(line), at: CGPoint(x: 40, y: 40 + CGFloat(row) * 70), height: 34, onto: drawing) }
                drawNote(id, drawing: drawing)
                if args.contains("--enhance") {
                    enhanceNote(id)
                    // `--mine`: back to the student's own page once Halo is done (both version controls showing).
                    if args.contains("--mine") { while enhancingNote != nil { try? await Task.sleep(for: .milliseconds(300)) }; noteShowsEnhanced = false }
                    await scriptCircleEnhanced(id)
                }
                if let ask = value("--refine") {
                    try? await Task.sleep(for: .seconds(1.2))
                    let area = CGRect(x: 26, y: lines.count > 1 ? 96 : 26, width: 300, height: CGFloat(max(1, lines.count - 1)) * 70 + 8)
                    let loop = (0...40).map { i -> CGPoint in
                        let a = Double(i) / 40 * 2 * .pi
                        return CGPoint(x: area.midX + cos(a) * area.width / 2, y: area.midY + sin(a) * area.height / 2)
                    }
                    startRefine(.ink(area: area, loop: loop), on: id)
                    if !ask.isEmpty { try? await Task.sleep(for: .seconds(0.8)); runRefine(ask) }
                    if args.contains("--keep") {
                        while refine?.reply == nil, refine?.error == nil { try? await Task.sleep(for: .milliseconds(300)) }
                        try? await Task.sleep(for: .seconds(1)); keepRefinement()
                    }
                }
            }
        }
        else if args.contains("--recap") { openRecap() }
        else if let query = value("--search") { navigatorQuery = query; openNavigator(.chapters) }
        else if let panel = value("--panel") { openNavigator(panel == "notes" ? .notes : .chapters) }
    }

    /// `--circle-enhanced "add detail" [--apply replace|below]`: circles the first section of the enhanced note and asks.
    private func scriptCircleEnhanced(_ id: UUID) async {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let ask = value("--circle-enhanced") {
            while enhancingNote != nil { try? await Task.sleep(for: .milliseconds(300)) }
            try? await Task.sleep(for: .seconds(1))
            if let section = openNote?.enhanced?.sections.first {
                let refs = section.points.indices.map { NotePointRef(section: 0, point: $0) }
                let text = ([section.heading] + section.points.map { "• \($0.text)" }).joined(separator: "\n")
                let area = CGRect(x: 0, y: 80, width: 560, height: 120)
                let loop = (0...40).map { i -> CGPoint in let a = Double(i) / 40 * 2 * .pi; return CGPoint(x: area.midX + cos(a) * area.width / 2, y: area.midY + sin(a) * area.height / 2) }
                startRefine(.enhanced(points: refs, text: text, area: area, loop: loop), on: id)
                if !ask.isEmpty { try? await Task.sleep(for: .seconds(0.6)); runRefine(ask) }
                if let how = value("--apply") {
                    while refine?.reply == nil, refine?.error == nil { try? await Task.sleep(for: .milliseconds(300)) }
                    try? await Task.sleep(for: .seconds(1.5)); applyEnhancedRefine(below: how == "below")
                }
            }
        }
    }

    // MARK: - Persistence
    private func saveLater() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation(); await self?.flush() } catch {}
        }
    }
    func flush() async {
        guard let repository, let document else { return }
        let snapshot = notes
        do { try await repository.save(snapshot, for: document.id) }
        catch { self.error = "Couldn’t save your notes: \(error.localizedDescription)" }
    }
}

/// Part of a note the student circled (or selected) and is asking Halo about.
struct RefineDraft: Equatable {
    enum Target: Equatable {
        /// Circled handwriting: the area and the circle, in the note page's points.
        case ink(area: CGRect, loop: [CGPoint])
        /// Selected typed text.
        case text(String)
        /// Points of Halo's enhanced note the student circled (with their text), and the circle on that page.
        case enhanced(points: [NotePointRef], text: String, area: CGRect, loop: [CGPoint])
    }
    let id = UUID()
    let noteID: UUID
    let target: Target
    var ask = ""
    var busy = false
    var listening = false
    var reply: RefineReply?
    var picture: Data?
    var drawing = false
    var error: String?
    /// The question has gone to Halo (it is answering, or has answered): the circle has done its job.
    var asked: Bool { busy || reply != nil }
}

/// One point of an enhanced note: which section, and which point in it.
struct NotePointRef: Hashable { let section: Int; let point: Int }

/// What Halo found on the web for one question. Parts are nil until they arrive.
struct DeepDive: Equatable {
    let id = UUID()
    let question: String
    let context: String
    var plan: DivePlan?
    var answer: DiveAnswer?
    var videos: [DiveVideo]?
    var images: [DiveImage]?
    /// The video on show, whether it is playing, and from which second.
    var selected: String?
    var playing = false
    var playFrom = 0
    /// Videos Halo is watching now, has finished watching, and the moment it found in each.
    var watching: Set<String> = []
    var watched: Set<String> = []
    var moments: [String: DiveMoment] = [:]
    /// What Halo is saying out loud right now.
    var caption: String?
    var error: String?
    var saved = false
    var video: DiveVideo? { videos?.first { $0.id == selected } }
    /// This dive as it is kept on the trail: only if Halo got as far as an answer, with nothing still in flight.
    var settled: DeepDive? {
        guard answer != nil else { return nil }
        var kept = self
        kept.videos = videos ?? []; kept.images = images ?? []; kept.watching = []
        kept.playing = false; kept.caption = nil; kept.error = nil
        return kept
    }
    var searching: Bool { error == nil && (plan == nil || answer == nil || videos == nil || images == nil || !watching.isEmpty) }
}
