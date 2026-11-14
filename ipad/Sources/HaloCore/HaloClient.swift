import Foundation

public enum HaloError: LocalizedError, Equatable {
    case invalidServer, server(Int), malformedEvent, incompleteStream, unsupportedNotes, unreadableDocument
    case importFailed(String)
    public var errorDescription: String? {
        switch self {
        case .importFailed(let message): return message
        case .invalidServer: return "Add a valid HTTP or HTTPS server address in Settings."
        case .server(let status): return "The Halo server returned HTTP \(status). Check the server connection and configuration."
        case .malformedEvent: return "The server sent an unreadable answer. Please try again."
        case .incompleteStream: return "The connection ended before the answer finished. Your question is ready to retry."
        case .unsupportedNotes: return "These notes were saved by a different app version. Update Halo before opening them."
        case .unreadableDocument: return "This PDF could not be opened. Try an unlocked PDF exported from your slides."
        }
    }
}
public enum AskEvent: Equatable, Sendable {
    case start(Int)
    case lesson(LessonEvent)
    case meta(mode: String, topic: String)
    case step(AnswerStep)
    /// Only from /api/check: what Halo made of the student's working.
    case verdict(CheckVerdict)
    /// Only from /api/stuck: the deep agent's plan, what it is doing, and what it found.
    case agent(AgentEvent)
    case done
    case failure(String)
}

/// SSE data can span lines. Comments, unknown event types, and CRLF are supported.
public struct EventDecoder: Sendable {
    private var event = "message"
    private var data: [String] = []
    private var count = 0
    private var lineBytes: [UInt8] = []
    public init() {}
    public mutating func consume(_ rawLine: String) throws -> AskEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return try dispatch() }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        if field == "event" { event = value }
        if field == "data" {
            count += value.utf8.count
            guard count <= 32 * 1024 * 1024 else { throw HaloError.malformedEvent }
            data.append(value)
        }
        return nil
    }
    public mutating func consume(byte: UInt8) throws -> AskEvent? {
        if byte == 10 {
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            return try consume(line)
        }
        guard lineBytes.count < 32 * 1024 * 1024 else { throw HaloError.malformedEvent }
        lineBytes.append(byte); return nil
    }
    public mutating func finish() throws -> AskEvent? {
        if !lineBytes.isEmpty {
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll()
            if let event = try consume(line) { return event }
        }
        return try dispatch()
    }
    private mutating func dispatch() throws -> AskEvent? {
        let name = event, payload = data.joined(separator: "\n")
        event = "message"; data = []; count = 0
        guard !payload.isEmpty else { return nil }
        let bytes = Data(payload.utf8), decoder = JSONDecoder()
        struct Start: Decodable { let id: Int? }
        struct Meta: Decodable { let mode: String; let topic: String }
        struct Failure: Decodable { let message: String }
        do {
            switch name {
            case "plan": return .lesson(.plan(try decoder.decode(LessonPlan.self, from: bytes)))
            case "concept":
                struct Concept: Decodable { let n: Int }
                return .lesson(.concept(try decoder.decode(Concept.self, from: bytes).n))
            case "material": return .lesson(.material(try decoder.decode(LessonMaterial.self, from: bytes)))
            case "question": return .lesson(.question(try decoder.decode(LessonQuestion.self, from: bytes)))
            case "grade": return .lesson(.grade(try decoder.decode(LessonGrade.self, from: bytes)))
            case "finish": return .lesson(.finish(try decoder.decode(LessonSummary.self, from: bytes)))
            case "start": return .start(try decoder.decode(Start.self, from: bytes).id ?? 0)
            case "verdict": return .verdict(try decoder.decode(CheckVerdict.self, from: bytes))
            case "todos":
                struct Plan: Decodable { let todos: [AgentTodo] }
                return .agent(.todos(try decoder.decode(Plan.self, from: bytes).todos))
            case "stage":
                // /api/check also sends stages, without anything to show.
                struct Stage: Decodable { let say: String? }
                return try decoder.decode(Stage.self, from: bytes).say.map { .agent(.stage($0)) }
            case "diagnosis": return .agent(.diagnosis(try decoder.decode(StuckDiagnosis.self, from: bytes)))
            case "meta": let meta = try decoder.decode(Meta.self, from: bytes); return .meta(mode: meta.mode, topic: meta.topic)
            case "step": return .step(try decoder.decode(AnswerStep.self, from: bytes))
            case "done": return .done
            case "error": return .failure(try decoder.decode(Failure.self, from: bytes).message)
            default: return nil
            }
        } catch { throw HaloError.malformedEvent }
    }
}

