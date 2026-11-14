import UIKit
import CoreText

// Teacher ink. Halo's handwriting does not go on the page itself (book pages have no
// room for it); it is written on a sheet of tracing paper that belongs to the circle. Layout happens
// in a reference space where a note is 400 units wide, so it is deterministic: a saved
// conversation re-lays out identically, and only the newest step is animated stroke by
// stroke while its audio plays. The page keeps just the circle and a small numbered tab.

enum InkPalette {
    static let answer = UIColor(red: 0.22, green: 0.19, blue: 0.84, alpha: 1)
    static let hint = UIColor(red: 0.62, green: 0.27, blue: 0.02, alpha: 1)
    static let circle = UIColor(red: 1.0, green: 0.35, blue: 0.21, alpha: 1)
    static let check = UIColor(red: 0.08, green: 0.50, blue: 0.24, alpha: 1)
    static let cross = UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1)
    static let note = UIColor(red: 0.992, green: 0.988, blue: 0.976, alpha: 1)
    static let noteEdge = UIColor(red: 0.84, green: 0.84, blue: 0.88, alpha: 1)
    static let question = UIColor(red: 0.40, green: 0.40, blue: 0.47, alpha: 1)
}

struct InkElement {
    enum Kind { case stroke, text, image }
    var kind: Kind
    var path: CGPath?
    var color: UIColor
    var width: CGFloat
    var image: UIImage?
    var rect: CGRect = .zero
    /// Relative drawing cost, used to split a step's time budget.
    var cost: CGFloat
    var bounds: CGRect { kind == .image ? rect : (path?.boundingBoxOfPath ?? .zero) }
}

