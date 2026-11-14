import UIKit

@MainActor
enum SampleLesson {
    static func create() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("A little calculus.pdf")
        let bounds = CGRect(x: 0, y: 0, width: 792, height: 612)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            for page in 0..<3 {
                context.beginPage()
                UIColor(red: 0.985, green: 0.973, blue: 0.945, alpha: 1).setFill(); context.cgContext.fill(bounds)
                let title = ["Where does the 2x come from?", "A function inside a function", "Your turn to connect the dots"][page]
                let notes = [
                    "The power rule\n\nf(x) = x²\nf′(x) = 2x\n\nBring the exponent down. Reduce the power by one.\n\nTry selecting the derivative with Apple Pencil.",
                    "The chain rule\n\ny = (x² + 1)³\n\nOutside: u³  →  3u²\nInside: x² + 1  →  2x\n\ny′ = 3(x² + 1)² × 2x",
                    "Practice\n\nf(x) = (2x + 3)⁴\n\nWhat is the outside function?\nWhat is the inside derivative?\n\nTurn on Tutor mode for a hint."
                ][page]
                ("HALO  /  SAMPLE LESSON  /  \(page + 1)" as NSString).draw(at: CGPoint(x: 52, y: 38), withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.systemOrange])
                (title as NSString).draw(in: CGRect(x: 52, y: 86, width: 690, height: 100), withAttributes: [.font: UIFont(name: "Georgia", size: 33) ?? .systemFont(ofSize: 33), .foregroundColor: UIColor.darkGray])
                (notes as NSString).draw(in: CGRect(x: 56, y: 200, width: 680, height: 350), withAttributes: [.font: UIFont.systemFont(ofSize: 21), .foregroundColor: UIColor.darkGray])
            }
        }
        return url
    }
    static func map(pageCount: Int) -> DocumentMap {
        DocumentMap(title: "A little calculus", subject: "calculus",
                    say: "Okay, this is a short chain rule lesson, three pages. Page two is where it gets interesting... that's where the inside and outside derivatives meet. Want to start there?",
                    keyIdeas: ["power rule: xⁿ → n·xⁿ⁻¹", "chain rule = outside′ × inside′", "always ask: what's inside?"], startHere: min(2, pageCount),
                    pages: (1...max(1, pageCount)).map { PageInsight(page: $0, topic: ["power rule", "chain rule", "practice"][($0 - 1) % 3], difficulty: $0 == 2 ? 3 : 1, note: $0 == 2 ? "students forget the inner derivative" : "") })
    }
    static func answers(tutorMode: Bool, followUp: Bool) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.meta(mode: tutorMode ? "hint" : "answer", topic: "chain rule"))
            let arrow = InkItem(type: "arrow"); var toCircled = arrow; toCircled.to = "circled"
            var underline = InkItem(type: "underline"); underline.target = "previous"
            var box = InkItem(type: "box"); box.target = "previous"
            var sketch = InkItem(type: "sketch"); sketch.w = 200; sketch.h = 110
            sketch.paths = ["M 15 95 L 185 95", "M 30 100 L 30 15", "M 35 90 Q 100 85 170 25", "M 95 70 L 150 40"]
            sketch.labels = [InkLabel(x: 150, y: 62, text: "slope"), InkLabel(x: 172, y: 108, text: "x")]
            func point(_ quote: String, _ style: String) -> InkItem { var item = InkItem(type: "point"); item.quote = quote; item.style = style; return item }
            let steps: [(String, [InkItem])]
            if tutorMode {
                steps = [("Look at this... you took care of the outside power, but what's sitting inside those parentheses?", [toCircled, InkItem(type: "text", value: "outside ✓   inside ?"), point("Inside: x² + 1", "highlight")]),
                         ("What's the derivative of that inside expression on its own?", [InkItem(type: "text", value: "d/dx (inside) = ?"), underline])]
            } else if followUp {
                steps = [("Right, so this line is the inside derivative we multiplied by... picture the slope of x squared plus one.", [toCircled, sketch]),
                         ("That slope is two x, and it's the thing the chain rule hands you at the end.", [InkItem(type: "text", value: "u = x² + 1 → u′ = 2x"), box])]
            } else {
                steps = [("This 2x right here... that's the derivative of the inside, x squared plus one.", [toCircled, InkItem(type: "text", value: "d/dx (x² + 1) = 2x"), point("→ 2x", "circle")]),
                         ("The chain rule says: differentiate the outside, then multiply by the inside's derivative.", [InkItem(type: "text", value: "outside′ × inside′"), underline, point("The chain rule", "highlight")]),
                         ("So the two is just the power coming down in front. Nothing mysterious.", [InkItem(type: "text", value: "power → coefficient"), box, point("y′ = 3(x² + 1)² × 2x", "underline")])]
            }
            for (index, step) in steps.enumerated() { continuation.yield(.step(AnswerStep(index: index, say: step.0, ink: step.1))) }
            continuation.yield(.done); continuation.finish()
        }
    }
}
