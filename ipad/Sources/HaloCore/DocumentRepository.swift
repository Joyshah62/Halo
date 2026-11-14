import Foundation

/// Local documents are copied into Halo. The original file is never modified.
public actor DocumentRepository {
    public let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Halo", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
    }
    public func library() throws -> [LibraryDocument] {
        let url = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([LibraryDocument].self, from: Data(contentsOf: url)).sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }
    public func importPDF(from source: URL, name: String, pageCount: Int) throws -> LibraryDocument {
        let document = LibraryDocument(name: name, pageCount: pageCount)
        let destination = fileURL(for: document.id)
        try FileManager.default.copyItem(at: source, to: destination)
        do { var items = try library(); items.insert(document, at: 0); try saveLibrary(items) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return document
    }
    public func fileURL(for id: UUID) -> URL { root.appendingPathComponent("Documents/\(id.uuidString).pdf") }
    public func notes(for id: UUID) throws -> DocumentNotes {
        let url = notesURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return DocumentNotes() }
        let notes = try decoder.decode(DocumentNotes.self, from: Data(contentsOf: url))
        guard notes.schemaVersion == 1 else { throw HaloError.unsupportedNotes }
        return notes
    }
    public func save(_ notes: DocumentNotes, for id: UUID) throws {
        guard notes.schemaVersion == 1 else { throw HaloError.unsupportedNotes }
        try encoder.encode(notes).write(to: notesURL(id), options: .atomic)
    }
    public func markOpened(_ id: UUID) throws {
        var items = try library()
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].lastOpenedAt = Date(); try saveLibrary(items) }
    }
    public func delete(_ id: UUID) throws {
        // Update the index first, so a failed file removal cannot leave a broken library entry.
        try saveLibrary(library().filter { $0.id != id })
        for url in [fileURL(for: id), notesURL(id)] where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    /// Topics the student has asked about across every document, most recent first.
    /// Feeds the learner profile so the tutor can connect today's question to yesterday's.
    public func recentTopics(limit: Int = 8) -> [String] {
        let notesDir = root.appendingPathComponent("Notes")
        guard let files = try? FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil) else { return [] }
        var dated: [(Date, String)] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let notes = try? decoder.decode(DocumentNotes.self, from: data) else { continue }
            for session in notes.sessions where !session.topic.isEmpty { dated.append((session.createdAt, session.topic)) }
        }
        var seen = Set<String>(), out: [String] = []
        for (_, topic) in dated.sorted(by: { $0.0 > $1.0 }) where !seen.contains(topic) { seen.insert(topic); out.append(topic); if out.count >= limit { break } }
        return out
    }
    /// Quick notes: the student's own notes that don't belong to a document.
    public func quickNotes() throws -> [NotebookEntry] {
        let url = root.appendingPathComponent("quick-notes.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([NotebookEntry].self, from: Data(contentsOf: url))
    }
    public func saveQuickNotes(_ entries: [NotebookEntry]) throws {
        try encoder.encode(entries).write(to: root.appendingPathComponent("quick-notes.json"), options: .atomic)
    }
    private func notesURL(_ id: UUID) -> URL { root.appendingPathComponent("Notes/\(id.uuidString).json") }
    private func saveLibrary(_ items: [LibraryDocument]) throws { try encoder.encode(items).write(to: root.appendingPathComponent("library.json"), options: .atomic) }
}