/// Decoded illustrations, shared by every note so a picture is decoded once.
@MainActor
enum InkImages {
    private static let cache = NSCache<NSString, UIImage>()
    /// `trim` crops the white margin generated illustrations come with; typeset formulas and code are already tight.
    static func image(_ base64: String, trim: Bool = true) -> UIImage? {
        let key = "\(trim)|\(base64.count)|\(base64.prefix(48))|\(base64.suffix(24))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let decoded = Data(base64Encoded: base64).flatMap(UIImage.init(data:)) else { return nil }
        let image = trim ? decoded.trimmedWhitespace() : decoded
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Deterministic layout of one thread: every question and every answer written under it.
@MainActor
struct InkLayout {
    static let width: CGFloat = 400
    static let fontSize: CGFloat = 27
    static let lineHeight: CGFloat = 35
    static let pad: CGFloat = 26

    struct Line { var x: CGFloat; var baseline: CGFloat; var width: CGFloat }

    let x: CGFloat = InkLayout.pad
    let columnWidth: CGFloat = InkLayout.width - InkLayout.pad * 2
    private(set) var nextBaseline: CGFloat = 8 + InkLayout.fontSize
    private(set) var lines: [Line] = []
    /// How many trailing entries of `lines` belong to the last thing written (a wrapped sentence is several).
    private var blockCount = 0
    private(set) var elements: [InkElement] = []
    private let font: CTFont
    private let fallback: CTFont
    private let small: CTFont
    private let mode: String

    init(mode: String) {
        self.mode = mode
        font = CTFontCreateWithName("Caveat-Regular" as CFString, Self.fontSize, nil)
        fallback = CTFontCreateWithFontDescriptor(UIFont.systemFont(ofSize: Self.fontSize * 0.82, weight: .medium).fontDescriptor as CTFontDescriptor, Self.fontSize * 0.82, nil)
        small = CTFontCreateWithFontDescriptor(UIFont.systemFont(ofSize: 15.5, weight: .medium).fontDescriptor as CTFontDescriptor, 15.5, nil)
    }

    /// Everything in the thread, in order. `stop` leaves out that message and all after it.
    static func build(_ session: StudySession, stoppingBefore stop: UUID? = nil) -> InkLayout {
        var layout = InkLayout(mode: session.mode)
        for message in session.messages {
            if message.id == stop { break }
            layout.add(message)
        }
        return layout
    }
    private static var heights: [String: CGFloat] = [:]
    /// Height of the whole thread in reference units (memoized: SwiftUI asks on every scroll frame).
    static func height(of session: StudySession) -> CGFloat {
        let key = "\(session.id)|\(session.messages.count)|\(session.messages.last?.id.uuidString ?? "")"
        if let hit = heights[key] { return hit }
        if heights.count > 200 { heights.removeAll() }
        let value = build(session).height
        heights[key] = value
        return value
    }

    var height: CGFloat { elements.isEmpty ? 0 : nextBaseline - Self.fontSize + 10 }
    var inkColor: UIColor { mode == "hint" ? InkPalette.hint : InkPalette.answer }

    mutating func add(_ message: StudyMessage) {
        if message.role == "user" { addQuestion(message.text) } else { addStep(message.ink) }
    }

    // MARK: text measurement
    /// Glyphs from the given font, with a system-font stand-in for anything it lacks (→, ∑, ⁿ …).
    private func glyphs(_ text: String, in primaryFont: CTFont) -> [(glyph: CGGlyph, advance: CGFloat, font: CTFont)] {
        let chars = Array(text.utf16)
        var primary = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(primaryFont, chars, &primary, chars.count)
        var secondary = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(fallback, chars, &secondary, chars.count)
        let size = CTFontGetSize(primaryFont)
        var out: [(CGGlyph, CGFloat, CTFont)] = []
        for i in 0..<chars.count {
            let useFallback = primary[i] == 0 && secondary[i] != 0
            let f = useFallback ? fallback : primaryFont, g = useFallback ? secondary[i] : primary[i]
            var advance = CGSize.zero; var glyph = g
            CTFontGetAdvancesForGlyphs(f, .horizontal, &glyph, &advance, 1)
            out.append((g, advance.width > 0 ? advance.width : size * 0.5, f))
        }
        return out
    }
    private func measure(_ text: String, in f: CTFont) -> CGFloat { glyphs(text, in: f).reduce(0) { $0 + $1.advance } }
    private func wrap(_ text: String, width: CGFloat, in f: CTFont) -> [String] {
        var lines: [String] = [], current = ""
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if measure(candidate, in: f) <= width || current.isEmpty { current = candidate } else { lines.append(current); current = word }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
    /// `hand` makes it read as written by a person, not set in a font: the line drifts off level, the
    /// baseline wanders, and each letter differs a little in size, lean and spacing. It is seeded from
    /// the text, so a saved note is rewritten exactly the same way every time.
    private func textPath(_ text: String, at origin: CGPoint, in f: CTFont, hand: Hand? = nil) -> CGPath {
        let path = CGMutablePath()
        var cursor = origin.x
        var rng = hand?.rng ?? Hand.Generator(seed: 0)
        let chars = Array(text)
        for (index, (glyph, advance, glyphFont)) in glyphs(text, in: f).enumerated() {
            guard let hand else {
                if glyph != 0, let g = CTFontCreatePathForGlyph(glyphFont, glyph, nil) {
                    path.addPath(g, transform: CGAffineTransform(translationX: cursor, y: origin.y).scaledBy(x: 1, y: -1))
                }
                cursor += advance
                continue
            }
            let run = cursor - origin.x
            let y = origin.y + run * hand.slope + hand.wander(at: run) + rng.signed() * 0.55
            let size = 1 + rng.signed() * 0.05 + hand.swell(at: run)
            let lean = rng.signed() * 0.035
            if glyph != 0, let g = CTFontCreatePathForGlyph(glyphFont, glyph, nil) {
                let transform = CGAffineTransform(translationX: cursor, y: y).rotated(by: lean + atan(hand.slope)).scaledBy(x: size, y: -size)
                path.addPath(g, transform: transform)
            }
            // utf16 glyph runs and characters line up for the text Halo writes; a space breathes more than a letter.
            let isSpace = index < chars.count && chars[index] == " "
            cursor += advance * (1 + rng.signed() * (isSpace ? 0.22 : 0.05))
        }
        return path
    }

    /// One line's worth of human unevenness.
    struct Hand {
        /// Small deterministic generator (SplitMix64): Swift's own hashing changes between launches.
        struct Generator {
            var state: UInt64
            init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
            mutating func next() -> UInt64 {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
            /// Uniform in -1...1.
            mutating func signed() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) * 2 - 1 }
        }
        var rng: Generator
        let slope: CGFloat          // the whole line climbs or sags a touch
        let indent: CGFloat         // lines never start at exactly the same x
        private let phase: CGFloat, period: CGFloat, depth: CGFloat, swellPhase: CGFloat

        init(_ text: String, line: Int) {
            var seed: UInt64 = 0xCBF29CE484222325
            for byte in text.utf8 { seed = (seed ^ UInt64(byte)) &* 0x100000001B3 }
            var g = Generator(seed: seed ^ (UInt64(line) &* 0x9E3779B97F4A7C15))
            slope = g.signed() * 0.011
            indent = g.signed() * 2.4
            phase = g.signed() * .pi
            period = 70 + g.signed() * 22
            depth = 0.9 + g.signed() * 0.35
            swellPhase = g.signed() * .pi
            rng = g
        }
        func wander(at run: CGFloat) -> CGFloat { sin(run / period * 2 * .pi + phase) * depth }
        func swell(at run: CGFloat) -> CGFloat { sin(run / 210 * 2 * .pi + swellPhase) * 0.025 }
    }

    // MARK: building
    /// The student's question, small and printed, so the note reads on its own weeks later.
    private mutating func addQuestion(_ text: String) {
        var top = nextBaseline - Self.fontSize
        if !elements.isEmpty {
            top += 8
            let rule = CGMutablePath(); rule.move(to: CGPoint(x: x, y: top)); rule.addLine(to: CGPoint(x: x + columnWidth, y: top))
            var element = InkElement(kind: .stroke, path: rule.copy(dashingWithPhase: 0, lengths: [3, 5]), color: InkPalette.question.withAlphaComponent(0.45), width: 1, cost: 0)
            element.rect = .zero
            elements.append(element)
            top += 12
        }
        var baseline = top + 15
        for line in wrap(text, width: columnWidth, in: small).prefix(4) {
            elements.append(InkElement(kind: .text, path: textPath(line, at: CGPoint(x: x, y: baseline), in: small), color: InkPalette.question, width: 0, cost: 0))
            baseline += 20
        }
        lines.removeAll()
        nextBaseline = baseline - 20 + 12 + Self.fontSize
    }
    private mutating func addStep(_ ink: [InkItem]) {
        for item in ink {
            switch item.type {
            case "text": if let value = item.value { addText(value) }
            // An arrow "to circled" is the note's own tail pointing at the circle; nothing to draw here.
            case "arrow": if item.to == "previous" { addArrow() }
            case "underline": addUnderline()
            case "box": addBox()
            case "check": addMark(check: true)
            case "cross": addMark(check: false)
            case "sketch": addSketch(item)
            // A typeset formula or code block (from "math"/"code") says how wide it wants to be; a generated
            // illustration has no width and takes the whole column.
            case "image": if let key = item.data, let image = InkImages.image(key, trim: item.w == nil) { addImage(image, natural: item.w.map { CGFloat($0) }) }
            default: break
            }
        }
    }

    private mutating func addText(_ text: String) {
        let wrapped = wrap(text, width: columnWidth, in: font)
        blockCount = wrapped.count
        for line in wrapped {
            let baseline = nextBaseline
            let hand = Hand(line, line: elements.count)
            let start = x + hand.indent
            let path = textPath(line, at: CGPoint(x: start, y: baseline), in: font, hand: hand)
            // Underlines and boxes follow what was actually written, not the font's nominal width.
            let box = path.boundingBoxOfPath
            let width = box.isNull ? measure(line, in: font) : max(1, box.maxX - start)
            elements.append(InkElement(kind: .text, path: path, color: inkColor, width: 1.1, cost: CGFloat(max(6, line.count))))
            lines.append(Line(x: start, baseline: baseline, width: width))
            nextBaseline += Self.lineHeight
        }
    }
    /// A little hook from the start of the next line back up to the previous one.
    private mutating func addArrow() {
        guard let prev = lines.last else { return }
        let target = CGPoint(x: prev.x - 6, y: prev.baseline - Self.fontSize * 0.3)
        let from = CGPoint(x: prev.x - 4, y: nextBaseline - Self.fontSize * 0.3)
        let control = CGPoint(x: prev.x - 24, y: (from.y + target.y) / 2)
        let shaft = CGMutablePath(); shaft.move(to: from); shaft.addQuadCurve(to: target, control: control)
        let tx = target.x - control.x, ty = target.y - control.y, tl = max(1, hypot(tx, ty))
        let ux = tx / tl, uy = ty / tl, s: CGFloat = 10
        let head = CGMutablePath()
        head.move(to: CGPoint(x: target.x - ux * s - uy * s * 0.6, y: target.y - uy * s + ux * s * 0.6))
        head.addLine(to: target)
        head.addLine(to: CGPoint(x: target.x - ux * s + uy * s * 0.6, y: target.y - uy * s - ux * s * 0.6))
        elements.append(InkElement(kind: .stroke, path: shaft, color: inkColor, width: 2.2, cost: 6))
        elements.append(InkElement(kind: .stroke, path: head, color: inkColor, width: 2.2, cost: 3))
    }
    /// Underlines every line of the last thing written, not just where a long sentence happened to wrap.
    private mutating func addUnderline() {
        for prev in lines.suffix(max(1, blockCount)) {
            let y = prev.baseline + 6, path = CGMutablePath()
            path.move(to: CGPoint(x: prev.x - 2, y: y))
            var px = prev.x + 7, flip = false
            while px <= prev.x + prev.width + 4 { path.addQuadCurve(to: CGPoint(x: px, y: y), control: CGPoint(x: px - 3.5, y: y + (flip ? 3 : -3))); px += 7; flip.toggle() }
            elements.append(InkElement(kind: .stroke, path: path, color: inkColor, width: 2.2, cost: 5))
        }
    }
    /// One box around the whole of the last thing written.
    private mutating func addBox() {
        let block = lines.suffix(max(1, blockCount))
        guard let first = block.first, let last = block.last else { return }
        let minX = block.map(\.x).min() ?? first.x, maxX = block.map { $0.x + $0.width }.max() ?? first.x
        let top = first.baseline - Self.fontSize * 0.95, bottom = last.baseline + 9
        // Stay on the paper: the note is only so wide.
        let r = CGRect(x: max(6, minX - 9), y: top, width: min(Self.width - 6, maxX + 9) - max(6, minX - 9), height: bottom - top)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX, y: r.minY + 1)); path.addLine(to: CGPoint(x: r.maxX + 1, y: r.minY)); path.addLine(to: CGPoint(x: r.maxX, y: r.maxY + 1))
        path.addLine(to: CGPoint(x: r.minX - 1, y: r.maxY)); path.addLine(to: CGPoint(x: r.minX, y: r.minY - 3))
        elements.append(InkElement(kind: .stroke, path: path, color: inkColor, width: 2.4, cost: 7))
        // Leave room so the next line doesn't sit on the box.
        if block.count > 1 || last.baseline + Self.lineHeight > nextBaseline - 1 { nextBaseline = max(nextBaseline, last.baseline + Self.lineHeight + 6) }
    }
    private mutating func addMark(check: Bool) {
        let prev = lines.last
        let mx = min(Self.width - 30, prev.map { $0.x + $0.width + 12 } ?? x)
        let my = prev?.baseline ?? nextBaseline
        let path = CGMutablePath()
        if check { path.move(to: CGPoint(x: mx, y: my - 9)); path.addLine(to: CGPoint(x: mx + 7, y: my - 1)); path.addLine(to: CGPoint(x: mx + 21, y: my - 19)) }
        else { path.move(to: CGPoint(x: mx, y: my - 19)); path.addLine(to: CGPoint(x: mx + 16, y: my - 1)); path.move(to: CGPoint(x: mx + 16, y: my - 19)); path.addLine(to: CGPoint(x: mx, y: my - 1)) }
        elements.append(InkElement(kind: .stroke, path: path, color: check ? InkPalette.check : InkPalette.cross, width: 3.2, cost: 4))
    }
    private mutating func addSketch(_ item: InkItem) {
        let w = min(320, max(80, item.w ?? 200))
        var paths: [CGPath] = []
        for d in (item.paths ?? []).prefix(8) { if let p = SVGPath.parse(d) { paths.append(p) } }
        let labels = Array((item.labels ?? []).prefix(6))
        guard !paths.isEmpty || !labels.isEmpty else { return }
        var union = paths.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
        if union.isNull || union.isEmpty { union = CGRect(x: 0, y: 0, width: w, height: min(240, max(60, item.h ?? 120))) }
        // Labels are part of the drawing: without them in the bounds they spill off the note.
        for label in labels { union = union.union(CGRect(x: label.x, y: label.y - 14, width: 1, height: 16)) }
        let scale = min(1.4, columnWidth / max(1, union.width))
        let top = nextBaseline - Self.fontSize + 8
        let W = union.width * scale, H = union.height * scale
        let x0 = x + max(0, (columnWidth - W) / 2)
        var transform = CGAffineTransform(translationX: x0 - union.minX * scale, y: top - union.minY * scale).scaledBy(x: scale, y: scale)
        let placed = paths.map { $0.copy(using: &transform) ?? $0 }
        for p in placed { elements.append(InkElement(kind: .stroke, path: p, color: inkColor, width: 2.3, cost: 9)) }
        // Shapes a label can sit inside (a box, a circle): anything with real area, smallest first.
        var shapes: [CGRect] = []
        for p in placed { let b = p.boundingBoxOfPath; if b.width > 24, b.height > 18 { shapes.append(b) } }
        shapes.sort { (a: CGRect, b: CGRect) -> Bool in a.width * a.height < b.width * b.height }
        var taken: [CGRect] = []
        for label in labels {
            let text = String(label.text.prefix(18))
            var size: CGFloat = 21
            var width = MarginInkView.caveatWidth(text, size: size)
            let anchor = CGPoint(x: CGFloat(label.x), y: CGFloat(label.y)).applying(transform)
            var origin = anchor
            // The model places labels by eye and can't measure handwriting. A label that starts inside
            // a shape belongs to it: centre it there and shrink it until it fits.
            let probe = CGPoint(x: anchor.x + 4, y: anchor.y - size * 0.3)
            if let shape = shapes.first(where: { $0.insetBy(dx: -4, dy: -4).contains(probe) && $0.width < W * 0.8 }) {
                let room = shape.width - 10
                if width > room { size = max(13, size * room / width); width = MarginInkView.caveatWidth(text, size: size) }
                origin = CGPoint(x: shape.midX - width / 2, y: shape.midY + size * 0.3)
            }
            // Keep it on the paper, and off any label already written.
            origin.x = min(max(x - 8, origin.x), x + columnWidth + 8 - width)
            var box = CGRect(x: origin.x, y: origin.y - size * 0.8, width: width, height: size)
            var tries = 0
            while tries < 4, taken.contains(where: { $0.insetBy(dx: -3, dy: 0).intersects(box) }) { origin.y -= size * 0.9; box.origin.y -= size * 0.9; tries += 1 }
            taken.append(box)
            // White halo first, so a label that crosses a stroke stays readable.
            elements.append(InkElement(kind: .stroke, path: MarginInkView.caveat(text, size: size, at: origin), color: InkPalette.note, width: 5, cost: 0))
            elements.append(InkElement(kind: .text, path: MarginInkView.caveat(text, size: size, at: origin), color: inkColor, width: 0.8, cost: 4))
        }
        let drawn = taken.reduce(CGRect(x: x0, y: top, width: W, height: H)) { $0.union($1) }
        blockCount = 1
        lines.append(Line(x: x0, baseline: drawn.maxY, width: W))
        nextBaseline = drawn.maxY + 14 + Self.fontSize
    }
    private mutating func addImage(_ image: UIImage, natural: CGFloat? = nil) {
        let W = min(columnWidth, natural ?? columnWidth), H = W * image.size.height / max(1, image.size.width)
        let top = nextBaseline - Self.fontSize + 8
        let rect = CGRect(x: x, y: top, width: W, height: H)
        elements.append(InkElement(kind: .image, path: nil, color: .clear, width: 0, image: image, rect: rect, cost: 10))
        blockCount = 1
        lines.append(Line(x: x, baseline: top + H, width: W))
        nextBaseline = top + H + 14 + Self.fontSize
    }
}

