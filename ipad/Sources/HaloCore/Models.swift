import Foundation
import Security

/// Top-left coordinates relative to the displayed PDF page, independent of zoom.
public struct PageRegion: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init?(x: Double, y: Double, width: Double, height: Double) {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let left = max(0, x), top = max(0, y)
        let right = min(1, x + width), bottom = min(1, y + height)
        guard right > left, bottom > top else { return nil }
        self.x = left; self.y = top; self.width = right - left; self.height = bottom - top
    }

    public static func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, pageWidth: Double, pageHeight: Double) -> PageRegion? {
        guard pageWidth > 0, pageHeight > 0 else { return nil }
        return PageRegion(x: min(fromX, toX) / pageWidth, y: min(fromY, toY) / pageHeight,
                          width: abs(toX - fromX) / pageWidth, height: abs(toY - fromY) / pageHeight)
    }
}

/// A point of the student's freehand circle, normalized to the displayed page (top-left origin).
public struct LassoPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Who is studying. Lives on the iPad; sent with every question so the tutor can adapt.
public struct LearnerProfile: Codable, Equatable, Sendable {
    public var name = ""
    public var course = ""
    public var level = ""
    public var style = ""
    public var goal = ""
    public var struggles: [String] = []
    public init() {}
    public var isEmpty: Bool { name.isEmpty && course.isEmpty && level.isEmpty && style.isEmpty && goal.isEmpty }
}

/// What Halo learned when it read the document on upload.
public struct PageInsight: Codable, Equatable, Sendable {
    public var page: Int
    public var topic: String
    public var difficulty: Int
    public var note: String
    public init(page: Int, topic: String, difficulty: Int, note: String) { self.page = page; self.topic = topic; self.difficulty = difficulty; self.note = note }
}
public struct DocumentMap: Codable, Equatable, Sendable {
    public var title: String
    public var subject: String
    public var say: String
    public var keyIdeas: [String]
    public var startHere: Int
    public var pages: [PageInsight]
    public var audio: String?
    public init(title: String, subject: String, say: String, keyIdeas: [String], startHere: Int, pages: [PageInsight], audio: String? = nil) {
        self.title = title; self.subject = subject; self.say = say; self.keyIdeas = keyIdeas; self.startHere = startHere; self.pages = pages; self.audio = audio
    }
    public func insight(for pageIndex: Int) -> PageInsight? { pages.first { $0.page == pageIndex + 1 } }
}
public struct DigestPage: Encodable, Sendable {
    public var page: Int
    public var text: String
    public var image: String?
    public init(page: Int, text: String, image: String?) { self.page = page; self.text = text; self.image = image }
}
public struct DigestRequest: Encodable, Sendable {
    public var title: String
    public var pages: [DigestPage]
    public var learner: LearnerProfile?
    /// Set when the pages are one chapter of a longer book, so the brief is about that chapter.
    public var chapter: String?
    /// Lessons record what was covered, and plan around it, per device (anonymous; see DeviceID).
    public var learnerId = DeviceID.current
    public init(title: String, pages: [DigestPage], learner: LearnerProfile?, chapter: String? = nil) { self.title = title; self.pages = pages; self.learner = learner; self.chapter = chapter }
}

/// One sticky note, as sent to the server for a session summary.
public struct RecapNote: Encodable, Sendable {
    public var n: Int
    public var page: Int
    public var chapter: String
    public var topic: String
    public var questions: [String]
    public var written: [String]
    public var said: String
    public init(n: Int, page: Int, chapter: String, topic: String, questions: [String], written: [String], said: String) {
        self.n = n; self.page = page; self.chapter = chapter; self.topic = topic; self.questions = questions; self.written = written; self.said = said
    }
}
public struct RecapRequest: Encodable, Sendable {
    public var title: String
    public var notes: [RecapNote]
    public var learner: LearnerProfile?
    public init(title: String, notes: [RecapNote], learner: LearnerProfile?) { self.title = title; self.notes = notes; self.learner = learner }
}
/// One question from the session: what was asked and how it was explained.
public struct RecapItem: Codable, Equatable, Sendable {
    public var note: Int
    public var question: String
    public var points: [String]
    public init(note: Int, question: String, points: [String]) { self.note = note; self.question = question; self.points = points }
}
/// A written summary of a study session: every question asked and how each was explained.
public struct SessionRecap: Codable, Equatable, Sendable {
    public var headline: String
    public var overview: String
    public var items: [RecapItem]
    /// Which notes this was written from (set on the iPad); a different set means it is stale.
    public var signature: String?
    public init(headline: String, overview: String, items: [RecapItem], signature: String? = nil) {
        self.headline = headline; self.overview = overview; self.items = items; self.signature = signature
    }
}

