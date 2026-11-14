import UIKit
import PDFKit
import PencilKit

struct PDFCapture {
    let page: String
    let crop: String?
    let selectedText: String
    static func make(page: PDFPage, region: PageRegion?, lasso: [LassoPoint]? = nil, drawing: Data? = nil) throws -> PDFCapture {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { throw HaloError.unreadableDocument }
        // PDFKit handles PDF rotation. Both the crop and pins use displayed, top-left coordinates.
        let rotated = abs(page.rotation) % 180 != 0
        let displaySize = CGSize(width: rotated ? bounds.height : bounds.width, height: rotated ? bounds.width : bounds.height)
        let scale = 1600 / max(displaySize.width, displaySize.height)
        let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        var image = page.thumbnail(of: size, for: .cropBox)
        if let drawing, let ink = try? PKDrawing(data: drawing) {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let background = image
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                background.draw(in: CGRect(origin: .zero, size: size))
                ink.image(from: CGRect(origin: .zero, size: displaySize), scale: scale).draw(in: CGRect(origin: .zero, size: size))
            }
        }
        guard let full = image.jpegData(compressionQuality: 0.82), var cg = image.cgImage else { throw HaloError.unreadableDocument }
        guard let region else { return PDFCapture(page: full.base64EncodedString(), crop: nil, selectedText: "") }
        if let lasso, lasso.count > 2 {
            // The model sees exactly what the student drew: their orange circle on the page.
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let marked = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                image.draw(in: CGRect(origin: .zero, size: size))
                let c = ctx.cgContext
                c.setStrokeColor(UIColor(red: 1, green: 0.35, blue: 0.21, alpha: 1).cgColor); c.setLineWidth(max(3, size.width / 300)); c.setLineCap(.round); c.setLineJoin(.round)
                let pts = lasso.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                c.move(to: pts[0]); for p in pts.dropFirst() { c.addLine(to: p) }; c.strokePath()
            }
            if let marked = marked.cgImage { cg = marked }
        }
        let pad = 0.03
        let rect = CGRect(x: (region.x - pad) * Double(cg.width), y: (region.y - pad) * Double(cg.height), width: (region.width + pad * 2) * Double(cg.width), height: (region.height + pad * 2) * Double(cg.height)).integral
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !clipped.isEmpty, let cut = cg.cropping(to: clipped), let data = UIImage(cgImage: cut).jpegData(compressionQuality: 0.92) else { throw HaloError.unreadableDocument }
        // Vision receives the exact crop; full page text supplies context even for rotated PDFs.
        return PDFCapture(page: full.base64EncodedString(), crop: data.base64EncodedString(), selectedText: "")
    }
}

/// Finds printed text on a page so Halo can mark it while it talks ("this formula up here").
/// Matching ignores spacing, case and dash/quote variants, because PDF text extraction spaces math unpredictably.
enum PagePointer {
    static func find(_ quote: String, on page: PDFPage, near: PageRegion? = nil) -> [PageRegion] {
        guard abs(page.rotation) % 360 == 0, let text = page.string, !text.isEmpty else { return [] }
        let (hay, map) = fold(text as NSString)
        let words = quote.split(whereSeparator: \.isWhitespace)
        // The whole quote first; if the model paraphrased a little, either half of it.
        var tries = [quote]
        if words.count >= 4 {
            tries.append(words.prefix(words.count / 2 + 1).joined(separator: " "))
            tries.append(words.suffix(words.count / 2 + 1).joined(separator: " "))
        }
        for attempt in tries {
            let needle = fold(attempt as NSString).0
            guard needle.count >= 2 else { continue }
            let hits = occurrences(of: needle, in: hay).prefix(12).compactMap { start -> [PageRegion]? in
                let from = map[start], to = map[start + needle.count - 1]
                let regions = regionsOf(page.selection(for: NSRange(location: from, length: to - from + 1)), on: page)
                return regions.isEmpty ? nil : regions
            }
            guard !hits.isEmpty else { continue }
            // Several matches: the one nearest what the student circled.
            guard let near, hits.count > 1 else { return hits[0] }
            let cx = near.x + near.width / 2, cy = near.y + near.height / 2
            return hits.min { a, b in distance(a[0], cx, cy) < distance(b[0], cx, cy) }!
        }
        return []
    }