extension InkElement {
    /// A layer for this element. Animated layers start invisible and are revealed by `InkPen`.
    @MainActor
    func layer(animated: Bool) -> CALayer {
        switch kind {
        case .image:
            let l = CALayer(); l.contents = image?.cgImage; l.frame = rect; l.contentsGravity = .resizeAspect
            l.cornerRadius = 4; l.masksToBounds = true
            if animated { l.opacity = 0 }
            return l
        case .stroke, .text:
            let l = CAShapeLayer(); l.path = path
            let filled = kind == .text
            l.strokeColor = width > 0 ? color.cgColor : nil; l.lineWidth = width; l.lineCap = .round; l.lineJoin = .round
            l.fillColor = filled && !animated ? color.cgColor : UIColor.clear.cgColor
            if animated { l.strokeEnd = 0 }
            return l
        }
    }
}

/// Reveals a layer the way a pen would: strokes are drawn, text is traced then filled.
@MainActor
enum InkPen {
    static func write(_ layer: CALayer, element: InkElement, seconds: Double) async {
        switch element.kind {
        case .image:
            await animate(layer, key: "opacity", from: 0, to: 1, seconds: max(0.4, seconds))
        case .stroke, .text:
            guard let shape = layer as? CAShapeLayer else { return }
            await animate(shape, key: "strokeEnd", from: 0, to: 1, seconds: max(0.08, seconds * (element.kind == .text ? 0.8 : 1)))
            if element.kind == .text {
                await animate(shape, key: "fillColor", from: UIColor.clear.cgColor, to: element.color.cgColor, seconds: 0.18)
            }
        }
    }
    private static func animate(_ layer: CALayer, key: String, from: Any, to: Any, seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CATransaction.begin()
            CATransaction.setCompletionBlock { continuation.resume() }
            let anim = CABasicAnimation(keyPath: key)
            anim.fromValue = from; anim.toValue = to; anim.duration = seconds
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.setValue(to, forKeyPath: key)
            layer.add(anim, forKey: key)
            CATransaction.commit()
        }
    }
}

