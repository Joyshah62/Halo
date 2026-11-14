import Foundation
import HaloCore

final class HaloCoreChecks {
    func testReverseCropAndClamping() throws {
        let crop = try unwrap(PageRegion.drag(fromX: 500, fromY: 400, toX: 100, toY: 200, pageWidth: 1000, pageHeight: 800))
        try expectEqual(crop.x, 0.1, accuracy: 0.0001)
        try expectEqual(crop.y, 0.25, accuracy: 0.0001)
        try expectEqual(crop.width, 0.4, accuracy: 0.0001)
        let clipped = try unwrap(PageRegion(x: -0.2, y: 0.8, width: 0.5, height: 0.5))
        try expectEqual(clipped.x, 0)
        try expectEqual(clipped.width, 0.3, accuracy: 0.0001)
        try expectEqual(clipped.height, 0.2, accuracy: 0.0001)
        try expectNil(PageRegion(x: .nan, y: 0, width: 1, height: 1))
        try expectNil(PageRegion(x: 0, y: 0, width: 0, height: 1))
        try expectNil(PageRegion.drag(fromX: 0, fromY: 0, toX: 1, toY: 1, pageWidth: 0, pageHeight: 100))
    }
    func testSSECommentsCRLFAndMultilineJSON() throws {
        var decoder = EventDecoder()
        try expectNil(try decoder.consume(": keepalive\r"))
        try expectNil(try decoder.consume("event: step\r"))
        try expectNil(try decoder.consume("data: {\"index\":0,\"say\":\"x squared\",\r"))
        try expectNil(try decoder.consume("data: \"ink\":[{\"type\":\"text\",\"value\":\"x²\"}],\"audio\":null}\r"))
        guard case .step(let step) = try decoder.consume("\r") else { try fail("Expected a decoded step") }
        try expectEqual(step.say, "x squared")
        try expectEqual(step.ink.first?.value, "x²")
        try expectNil(try decoder.consume("event: done"))
        try expectNil(try decoder.consume("data: {}"))
        try expectEqual(try decoder.finish(), .done)
    }
    func testSSEFailureAndUnknownEvents() throws {
        var decoder = EventDecoder()
        _ = try decoder.consume("event: error")
        _ = try decoder.consume("data: {\"message\":\"Try again\"}")
        try expectEqual(try decoder.consume(""), .failure("Try again"))
        _ = try decoder.consume("event: future-event"); _ = try decoder.consume("data: ignored")
        try expectNil(try decoder.consume(""))
        _ = try decoder.consume("event: step"); _ = try decoder.consume("data: not json")
        try expectThrows(try decoder.consume(""))
    }
    func testLessonEventsAndRetryIdentity() throws {
        let events = [
            ("plan", #"{"id":"lesson-1","title":"Cells","thread":"How cells work","say":"Three connections.","concepts":[{"n":1,"name":"membrane","why":"Controls exchange","page":12,"kind":"idea","minutes":2}]}"#),
            ("concept", #"{"n":1}"#),
            ("question", #"{"n":1,"kind":"open","ask":"Why?","options":[],"hint":"Think about exchange"}"#),
            ("grade", #"{"n":1,"verdict":"almost","say":"One missing piece.","note":"exchange"}"#),
            ("finish", #"{"say":"Keep that connection.","nailed":[],"revisit":["membrane"],"takeaway":"Exchange matters","mastery":[{"n":1,"verdict":"almost"}]}"#),
            ("material", #"{"n":1,"anchor":{"page":12,"quote":"The membrane controls exchange."},"headline":"Follow the water","status":"ready","visual":{"kind":"flow","title":"Exchange","nodes":[{"label":"Water","detail":"Moves across"}],"caption":"See the connection"},"example":null,"web":null,"images":[]}"#)
        ]
        var decoded: [AskEvent] = []
        var decoder = EventDecoder()
        for (name, json) in events {
            for byte in "event: \(name)\r\ndata: \(json)\r\n\r\n".utf8 {
                if let event = try decoder.consume(byte: byte) { decoded.append(event) }
            }
        }
        try expectEqual(decoded.count, 6)
        guard case .lesson(.material(let material)) = decoded[5] else { try fail("Missing lesson material") }
        try expectEqual(material.anchor.page, 12)
        try expectEqual(material.visual?.kind, "flow")
        guard case .lesson(.plan(let plan)) = decoded[0], case .lesson(.question(let question)) = decoded[2] else { try fail("Lesson event mapping failed") }
        try expectEqual(plan.concepts.first?.page, 12)
        try expectEqual(question.hint, "Think about exchange")
        let reply = LessonReply(id: plan.id, answer: "It controls exchange")
        let first = try JSONEncoder().encode(reply), retry = try JSONEncoder().encode(reply)
        let a = try unwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let b = try unwrap(JSONSerialization.jsonObject(with: retry) as? [String: Any])
        try expectEqual(a["requestID"] as? String, b["requestID"] as? String)
        try expectEqual(a["answer"] as? String, "It controls exchange")
    }
    func testRequestPreservesFollowUpAndScope() throws {
        var session = StudySession(number: 1, pageIndex: 4, region: nil)
        session.parentID = 42
        session.conversation = (0..<30).map { ConversationTurn(role: $0 % 2 == 0 ? "user" : "assistant", text: "Turn \($0)") }
        let request = AskRequest(question: "Why?", session: session, image: nil, contextImage: "jpeg", selectedText: "", pageText: String(repeating: "a", count: 13000), title: "Lecture", documentID: UUID(), tutorMode: true)
        let json = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        try expectEqual(json["selectionMode"] as? String, "page")
        try expectEqual(json["parentId"] as? Int, 42)
        try expectEqual((json["conversation"] as? [[String: String]])?.count, 20)
        try expectEqual((json["pageText"] as? String)?.count, 12000)
        try expectEqual(json["pageTitle"] as? String, "Lecture · Page 5")
        try expectNil(json["image"])
        try expectEqual(json["tutorMode"] as? Bool, true)
    }
    func testServerURLs() throws {
        try expectEqual(try HaloClient.endpoint(" https://example.com/halo/ ", path: "/api/ask").absoluteString, "https://example.com/halo/api/ask")
        try expectEqual(try HaloClient.endpoint("http://my-mac.local:8787", path: "api/health").host, "my-mac.local")
        try expectThrows(try HaloClient.endpoint("file:///tmp/server", path: "api/ask"))
        try expectThrows(try HaloClient.endpoint("https://user:password@example.com", path: "api/ask"))
    }
    func testLocalLibraryRestoresConversationAndDrawing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DocumentRepository(root: root)
        let source = root.appendingPathComponent("source.pdf")
        try Data("test PDF bytes".utf8).write(to: source)
        let document = try await repository.importPDF(from: source, name: "Lecture", pageCount: 8)
        var notes = DocumentNotes()
        notes.pageIndex = 4
        var session = StudySession(number: 1, pageIndex: 4, region: PageRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        session.draft = "Follow up later"
        session.messages = [StudyMessage(role: "assistant", text: "A saved answer", ink: [InkItem(type: "text", value: "x²")])]
        notes.sessions = [session]; notes.drawings[4] = Data([1, 2, 3])
        try await repository.save(notes, for: document.id)
        let reopened = try DocumentRepository(root: root)
        let restored = try await reopened.notes(for: document.id)
        try expectEqual(restored, notes)
        let library = try await reopened.library()
        try expectEqual(library.first?.id, document.id)
        try await reopened.delete(document.id)
        let remaining = try await reopened.library()
        try expect(remaining.isEmpty)
        try expect(FileManager.default.fileExists(atPath: source.path), "The source document must never be deleted")
    }
    func testFutureNotesVersionIsNotSilentlyOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DocumentRepository(root: root)
        var notes = DocumentNotes(); notes.schemaVersion = 999
        do { try await repository.save(notes, for: UUID()); try fail("Expected a schema error") }
        catch { try expectEqual(error as? HaloError, .unsupportedNotes) }
    }
}


private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func fail(_ message: String) throws -> Never { throw CheckFailure(description: message) }
private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws { if actual != expected { throw CheckFailure(description: "Expected \(expected), received \(actual). \(message)") } }
private func expectEqual(_ actual: Double, _ expected: Double, accuracy: Double) throws { if abs(actual - expected) > accuracy { throw CheckFailure(description: "Expected \(expected), received \(actual)") } }
private func expectNil<T>(_ value: T?) throws { if value != nil { throw CheckFailure(description: "Expected nil") } }
private func expect(_ value: Bool, _ message: String = "") throws { if !value { throw CheckFailure(description: "Expected true. \(message)") } }
private func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw CheckFailure(description: "Unexpected nil") }; return value }
private func expectThrows<T>(_ expression: @autoclosure () throws -> T) throws { do { _ = try expression() } catch { return }; throw CheckFailure(description: "Expected an error") }

@main struct RunChecks {
    static func main() async {
        do { try await run() } catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        let checks = HaloCoreChecks()
        try checks.testReverseCropAndClamping(); print("PASS: normalized crop geometry")
        try checks.testSSECommentsCRLFAndMultilineJSON(); print("PASS: streaming SSE decoding")
        try checks.testSSEFailureAndUnknownEvents(); print("PASS: stream failures and unknown events")
        try checks.testRequestPreservesFollowUpAndScope(); print("PASS: follow-up request compatibility")
        try checks.testLessonEventsAndRetryIdentity(); print("PASS: chapter lesson events and retry identity")
        try checks.testServerURLs(); print("PASS: server URL validation")
        try await checks.testLocalLibraryRestoresConversationAndDrawing(); print("PASS: document, drawing, and conversation persistence")
        try await checks.testFutureNotesVersionIsNotSilentlyOverwritten(); print("PASS: schema protection")
        try await checkTransport(); print("PASS: URLSession SSE transport and incomplete-stream recovery")
    }
}

private final class MockProtocol: URLProtocol {
    static var truncated = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let events = ["event: start\ndata: {\"id\":1}\n\n", "event: step\ndata: {\"index\":0,\"say\":\"Hello\",\"ink\":[],\"audio\":null}\n\n"] + (Self.truncated ? [] : ["event: done\ndata: {}\n\n"])
        for event in events { client?.urlProtocol(self, didLoad: Data(event.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func checkTransport() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let client = HaloClient(session: session)
    let request = AskRequest(question: "Hello", session: StudySession(number: 1, pageIndex: 0, region: nil), image: nil, contextImage: nil, selectedText: "", pageText: "Text", title: "Test", documentID: UUID(), tutorMode: false)
    var received: [AskEvent] = []
    for try await event in client.ask(request, server: "https://test.invalid") { received.append(event) }
    try expectEqual(received.count, 3)
    try expectEqual(received.last, .done)
    MockProtocol.truncated = true
    do { for try await _ in client.ask(request, server: "https://test.invalid") {}; try fail("Truncated streams must fail") }
    catch { try expectEqual(error as? HaloError, .incompleteStream) }
}