public struct InkLabel: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var text: String
    public init(x: Double, y: Double, text: String) { self.x = x; self.y = y; self.text = text }
}
public struct InkItem: Codable, Equatable, Sendable {
    public var type: String
    public var value: String?
    public var to: String?
    public var target: String?
    public var w: Double?
    public var h: Double?
    public var paths: [String]?
    public var labels: [InkLabel]?
    public var prompt: String?
    public var mime: String?
    public var data: String?
    /// "point": printed text on the page to mark while this step is spoken, or a line of checked working.
    public var quote: String?
    public var line: Int?
    /// "point": "highlight", "underline" or "circle".
    public var style: String?
    /// "point": the 1-based page the quote is on, when it is not the page the note belongs to.
    public var page: Int?
    public init(type: String, value: String? = nil) { self.type = type; self.value = value }
}
public struct AnswerStep: Codable, Equatable, Sendable {
    public var focus: String?
    public var index: Int
    public var say: String
    public var ink: [InkItem]
    public var audio: String?
    public init(index: Int, say: String, ink: [InkItem] = [], audio: String? = nil, focus: String? = nil) {
        self.focus = focus
        self.index = index; self.say = say; self.ink = ink; self.audio = audio
    }
}
public struct ConversationTurn: Codable, Equatable, Sendable {
    public var role: String
    public var text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}
public struct StudyMessage: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var role: String
    public var text: String
    public var ink: [InkItem]
    public var isDemo: Bool
    public init(role: String, text: String, ink: [InkItem] = [], isDemo: Bool = false) { self.role = role; self.text = text; self.ink = ink; self.isDemo = isDemo }
}
public struct StudySession: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var number: Int
    public var pageIndex: Int
    public var region: PageRegion?
    public var lasso: [LassoPoint]?
    public var followUpLassos: [[LassoPoint]] = []
    public var mode = "answer"
    public var title: String
    public var draft = ""
    public var messages: [StudyMessage] = []
    public var conversation: [ConversationTurn] = []
    public var parentID: Int?
    public var topic = ""
    public var createdAt = Date()
    /// "check" when Halo opened this note itself, after spotting a mistake in the student's working.
    public var origin: String?
    /// What the checker read when it opened this note; "Why am I stuck?" starts from it.
    public var check: CheckVerdict?
    /// What the deep agent found behind the mistake, once the student has asked.
    public var stuck: StuckDiagnosis?
    public init(number: Int, pageIndex: Int, region: PageRegion?, lasso: [LassoPoint]? = nil) {
        self.number = number; self.pageIndex = pageIndex; self.region = region; self.lasso = lasso
        self.title = region == nil ? "Whole-page question" : "New section"
    }
}
public struct LibraryDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pageCount: Int
    public var addedAt = Date()
    public var lastOpenedAt = Date()
    public init(id: UUID = UUID(), name: String, pageCount: Int) { self.id = id; self.name = name; self.pageCount = pageCount }
}
public struct DocumentNotes: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var pageIndex = 0
    public var sessions: [StudySession] = []
    public var drawings: [Int: Data] = [:]
    public var map: DocumentMap?
    public var welcomed = false
    /// Books are read a chapter at a time: Halo's map of each chapter, keyed by its first page index.
    public var chapterMaps: [Int: DocumentMap]?
    /// The last session summary Halo wrote, kept so reopening it is instant.
    public var summary: SessionRecap?
    /// Lines of the student's working that Halo checked and found correct, by page: where its ✓ marks go.
    public var ticks: [Int: [PageRegion]]?
    /// The student's own notes for this document.
    public var notebook: [NotebookEntry]?
    public init() {}
}