/// A tiny SVG path-data parser (M L H V C S Q T A Z, absolute and relative). Arcs are approximated by lines.
enum SVGPath {
    static func parse(_ d: String) -> CGPath? {
        let path = CGMutablePath()
        var numbers: [CGFloat] = [], command: Character = "M", current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        let scanner = Scanner(string: d); scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t")
        func flush() {
            var i = 0
            func n(_ k: Int) -> CGFloat { numbers[i + k] }
            let rel = command.isLowercase
            func pt(_ k: Int) -> CGPoint { let p = CGPoint(x: n(k), y: n(k + 1)); return rel ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p }
            switch command.uppercased() {
            case "M": while i + 1 < numbers.count { let p = pt(0); if i == 0 { path.move(to: p); start = p } else { path.addLine(to: p) }; current = p; i += 2 }
            case "L": while i + 1 < numbers.count { let p = pt(0); path.addLine(to: p); current = p; i += 2 }
            case "H": while i < numbers.count { current = CGPoint(x: rel ? current.x + n(0) : n(0), y: current.y); path.addLine(to: current); i += 1 }
            case "V": while i < numbers.count { current = CGPoint(x: current.x, y: rel ? current.y + n(0) : n(0)); path.addLine(to: current); i += 1 }
            case "Q": while i + 3 < numbers.count { let c = pt(0), p = pt(2); path.addQuadCurve(to: p, control: c); lastControl = c; current = p; i += 4 }
            case "T": while i + 1 < numbers.count { let c = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current; let p = pt(0); path.addQuadCurve(to: p, control: c); lastControl = c; current = p; i += 2 }
            case "C": while i + 5 < numbers.count { let c1 = pt(0), c2 = pt(2), p = pt(4); path.addCurve(to: p, control1: c1, control2: c2); lastControl = c2; current = p; i += 6 }
            case "S": while i + 3 < numbers.count { let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current; let c2 = pt(0), p = pt(2); path.addCurve(to: p, control1: c1, control2: c2); lastControl = c2; current = p; i += 4 }
            case "A": while i + 6 < numbers.count { let p = CGPoint(x: n(5), y: n(6)); let dest = rel ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p; path.addLine(to: dest); current = dest; i += 7 }
            default: break
            }
            numbers.removeAll()
        }
        while !scanner.isAtEnd {
            if let value = scanner.scanDouble() { numbers.append(CGFloat(value)); continue }
            guard let ch = scanner.scanCharacter() else { break }
            if ch.isLetter {
                flush()
                if ch == "Z" || ch == "z" { path.closeSubpath(); current = start; command = "M"; continue }
                command = ch
            } else { break }
        }
        flush()
        return path.isEmpty ? nil : path
    }
}