    private static func distance(_ r: PageRegion, _ x: Double, _ y: Double) -> Double {
        let dx = r.x + r.width / 2 - x, dy = r.y + r.height / 2 - y
        return dx * dx + dy * dy * 4     // being on the same line matters more
    }
    private static func regionsOf(_ selection: PDFSelection?, on page: PDFPage) -> [PageRegion] {
        guard let selection else { return [] }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return [] }
        return selection.selectionsByLine().prefix(4).compactMap { line in
            let b = line.bounds(for: page)
            return PageRegion(x: (b.minX - box.minX) / box.width, y: (box.maxY - b.maxY) / box.height, width: b.width / box.width, height: b.height / box.height)
        }
    }
    private static func occurrences(of needle: [UInt16], in hay: [UInt16]) -> [Int] {
        guard hay.count >= needle.count else { return [] }
        var out: [Int] = []
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if hay[i..<(i + needle.count)].elementsEqual(needle) { out.append(i) }
        }
        return out
    }
    /// Text without whitespace, lower-cased, with look-alike characters merged; plus where each unit came from.
    private static func fold(_ text: NSString) -> ([UInt16], [Int]) {
        var out: [UInt16] = [], map: [Int] = []
        out.reserveCapacity(text.length); map.reserveCapacity(text.length)
        for i in 0..<text.length {
            var c = text.character(at: i)
            if let scalar = Unicode.Scalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            switch c {
            case 0x2212, 0x2013, 0x2014, 0x2010, 0x2011: c = 0x2D                 // minus and dashes → -
            case 0x2018, 0x2019, 0x2032: c = 0x27                                  // ‘ ’ ′ → '
            case 0x201C, 0x201D, 0x2033: c = 0x22                                  // “ ” ″ → "
            case 0x00D7, 0x22C5, 0x00B7, 0x2219: c = 0x2A                          // × ⋅ · ∙ → *
            case 0xFB01: out += [0x66, 0x69]; map += [i, i]; continue              // ﬁ
            case 0xFB02: out += [0x66, 0x6C]; map += [i, i]; continue              // ﬂ
            case 0x41...0x5A: c += 0x20                                            // A-Z → a-z
            default: break
            }
            out.append(c); map.append(i)
        }
        return (out, map)
    }
}

/// The part of a page the student is working on right now, for "Halo watches you work".
struct WorkCapture {
    let image: String            // base64 JPEG: the printed problem above, and the working under it
    let crop: CGRect             // that image's place on the page, 0-1 from the top-left
    let work: PageRegion         // just the handwriting
    let signature: String        // changes whenever the working does

    /// Maps a box on the image back onto the page.
    func region(_ box: CheckBox) -> PageRegion? {
        PageRegion(x: crop.minX + box.x * crop.width, y: crop.minY + box.y * crop.height, width: box.w * crop.width, height: box.h * crop.height)
    }

    /// Finds the working around the most recent stroke: the lines written near it, one under another.
    static func make(page: PDFPage, drawing data: Data?) -> WorkCapture? {
        guard let data, let drawing = try? PKDrawing(data: data), let latest = drawing.strokes.last else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 != 0
        let display = CGSize(width: rotated ? bounds.height : bounds.width, height: rotated ? bounds.width : bounds.height)
        guard display.width > 0, display.height > 0 else { return nil }
        // Grow outwards from the newest stroke: anything within a line or so belongs to the same piece of working.
        var cluster = latest.renderBounds, members = 1
        var rest = drawing.strokes.dropLast().map(\.renderBounds)
        var grew = true
        while grew {
            grew = false
            let reach = cluster.insetBy(dx: -display.width * 0.12, dy: -display.height * 0.04)
            rest.removeAll { box in
                guard reach.intersects(box) else { return false }
                cluster = cluster.union(box); members += 1; grew = true
                return true
            }
        }
        cluster = cluster.intersection(CGRect(origin: .zero, size: display))
        // A dot or a stray tick is not working.
        guard members >= 3, cluster.width > display.width * 0.04,
              let work = PageRegion(x: cluster.minX / display.width, y: cluster.minY / display.height, width: cluster.width / display.width, height: cluster.height / display.height) else { return nil }
        // Look above the handwriting for the printed problem it starts from, and take the page's full width.
        let top = max(0, cluster.minY - display.height * 0.115), bottom = min(display.height, cluster.maxY + display.height * 0.025)
        let left = display.width * 0.02, right = min(display.width, max(cluster.maxX + display.width * 0.06, display.width * 0.72))
        let crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let scale = min(3.2, 1500 / crop.width)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: crop.width * scale, height: crop.height * scale)
        let full = CGSize(width: display.width * scale, height: display.height * scale)
        let printed = page.thumbnail(of: full, for: .cropBox)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let origin = CGPoint(x: -crop.minX * scale, y: -crop.minY * scale)
            printed.draw(in: CGRect(origin: origin, size: full))
            drawing.image(from: CGRect(origin: .zero, size: display), scale: scale).draw(in: CGRect(origin: origin, size: full))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let r = { (v: CGFloat) in Int(v.rounded()) }
        return WorkCapture(image: jpeg.base64EncodedString(),
                           crop: CGRect(x: crop.minX / display.width, y: crop.minY / display.height, width: crop.width / display.width, height: crop.height / display.height),
                           work: work,
                           signature: "\(members)|\(r(cluster.minX)),\(r(cluster.minY)),\(r(cluster.maxX)),\(r(cluster.maxY))|\(r(latest.renderBounds.midX)),\(r(latest.renderBounds.midY))")
    }

    /// A loose hand-drawn ring around a line, the way a tutor circles a slip: it overshoots where it started.
    static func ring(around region: PageRegion, aspect: Double) -> (lasso: [LassoPoint], region: PageRegion)? {
        let padX = 0.022, padY = max(0.007, region.height * 0.4) + 0.004 / max(0.5, aspect)
        guard let outer = PageRegion(x: region.x - padX, y: region.y - padY, width: region.width + padX * 2, height: region.height + padY * 2) else { return nil }
        let cx = outer.x + outer.width / 2, cy = outer.y + outer.height / 2
        let lasso = (0...46).map { i -> LassoPoint in
            let t = Double(i) / 42, angle = -2.5 + t * 2 * .pi
            let wobble = 1 + 0.035 * sin(t * 9.4) - 0.03 * t
            return LassoPoint(x: min(1, max(0, cx + cos(angle) * outer.width / 2 * wobble)), y: min(1, max(0, cy + sin(angle) * outer.height / 2 * wobble)))
        }
        return (lasso, outer)
    }
}