// MARK: - The student's own notes

public struct NotePoint: Codable, Equatable, Sendable {
    public var text: String
    /// True when Halo added this; false when it is the student's own point, tidied up.
    public var added: Bool
    public init(text: String, added: Bool = false) { self.text = text; self.added = added }
}
public struct NoteSection: Codable, Equatable, Sendable {
    public var heading: String
    public var points: [NotePoint]
    /// A diagram worth drawing for this section (a description), or empty.
    public var image: String?
    /// The drawn diagram (JPEG), once it has arrived.
    public var picture: Data?
    public init(heading: String, points: [NotePoint], image: String? = nil) { self.heading = heading; self.points = points; self.image = image }
}
public struct NoteTerm: Codable, Equatable, Sendable {
    public var term: String
    public var meaning: String
}
public struct NoteCorrection: Codable, Equatable, Sendable {
    public var wrote: String
    public var correct: String
}
/// Halo's organized, filled-out version of a note. The student's own text is kept beside it, untouched.
public struct EnhancedNote: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var sections: [NoteSection]
    public var terms: [NoteTerm]?
    public var corrections: [NoteCorrection]?
    /// The text this was written from (set on the iPad); if the note has changed since, it is out of date.
    public var source: String?
    public init(title: String, summary: String, sections: [NoteSection]) { self.title = title; self.summary = summary; self.sections = sections }
    public var plainText: String {
        var lines = [title, summary].filter { !$0.isEmpty }
        for section in sections { lines.append(""); lines.append(section.heading); lines += section.points.map { "• \($0.text)" } }
        if let terms, !terms.isEmpty { lines.append(""); lines.append("Key terms"); lines += terms.map { "\($0.term): \($0.meaning)" } }
        return lines.joined(separator: "\n")
    }
}
public struct NotebookEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var title = ""
    public var text = ""
    /// The page the student was on when they started it.
    public var pageIndex: Int
    public var createdAt = Date()
    public var updatedAt = Date()
    public var enhanced: EnhancedNote?
    /// What the student wrote by hand (PencilKit drawing data), if anything.
    public var drawing: Data?
    /// Goes up each time the handwriting changes, so an enhanced version can tell it is out of date.
    public var inkVersion: Int?
    /// Parts of the handwriting the student circled and had Halo refine, kept beside them on the page.
    public var refinements: [NoteRefinement]?
    public init(pageIndex: Int) { self.pageIndex = pageIndex }
    public var isEmpty: Bool { drawing == nil && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Identifies the note's content (typed and handwritten) as it is now.
    public var signature: String { drawing == nil ? text : "\(text)\u{1}ink\(inkVersion ?? 0)" }
    public var displayTitle: String {
        let own = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        if let enhanced, !enhanced.title.isEmpty { return enhanced.title }
        return text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(60)) } ?? (drawing == nil ? "New note" : "Handwritten note")
    }
}
/// Halo's refinement of one circled part of a handwritten note, kept on the page beside the circle.
public struct NoteRefinement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var ask: String
    /// The circled area and the circle itself, in the note page's points (top-left origin).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var loop: [LassoPoint]
    public var title: String
    public var points: [NotePoint]
    public var image: String?
    public var picture: Data?
    public var createdAt = Date()
    public init(id: UUID, ask: String, x: Double, y: Double, width: Double, height: Double, loop: [LassoPoint], title: String, points: [NotePoint], image: String?, picture: Data?) {
        self.id = id; self.ask = ask; self.x = x; self.y = y; self.width = width; self.height = height; self.loop = loop
        self.title = title; self.points = points; self.image = image; self.picture = picture
    }
}
public struct RefineRequest: Encodable, Sendable {
    public var ask: String
    /// The circled handwriting (base64 JPEG), and the whole handwritten page for context.
    public var image: String?
    public var overview: String?
    /// Or: the typed text they selected.
    public var selected: String
    public var text: String
    public var title: String
    public var document: String
    public var pageText: String
    public var learner: LearnerProfile?
    public init(ask: String, selected: String = "", text: String, title: String, document: String, pageText: String) {
        self.ask = ask; self.selected = String(selected.prefix(4000)); self.text = String(text.prefix(6000)); self.title = title
        self.document = document; self.pageText = String(pageText.prefix(4000))
    }
}
public struct RefineReply: Codable, Equatable, Sendable {
    public var title: String
    public var points: [NotePoint]
    /// For typed selections: the refined text, ready to replace what they selected.
    public var replacement: String
    /// A diagram worth drawing, or empty.
    public var image: String
    public init(title: String, points: [NotePoint], replacement: String = "", image: String = "") { self.title = title; self.points = points; self.replacement = replacement; self.image = image }
}
public struct EnhanceRequest: Encodable, Sendable {
    public var text: String
    public var title: String
    public var document: String
    public var chapter: String
    public var page: Int
    public var pageText: String
    /// The handwritten part of the note, as a base64 JPEG.
    public var image: String?
    public var learner: LearnerProfile?
    public init(entry: NotebookEntry, document: String, chapter: String, pageText: String, image: String? = nil, learner: LearnerProfile? = nil) {
        self.image = image
        self.text = String(entry.text.prefix(12000)); self.title = entry.title; self.document = document; self.chapter = chapter
        self.page = entry.pageIndex + 1; self.pageText = String(pageText.prefix(6000))
        self.learner = learner.flatMap { $0.isEmpty && $0.struggles.isEmpty ? nil : $0 }
    }
}