extension UIImage {
    /// Generated illustrations come with a wide white margin; crop it so the picture sits tight in the margin.
    func trimmedWhitespace() -> UIImage {
        guard let cg = cgImage, cg.width > 8, cg.height > 8 else { return self }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }() else { return self }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        var y = 0
        while y < h { var x = 0; while x < w { let i = (y * w + x) * 4; if px[i] < 225 || px[i + 1] < 225 || px[i + 2] < 225 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }; x += 2 }; y += 2 }
        guard x1 > x0, y1 > y0 else { return self }
        let pad = Int(Double(min(w, h)) * 0.04)
        let rect = CGRect(x: max(0, x0 - pad), y: max(0, y0 - pad), width: min(w, x1 + pad) - max(0, x0 - pad), height: min(h, y1 + pad) - max(0, y0 - pad))
        guard let cut = cg.cropping(to: rect) else { return self }
        return UIImage(cgImage: cut)
    }
}
/// One per page. The page itself stays clean: the student's circles, a numbered sticky tab
/// for each one (tap it to bring its note back), and the difficulty mark.
@MainActor
final class MarginInkView: UIView {
    static let reference: CGFloat = 1000
    private let container = CALayer()
    private var drawn: [CALayer] = []
    private var tabs: [(id: UUID, rect: CGRect)] = []     // reference space
    private var pageAspect: CGFloat = 1.3
    private var signature = ""
    private(set) var hotspotFrame: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        layer.addSublayer(container)
        container.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var scale: CGFloat { bounds.width / Self.reference }
    private var size: CGSize { CGSize(width: Self.reference, height: Self.reference * pageAspect) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pageAspect = bounds.height / bounds.width
        container.bounds = CGRect(origin: .zero, size: size)
        container.anchorPoint = .zero; container.position = .zero
        container.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    func render(sessions: [StudySession], active: UUID?, insight: PageInsight?, ticks: [PageRegion] = [], glance: PageRegion? = nil, pointer: PagePointing? = nil) {
        show(pointer)
        let key = sessions.map { "\($0.id)\($0.number)\($0.messages.isEmpty)\($0.circlePending ?? false)\($0.lasso?.first.map { "\($0.x),\($0.y)" } ?? "")" }.joined() + "|\(active?.uuidString ?? "")|\(insight?.topic ?? "")\(insight?.difficulty ?? 0)|\(pageAspect)"
            + "|\(ticks.count)|\(glance.map { "\($0.x),\($0.y)" } ?? "")"
        guard key != signature else { return }
        signature = key
        // The circle is there to say "this part": once the question about it has been asked it fades away, and only
        // the numbered tab stays. A circle Halo drew itself around a mistake stays while its note is open.
        func keepsCircle(_ session: StudySession) -> Bool { session.id == active && (session.messages.isEmpty || session.circlePending == true || session.origin == "check") }
        if let shown = shownCircle, !sessions.contains(where: { $0.id == shown.id && keepsCircle($0) }) {
            drawn.removeAll { $0 === shown.layer }
            fadeOut(shown.layer)
            shownCircle = nil
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        drawn.forEach { $0.removeFromSuperlayer() }; drawn.removeAll(); tabs.removeAll()
        var pageLevel = 0
        for session in sessions {
            let isActive = session.id == active
            if keepsCircle(session), let lasso = session.lasso, lasso.count > 2 {
                let circle = circleLayer(lasso, dimmed: false)
                // Reopening a note draws its circle back in.
                if shownCircle?.id != session.id, !(session.origin == "check" && !penned.contains(session.id)) { pen(circle, seconds: 0.4) }
                shownCircle = (session.id, circle)
                // A circle Halo drew itself appears the way a pen would draw it, once.
                if session.origin == "check", !penned.contains(session.id) {
                    penned.insert(session.id)
                    if Date().timeIntervalSince(session.createdAt) < 3 { pen(circle, seconds: 0.55) }
                }
                add(circle)
            }
            // The tab hangs off the circle's top-right corner; whole-page notes stack down the left edge.
            let origin: CGPoint
            if let r = session.region {
                origin = CGPoint(x: min(size.width - 40, (r.x + r.width) * size.width - 8), y: max(4, r.y * size.height - 26))
            } else {
                origin = CGPoint(x: 10, y: 70 + CGFloat(pageLevel) * 44); pageLevel += 1
            }
            let rect = CGRect(x: origin.x, y: origin.y, width: 34, height: 34)
            addTab(rect, number: session.number, active: isActive)
            tabs.append((session.id, rect))
        }
        if let insight, insight.difficulty >= 3 { addHotspot(insight) } else { hotspotFrame = nil }
        for (index, tick) in ticks.enumerated() { addTick(tick, fresh: index >= tickCount) }
        tickCount = ticks.count
        if let glance { addGlance(glance) }
        CATransaction.commit()
    }

    // MARK: Pointing at the printed page
    // While a step is spoken Halo marks what it is talking about on the page itself, like a tutor
    // tapping the book with a pen. The mark is drawn in, and fades out when the step is over.
    private var pointerID: UUID?
    private var pointerLayers: [CALayer] = []
    private var shownCircle: (id: UUID, layer: CALayer)?

    private func fadeOut(_ layer: CALayer, seconds: Double = 0.45) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = layer.opacity; fade.toValue = 0; fade.duration = seconds
        layer.opacity = 0; layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }
    static let highlighter = UIColor(red: 1.0, green: 0.80, blue: 0.16, alpha: 0.42)

    private func show(_ pointer: PagePointing?) {
        guard pointer?.id != pointerID else { return }
        pointerID = pointer?.id
        let old = pointerLayers; pointerLayers = []
        if !old.isEmpty {
            CATransaction.begin()
            CATransaction.setCompletionBlock { old.forEach { $0.removeFromSuperlayer() } }
            for layer in old {
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = layer.opacity; fade.toValue = 0; fade.duration = 0.45
                layer.opacity = 0; layer.add(fade, forKey: "fade")
            }
            CATransaction.commit()
        }
        guard let pointer, !pointer.regions.isEmpty else { return }
        let rects = pointer.regions.map { CGRect(x: $0.x * size.width, y: $0.y * size.height, width: $0.width * size.width, height: $0.height * size.height) }
        var seed = UInt64(truncatingIfNeeded: pointer.id.hashValue)
        func jitter() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(Int64(bitPattern: seed >> 11) % 1000) / 1000 }
        switch pointer.style {
        case "circle":
            let all = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let r = all.insetBy(dx: -max(10, all.height * 0.45), dy: -max(7, all.height * 0.45))
            let path = CGMutablePath()
            // One and a bit turns, slightly off-round: drawn, not stamped.
            for i in 0...52 {
                let t = CGFloat(i) / 46, angle = -2.4 + t * 2 * .pi
                let wobble = 1 + 0.04 * sin(t * 8.7) - 0.035 * t
                let p = CGPoint(x: r.midX + cos(angle) * r.width / 2 * wobble, y: r.midY + sin(angle) * r.height / 2 * wobble)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            addPointerStroke(path, color: InkPalette.circle, width: 3, delay: 0, seconds: 0.5)
        case "underline":
            for (i, r) in rects.enumerated() {
                let y = r.maxY + 3, lift = jitter() * 2.5
                let path = CGMutablePath()
                path.move(to: CGPoint(x: r.minX - 3, y: y + lift))
                path.addQuadCurve(to: CGPoint(x: r.maxX + 5, y: y - lift), control: CGPoint(x: r.midX, y: y + 2.5))
                addPointerStroke(path, color: InkPalette.circle, width: 3, delay: Double(i) * 0.3, seconds: 0.3)
            }
        default:
            for (i, r) in rects.enumerated() {
                let tilt = (jitter() - 0.5) * r.height * 0.18
                let path = CGMutablePath()
                path.move(to: CGPoint(x: r.minX - 4, y: r.midY + tilt))
                path.addQuadCurve(to: CGPoint(x: r.maxX + 4, y: r.midY - tilt), control: CGPoint(x: r.midX, y: r.midY + r.height * 0.06))
                addPointerStroke(path, color: Self.highlighter, width: r.height * 1.1, delay: Double(i) * 0.3, seconds: 0.35, cap: .butt, multiply: true)
            }
        }
    }
    private func addPointerStroke(_ path: CGPath, color: UIColor, width: CGFloat, delay: Double, seconds: Double, cap: CAShapeLayerLineCap = .round, multiply: Bool = false) {
        let layer = CAShapeLayer()
        layer.path = path; layer.fillColor = UIColor.clear.cgColor; layer.strokeColor = color.cgColor
        layer.lineWidth = width; layer.lineCap = cap; layer.lineJoin = .round
        // A highlighter tints the print under it instead of covering it.
        if multiply { layer.compositingFilter = "multiplyBlendMode" }
        container.addSublayer(layer); pointerLayers.append(layer)
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0; draw.toValue = 1; draw.duration = seconds
        draw.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        draw.fillMode = .backwards; draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(draw, forKey: "pen")
    }

    // MARK: Halo watches you work
    private var penned: Set<UUID> = []
    private var tickCount = Int.max      // ticks already on the page when it first appears are not re-drawn
    private func pen(_ layer: CAShapeLayer, seconds: Double) {
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0; draw.toValue = 1; draw.duration = seconds
        draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(draw, forKey: "pen")
    }
    /// A green ✓ just past the end of a line Halo checked.
    private func addTick(_ region: PageRegion, fresh: Bool) {
        let x = min(size.width - 44, (region.x + region.width) * size.width + 16)
        let y = (region.y + region.height / 2) * size.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y - 1)); path.addLine(to: CGPoint(x: x + 9, y: y + 10)); path.addQuadCurve(to: CGPoint(x: x + 30, y: y - 17), control: CGPoint(x: x + 16, y: y - 4))
        let tick = CAShapeLayer(); tick.path = path; tick.fillColor = UIColor.clear.cgColor; tick.strokeColor = InkPalette.check.cgColor
        tick.lineWidth = 3.6; tick.lineCap = .round; tick.lineJoin = .round
        if fresh { pen(tick, seconds: 0.35) }
        add(tick)
    }
    /// A quiet pulsing dot beside the working while Halo is looking at it.
    private func addGlance(_ region: PageRegion) {
        let x = min(size.width - 30, (region.x + region.width) * size.width + 22)
        let y = region.y * size.height + 6
        let dot = CAShapeLayer()
        dot.frame = CGRect(x: x, y: y, width: 12, height: 12)
        dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 12, height: 12), transform: nil)
        dot.fillColor = InkPalette.circle.cgColor
        let pulse = CABasicAnimation(keyPath: "opacity"); pulse.fromValue = 1; pulse.toValue = 0.25; pulse.duration = 0.7; pulse.autoreverses = true; pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
        add(dot)
    }

    /// The note tab under a point in this view's coordinates, if any.
    func tab(at point: CGPoint) -> UUID? {
        guard scale > 0 else { return nil }
        let p = CGPoint(x: point.x / scale, y: point.y / scale)
        return tabs.last { $0.rect.insetBy(dx: -8, dy: -8).contains(p) }?.id
    }

    private func add(_ layer: CALayer) { container.addSublayer(layer); drawn.append(layer) }
    private func circleLayer(_ lasso: [LassoPoint], dimmed: Bool) -> CAShapeLayer {
        let pts = lasso.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let path = CGMutablePath(); path.move(to: pts[0])
        for i in 1..<(pts.count - 1) { path.addQuadCurve(to: CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2), control: pts[i]) }
        path.addLine(to: pts[pts.count - 1])
        let l = CAShapeLayer(); l.path = path; l.strokeColor = InkPalette.circle.cgColor; l.fillColor = UIColor.clear.cgColor
        l.lineWidth = dimmed ? 2.6 : 3.4; l.lineCap = .round; l.lineJoin = .round; l.opacity = dimmed ? 0.55 : 1
        l.shadowColor = InkPalette.circle.cgColor; l.shadowOpacity = dimmed ? 0 : 0.35; l.shadowRadius = 3; l.shadowOffset = .zero
        return l
    }
    private func addTab(_ rect: CGRect, number: Int, active: Bool) {
        let fold: CGFloat = 9
        let body = CGMutablePath()
        body.move(to: CGPoint(x: rect.minX, y: rect.minY)); body.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        body.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold)); body.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
        body.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); body.closeSubpath()
        let paper = CAShapeLayer(); paper.path = body; paper.fillColor = InkPalette.note.cgColor
        paper.strokeColor = (active ? InkPalette.circle : InkPalette.noteEdge).cgColor; paper.lineWidth = active ? 2 : 1
        paper.shadowColor = UIColor.black.cgColor; paper.shadowOpacity = 0.22; paper.shadowRadius = 3; paper.shadowOffset = CGSize(width: 0, height: 2)
        add(paper)
        let corner = CGMutablePath()
        corner.move(to: CGPoint(x: rect.maxX, y: rect.maxY - fold)); corner.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY - fold)); corner.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY)); corner.closeSubpath()
        let flap = CAShapeLayer(); flap.path = corner; flap.fillColor = InkPalette.noteEdge.cgColor
        add(flap)
        let text = "\(number)"
        let width = Self.caveatWidth(text, size: 25)
        let label = CAShapeLayer(); label.path = Self.caveat(text, size: 25, at: CGPoint(x: rect.midX - width / 2 - 1, y: rect.midY + 7)); label.fillColor = InkPalette.answer.cgColor
        add(label)
    }
    private func addHotspot(_ insight: PageInsight) {
        // A small coral mark in the top-right margin: "Halo thinks this page will trip you up."
        let text = "tricky: \(insight.topic.lowercased())"
        let width = Self.caveatWidth(text, size: 22)
        let origin = CGPoint(x: size.width - width - 60, y: 26)
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: origin.x, y: origin.y, width: 16, height: 16), transform: nil)
        dot.fillColor = InkPalette.circle.cgColor
        add(dot)
        let ring = CAShapeLayer(); ring.fillColor = UIColor.clear.cgColor; ring.strokeColor = InkPalette.circle.cgColor; ring.lineWidth = 2
        let pulse = CABasicAnimation(keyPath: "transform.scale"); pulse.fromValue = 1; pulse.toValue = 2.2; pulse.duration = 1.4; pulse.repeatCount = .infinity
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.7; fade.toValue = 0; fade.duration = 1.4; fade.repeatCount = .infinity
        ring.frame = CGRect(x: origin.x, y: origin.y, width: 16, height: 16); ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 16, height: 16), transform: nil)
        ring.add(pulse, forKey: "pulse"); ring.add(fade, forKey: "fade")
        add(ring)
        let backing = CAShapeLayer()
        backing.path = CGPath(roundedRect: CGRect(x: origin.x + 20, y: origin.y - 5, width: width + 12, height: 28), cornerWidth: 8, cornerHeight: 8, transform: nil)
        backing.fillColor = UIColor.white.withAlphaComponent(0.85).cgColor
        add(backing)
        let label = CAShapeLayer(); label.path = Self.caveat(text, size: 22, at: CGPoint(x: origin.x + 26, y: origin.y + 15)); label.fillColor = InkPalette.circle.cgColor
        add(label)
        hotspotFrame = CGRect(x: (origin.x - 10) * scale, y: (origin.y - 10) * scale, width: (width + 50) * scale, height: 40 * scale)
    }

    private static func caveatGlyphs(_ text: String, size: CGFloat) -> (CTFont, [CGGlyph], [CGSize]) {
        let font = CTFontCreateWithName("Caveat-Regular" as CFString, size, nil)
        let chars = Array(text.utf16); var glyphs = [CGGlyph](repeating: 0, count: chars.count); CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: chars.count); CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, chars.count)
        return (font, glyphs, advances)
    }
    static func caveatWidth(_ text: String, size: CGFloat) -> CGFloat { caveatGlyphs(text, size: size).2.reduce(0) { $0 + $1.width } }
    static func caveat(_ text: String, size: CGFloat, at origin: CGPoint) -> CGPath {
        let (font, glyphs, advances) = caveatGlyphs(text, size: size)
        let path = CGMutablePath(); var cursor = origin.x
        for (g, a) in zip(glyphs, advances) {
            if let gp = CTFontCreatePathForGlyph(font, g, nil) { let t = CGAffineTransform(translationX: cursor, y: origin.y).scaledBy(x: 1, y: -1); path.addPath(gp, transform: t) }
            cursor += a.width
        }
        return path
    }
}