/// Stands in for the Pencil in scripted runs (`--write`): a few stick-figure characters, enough to write out algebra.
enum WorkScript {
    private static let glyphs: [Character: [[(Double, Double)]]] = [
        "0": [[(0.5, 0), (0.15, 0.25), (0.12, 0.7), (0.5, 1), (0.85, 0.72), (0.88, 0.28), (0.5, 0)]],
        "1": [[(0.25, 0.25), (0.55, 0), (0.55, 1)]],
        "2": [[(0.12, 0.25), (0.32, 0.03), (0.68, 0.03), (0.88, 0.27), (0.75, 0.52), (0.1, 1), (0.92, 1)]],
        "3": [[(0.12, 0.1), (0.5, 0), (0.85, 0.22), (0.48, 0.48), (0.88, 0.74), (0.5, 1), (0.1, 0.9)]],
        "4": [[(0.72, 1), (0.72, 0), (0.08, 0.66), (0.95, 0.66)]],
        "5": [[(0.85, 0), (0.22, 0), (0.16, 0.45), (0.56, 0.4), (0.88, 0.66), (0.6, 1), (0.12, 0.9)]],
        "6": [[(0.8, 0.05), (0.4, 0.1), (0.14, 0.55), (0.3, 0.97), (0.7, 0.97), (0.86, 0.68), (0.55, 0.48), (0.18, 0.62)]],
        "7": [[(0.1, 0), (0.9, 0), (0.42, 1)]],
        "8": [[(0.5, 0.48), (0.2, 0.25), (0.5, 0), (0.8, 0.25), (0.5, 0.48), (0.14, 0.75), (0.5, 1), (0.86, 0.75), (0.5, 0.48)]],
        "9": [[(0.86, 0.3), (0.5, 0), (0.15, 0.26), (0.48, 0.52), (0.86, 0.3), (0.8, 1)]],
        "x": [[(0.12, 0.38), (0.9, 1)], [(0.9, 0.38), (0.1, 1)]],
        "=": [[(0.1, 0.5), (0.9, 0.5)], [(0.1, 0.78), (0.9, 0.78)]],
        "+": [[(0.1, 0.64), (0.9, 0.64)], [(0.5, 0.36), (0.5, 0.92)]],
        "-": [[(0.12, 0.64), (0.88, 0.64)]],
        "(": [[(0.7, -0.05), (0.35, 0.3), (0.35, 0.75), (0.7, 1.08)]],
        ")": [[(0.3, -0.05), (0.65, 0.3), (0.65, 0.75), (0.3, 1.08)]],
    ]
    /// Adds one line of writing to a drawing. `origin` is the top-left of the line in page points.
    static func write(_ text: String, at origin: CGPoint, height: CGFloat, onto data: Data?) -> Data {
        var drawing = data.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        let ink = PKInk(.pen, color: UIColor(red: 0.16, green: 0.16, blue: 0.22, alpha: 1))
        var x = origin.x
        let width = height * 0.6
        for character in text {
            defer { x += character == " " ? width * 0.55 : width * 1.25 }
            for polyline in glyphs[character] ?? [] {
                let points = polyline.enumerated().map { index, p in
                    PKStrokePoint(location: CGPoint(x: x + p.0 * width, y: origin.y + p.1 * height), timeOffset: Double(index) * 0.02,
                                  size: CGSize(width: 2.2, height: 2.2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                drawing.strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
        }
        return drawing.dataRepresentation()
    }
}