// MARK: - Halo watches you work

/// A box on the image that was sent, each value 0-1 from the top-left.
public struct CheckBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
}
public struct CheckLine: Codable, Equatable, Sendable {
    public var n: Int
    public var source: String
    public var text: String
    public var box: CheckBox?
}
/// What Halo made of the working: "correct", "wrong", "unsure" or "nothing".
public struct CheckVerdict: Codable, Equatable, Sendable {
    public var status: String
    public var line: Int?
    public var box: CheckBox?
    public var kind: String?
    public var concept: String?
    public var topic: String?
    public var problem: String?
    public var lines: [CheckLine]?
    public func text(ofLine n: Int?) -> String { lines?.first { $0.n == n }?.text ?? "" }
}
/// An anonymous ID for this device, made on first use and kept in the Keychain (so it survives reinstalls).
/// Halo's memory of the learner is filed under it. There is no login: this is for the demo, not for real accounts.
public enum DeviceID {
    private static let service = "app.halo.device", account = "learner"
    public static let current: String = load() ?? create()
    private static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func create() -> String {
        let id = UUID().uuidString.lowercased()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecValueData as String: Data(id.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        // If the Keychain refuses (some simulators), fall back to UserDefaults so the ID is still stable.
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess {
            if let saved = UserDefaults.standard.string(forKey: "halo.deviceID") { return saved }
            UserDefaults.standard.set(id, forKey: "halo.deviceID")
        }
        return id
    }
}
/// "Why am I stuck?": the checker's verdict plus the chapter, for the deep agent that looks for the missing idea.
public struct StuckRequest: Encodable, Sendable {
    public struct Line: Encodable, Sendable { public var n: Int; public var source: String; public var text: String }
    public var problem: String
    public var lines: [Line]
    public var line: Int
    public var concept: String
    public var hint: String
    public var title: String
    public var chapter: String?
    public var pages: [DigestPage]
    public var learner: LearnerProfile?
    /// Which learner's memory to use: this device's anonymous ID.
    public var learnerId = DeviceID.current
    public init(verdict: CheckVerdict, hint: String, title: String, chapter: String?, pages: [DigestPage], learner: LearnerProfile?) {
        problem = verdict.problem ?? ""; line = verdict.line ?? 0; concept = verdict.concept ?? ""
        lines = (verdict.lines ?? []).map { Line(n: $0.n, source: $0.source, text: $0.text) }
        self.hint = String(hint.prefix(240)); self.title = title; self.chapter = chapter; self.pages = pages
        self.learner = learner.flatMap { $0.isEmpty && $0.struggles.isEmpty ? nil : $0 }
    }
}
/// One item of the plan the agent wrote for itself; the note shows the list ticking off while it works.
public struct AgentTodo: Codable, Equatable, Sendable {
    public var content: String
    public var status: String
    public init(content: String, status: String) { self.content = content; self.status = status }
}
/// The idea behind a mistake, and where the student's own book teaches it.
public struct StuckDiagnosis: Codable, Equatable, Sendable {
    public var gap: String
    public var why: String
    /// 1-based page of the book, 0 when the book does not cover it.
    public var page: Int
    public var quote: String
    public var seenBefore: Bool
    public var question: String
}
/// Progress from a deep agent run (/api/stuck).
public enum AgentEvent: Equatable, Sendable {
    case todos([AgentTodo])
    case stage(String)
    case diagnosis(StuckDiagnosis)
}
public struct CheckRequest: Encodable, Sendable {
    public var image: String
    public var imageMime = "image/jpeg"
    public var pageText: String
    public var pageTitle: String
    public var pageUrl: String
    public var learner: LearnerProfile?
    /// Practice results are remembered per device (anonymous; see DeviceID).
    public var learnerId = DeviceID.current
    public init(image: String, pageText: String, title: String, documentID: UUID, page: Int, learner: LearnerProfile? = nil) {
        self.image = image; self.pageText = String(pageText.prefix(3000))
        self.pageTitle = "\(title) · Page \(page + 1)"
        self.pageUrl = "halo-document://\(documentID.uuidString)/page/\(page + 1)"
        self.learner = learner.flatMap { $0.isEmpty && $0.struggles.isEmpty ? nil : $0 }
    }
}

public struct AskRequest: Encodable, Sendable {
    public var question: String
    public var selectionMode: String
    public var conversation: [ConversationTurn]
    public var image: String?
    public var imageMime = "image/jpeg"
    public var contextImage: String?
    public var circledText: String
    public var pageText: String
    public var pageTitle: String
    public var pageUrl: String
    public var tutorMode: Bool
    public var previousAnswer: String?
    public var parentId: Int?
    public var surface = "margin"
    /// The reader can mark printed text on the page while Halo talks.
    public var pointing = true
    public var learner: LearnerProfile?
    public init(question: String, session: StudySession, image: String?, contextImage: String?, selectedText: String, pageText: String, title: String, documentID: UUID, tutorMode: Bool, learner: LearnerProfile? = nil) {
        self.question = question; self.selectionMode = session.region == nil ? "page" : "crop"
        self.conversation = Array(session.conversation.suffix(20))
        self.image = image; self.contextImage = contextImage
        self.circledText = String(selectedText.prefix(2000)); self.pageText = String(pageText.prefix(12000))
        self.pageTitle = "\(title) · Page \(session.pageIndex + 1)"
        self.pageUrl = "halo-document://\(documentID.uuidString)/page/\(session.pageIndex + 1)"
        self.tutorMode = tutorMode
        self.previousAnswer = session.conversation.last(where: { $0.role == "assistant" })?.text
        self.parentId = session.parentID
        self.learner = learner.flatMap { $0.isEmpty && $0.struggles.isEmpty ? nil : $0 }
    }
}

// MARK: - Go deeper: Halo looks it up on the web

/// What Halo decided to search for, and what it says while it searches.
public struct DivePlan: Codable, Equatable, Sendable {
    public var title: String
    public var say: String
    public var web: String
    public var video: String
    public var wiki: String
    public var image: String
}
public struct DiveRequest: Encodable, Sendable {
    public var question: String
    public var topic: String
    public var context: String
    public var document: String
    public var learner: LearnerProfile?
    public init(question: String, topic: String = "", context: String, document: String, learner: LearnerProfile?) {
        self.question = String(question.prefix(300)); self.topic = topic; self.context = String(context.prefix(2500)); self.document = document; self.learner = learner
    }
}
/// A page Halo read. `cites` in a section are 1-based positions in the answer's `sources`.
public struct DiveSource: Codable, Equatable, Sendable {
    public var title: String
    public var url: String
    public var site: String
}
public struct DiveSection: Codable, Equatable, Sendable {
    public var heading: String
    public var text: String
    public var cites: [Int]
}
public struct DiveAnswer: Codable, Equatable, Sendable {
    public var sections: [DiveSection]
    public var takeaway: String
    public var say: String
    public var audio: String?
    public var sources: [DiveSource]
    public var searches: [String]
    /// Questions worth asking next, one step deeper. Absent from older servers.
    public var next: [String]?
}
public struct DiveVideo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var channel: String
    public var length: String
    public var views: String
    public var thumbnail: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
    public var link: URL? { URL(string: "https://www.youtube.com/watch?v=\(id)") }
}
/// Where in a video the student's question is answered, found by Halo watching it.
public struct DiveMoment: Codable, Equatable, Sendable {
    public var start: Int
    public var why: String
    public var clock: String { start >= 3600 ? String(format: "%d:%02d:%02d", start / 3600, start % 3600 / 60, start % 60) : String(format: "%d:%02d", start / 60, start % 60) }
}
public struct DiveImage: Codable, Equatable, Identifiable, Sendable {
    public var thumb: String
    public var title: String
    public var credit: String
    public var license: String
    public var page: String
    public var width: Double?
    public var height: Double?
    public var id: String { thumb }
}