public struct HaloClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public static func endpoint(_ base: String, path: String) throws -> URL {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme, ["http", "https"].contains(scheme.lowercased()),
              components.host != nil, components.user == nil, components.password == nil else { throw HaloError.invalidServer }
        components.query = nil; components.fragment = nil
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([components.path, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))].filter { !$0.isEmpty }).joined(separator: "/")
        guard let url = components.url else { throw HaloError.invalidServer }
        return url
    }
    public func checkHealth(server: String) async throws {
        var request = URLRequest(url: try Self.endpoint(server, path: "api/health"))
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HaloError.incompleteStream }
        guard (200..<300).contains(response.statusCode) else { throw HaloError.server(response.statusCode) }
        struct Health: Decodable { let ok: Bool }
        guard try JSONDecoder().decode(Health.self, from: data).ok else { throw HaloError.incompleteStream }
    }
    /// Reads a freshly imported document and returns Halo's map of it, with a spoken welcome.
    public func digest(_ payload: DigestRequest, server: String) async throws -> DocumentMap {
        var request = URLRequest(url: try Self.endpoint(server, path: "api/digest"))
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HaloError.incompleteStream }
        guard (200..<300).contains(response.statusCode) else { throw HaloError.server(response.statusCode) }
        do { return try JSONDecoder().decode(DocumentMap.self, from: data) } catch { throw HaloError.malformedEvent }
    }
    /// Halo's summary of a study session, written from the student's sticky notes.
    public func recap(_ payload: RecapRequest, server: String) async throws -> SessionRecap {
        var request = URLRequest(url: try Self.endpoint(server, path: "api/recap"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HaloError.incompleteStream }
        guard (200..<300).contains(response.statusCode) else { throw HaloError.server(response.statusCode) }
        do { return try JSONDecoder().decode(SessionRecap.self, from: data) } catch { throw HaloError.malformedEvent }
    }
    /// The student's own notes, organized and filled out. Diagrams are fetched one by one with `noteImage`.
    public func enhance(_ payload: EnhanceRequest, server: String) async throws -> EnhancedNote {
        try await post("api/notes/enhance", payload, server: server, timeout: 90)
    }
    /// One circled or selected part of the student's notes, refined as they asked.
    public func refine(_ payload: RefineRequest, server: String) async throws -> RefineReply {
        try await post("api/notes/refine", payload, server: server, timeout: 60)
    }
    /// A quiz written from the student's notes, each question with its voice.
    public func quiz(_ payload: QuizRequest, server: String) async throws -> Quiz {
        try await post("api/notes/quiz", payload, server: server, timeout: 120)
    }
    /// Marks one short answer in a quiz.
    public func grade(_ payload: QuizGradeRequest, server: String) async throws -> QuizGrade {
        try await post("api/notes/grade", payload, server: server, timeout: 45)
    }
    /// A question about the student's own notes, answered aloud.
    public func askNotes(_ payload: NotesQuestion, server: String) async throws -> NotesAnswer {
        try await post("api/notes/ask", payload, server: server, timeout: 60)
    }
    /// One diagram for a section of enhanced notes: image bytes, or nil if none could be drawn.
    public func noteImage(_ prompt: String, server: String) async throws -> Data? {
        struct Ask: Encodable { let prompt: String }
        struct Reply: Decodable { struct Image: Decodable { let data: String }; let image: Image? }
        let reply: Reply = try await post("api/notes/image", Ask(prompt: prompt), server: server, timeout: 90)
        return reply.image.flatMap { Data(base64Encoded: $0.data) }
    }
    // MARK: Go deeper (the web)
    public func divePlan(_ payload: DiveRequest, server: String) async throws -> DivePlan {
        try await post("api/dive/plan", payload, server: server, timeout: 30)
    }
    /// An explanation built from a live web search, with the pages it used.
    public func diveAnswer(_ payload: DiveRequest, server: String) async throws -> DiveAnswer {
        try await post("api/dive/answer", payload, server: server, timeout: 90)
    }
    public func diveVideos(_ query: String, server: String) async throws -> [DiveVideo] {
        struct Ask: Encodable { let query: String }
        struct Reply: Decodable { let videos: [DiveVideo] }
        let reply: Reply = try await post("api/dive/videos", Ask(query: query), server: server, timeout: 30)
        return reply.videos
    }
    /// Halo watches the video and finds where the question is answered; nil when it isn't in there.
    public func diveMoment(video: DiveVideo, question: String, server: String) async throws -> DiveMoment? {
        struct Ask: Encodable { let videoId: String; let question: String; let title: String }
        struct Reply: Decodable { let moment: DiveMoment? }
        let reply: Reply = try await post("api/dive/moment", Ask(videoId: video.id, question: question, title: video.title), server: server, timeout: 120)
        return reply.moment
    }
    public func diveImages(wiki: String, query: String, question: String, server: String) async throws -> [DiveImage] {
        struct Ask: Encodable { let wiki: String; let query: String; let question: String }
        struct Reply: Decodable { let images: [DiveImage] }
        let reply: Reply = try await post("api/dive/images", Ask(wiki: wiki, query: query, question: question), server: server, timeout: 30)
        return reply.images
    }
    /// Halo's voice for a line of text (base64 audio), or nil when the server has no voice.
    public func speak(_ text: String, server: String) async throws -> String? {
        struct Ask: Encodable { let text: String }
        struct Reply: Decodable { let audio: String? }
        let reply: Reply = try await post("api/speak", Ask(text: text), server: server, timeout: 30)
        return reply.audio
    }
    /// Office documents are converted by the user's Halo server, then kept locally as PDFs.
    public func convertOffice(_ data: Data, extension ext: String, server: String) async throws -> Data {
        guard data.count <= 25 * 1024 * 1024 else { throw HaloError.importFailed("Choose a document smaller than 25 MB.") }
        var url = URLComponents(url: try Self.endpoint(server, path: "api/documents/convert"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "extension", value: ext.lowercased())]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"; request.timeoutInterval = 110
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (pdf, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HaloError.incompleteStream }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: pdf).error)
            throw HaloError.importFailed(message ?? "Office import failed (HTTP \(response.statusCode)). Check your Halo server or export the document as PDF.")
        }
        guard pdf.starts(with: Data("%PDF-".utf8)) else { throw HaloError.unreadableDocument }
        return pdf
    }

    private func post<Payload: Encodable, Reply: Decodable>(_ path: String, _ payload: Payload, server: String, timeout: TimeInterval) async throws -> Reply {
        var request = URLRequest(url: try Self.endpoint(server, path: path))
        request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HaloError.incompleteStream }
        guard (200..<300).contains(response.statusCode) else { throw HaloError.server(response.statusCode) }
        do { return try JSONDecoder().decode(Reply.self, from: data) } catch { throw HaloError.malformedEvent }
    }
    public func ask(_ payload: AskRequest, server: String) -> AsyncThrowingStream<AskEvent, Error> {
        stream("api/ask", payload, server: server, timeout: 180)
    }
    public func startLesson(_ payload: DigestRequest, server: String) -> AsyncThrowingStream<AskEvent, Error> {
        stream("api/lesson/start", payload, server: server, timeout: 240)
    }
    public func answerLesson(_ payload: LessonReply, server: String) -> AsyncThrowingStream<AskEvent, Error> {
        stream("api/lesson/answer", payload, server: server, timeout: 240)
    }
    /// "Halo watches you work": sends an image of the student's working; a verdict comes back, then a hint if it is wrong.
    public func check(_ payload: CheckRequest, server: String) -> AsyncThrowingStream<AskEvent, Error> {
        stream("api/check", payload, server: server, timeout: 60)
    }
    /// "Why am I stuck?": a deep agent searches the student's book for the idea behind a caught mistake.
    public func stuck(_ payload: StuckRequest, server: String) -> AsyncThrowingStream<AskEvent, Error> {
        stream("api/stuck", payload, server: server, timeout: 120)
    }
    private static func canRetryStream(_ error: Error) -> Bool {
        if error as? HaloError == .incompleteStream { return true }
        guard let error = error as? URLError else { return false }
        return [.networkConnectionLost, .cannotConnectToHost, .timedOut].contains(error.code)
    }
    private func stream<Payload: Encodable & Sendable>(_ path: String, _ payload: Payload, server: String, timeout: TimeInterval) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var receivedAnswer = false
                // A dev-server restart or transient Wi-Fi drop may end an otherwise valid response.
                // Retry only before any answer content, so a partial explanation is never duplicated.
                let attempts = path == "api/ask" ? 2 : 1
                for attempt in 0..<attempts {
                    do {
                        try Task.checkCancellation()
                        var request = URLRequest(url: try Self.endpoint(server, path: path))
                        request.httpMethod = "POST"; request.timeoutInterval = timeout
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.setValue("ipad/stream-recovery-v2", forHTTPHeaderField: "X-Halo-Client")
                        request.httpBody = try JSONEncoder().encode(payload)
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let response = response as? HTTPURLResponse else { throw HaloError.incompleteStream }
                        guard (200..<300).contains(response.statusCode) else { throw HaloError.server(response.statusCode) }
                        var decoder = EventDecoder(), ended = false
                        // AsyncBytes.lines can omit empty lines, which are SSE event boundaries.
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if let event = try decoder.consume(byte: byte) {
                                if case .step = event { receivedAnswer = true }
                                continuation.yield(event)
                                if event == .done { ended = true; break }
                                if case .failure = event { ended = true; break }
                            }
                        }
                        if !ended, let event = try decoder.finish() {
                            if case .step = event { receivedAnswer = true }
                            continuation.yield(event)
                            switch event { case .done, .failure: ended = true; default: break }
                        }
                        guard ended else { throw HaloError.incompleteStream }
                        continuation.finish()
                        return
                    } catch {
                        guard !Task.isCancelled, !receivedAnswer, attempt + 1 < attempts, Self.canRetryStream(error) else {
                            continuation.finish(throwing: error); return
                        }
                        do { try await Task.sleep(for: .milliseconds(800)) }
                        catch { continuation.finish(throwing: error); return }
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