// MARK: - Chapter tutoring
public struct LessonConcept: Codable, Equatable, Identifiable, Sendable {
    public var n: Int; public var name: String; public var why: String; public var page: Int; public var kind: String; public var minutes: Int
    public var id: Int { n }
}
public struct LessonPlan: Codable, Equatable, Sendable {
    public var id: String; public var title: String; public var thread: String; public var say: String; public var audio: String?; public var concepts: [LessonConcept]
    /// Short things Halo says the moment the student answers ("Mm, okay..."), so there is no silence while it thinks.
    public var fillers: [LessonFiller]?
}
public struct LessonFiller: Codable, Equatable, Sendable {
    /// "guess" (after the student's guess) or "answer" (after an answer to a check).
    public var kind: String; public var say: String; public var audio: String?
}
public struct LessonQuestion: Codable, Equatable, Sendable {
    /// `kind` is "hook" (Halo asks what the student thinks before teaching; never graded), "open" or "choice".
    public var n: Int; public var kind: String; public var ask: String; public var options: [String]; public var hint: String; public var audio: String?; public var again: Bool?
    /// How the question hands the idea back: "guess", "explain", "predict", "next_move", "spot_the_slip" or "choice".
    public var style: String?
}
public struct LessonGrade: Codable, Equatable, Sendable {
    public var n: Int; public var verdict: String; public var say: String; public var audio: String?; public var note: String
}
public struct LessonMastery: Codable, Equatable, Sendable { public var n: Int; public var verdict: String }
public struct LessonSummary: Codable, Equatable, Sendable {
    public var say: String; public var audio: String?; public var nailed: [String]; public var revisit: [String]; public var takeaway: String; public var mastery: [LessonMastery]
}
public enum LessonEvent: Equatable, Sendable {
    case plan(LessonPlan), concept(Int), material(LessonMaterial), question(LessonQuestion), grade(LessonGrade), finish(LessonSummary)
}
public struct LessonReply: Encodable, Sendable {
    public var id: String; public var answer: String; public var action: String; public var concept: Int; public var requestID: String
    public init(id: String, answer: String = "", action: String = "answer", concept: Int = 0, requestID: String = UUID().uuidString) {
        self.id = id; self.answer = answer; self.action = action; self.concept = concept; self.requestID = requestID
    }
}

public struct LessonAnchor: Codable, Equatable, Sendable { public var page: Int; public var quote: String }
public struct LessonDiagramNode: Codable, Equatable, Sendable { public var label: String; public var detail: String }
public struct LessonVisual: Codable, Equatable, Sendable { public var kind: String; public var title: String; public var nodes: [LessonDiagramNode]; public var caption: String }
public struct LessonExample: Codable, Equatable, Sendable { public var title: String; public var given: String; public var steps: [String]; public var result: String; public var why: String }
public struct LessonWeb: Codable, Equatable, Sendable { public var heading: String; public var text: String; public var sources: [DiveSource] }
public struct LessonMaterial: Codable, Equatable, Sendable {
    public var n: Int; public var anchor: LessonAnchor; public var headline: String; public var status: String
    public var visual: LessonVisual?; public var example: LessonExample?; public var web: LessonWeb?; public var images: [DiveImage]
}
