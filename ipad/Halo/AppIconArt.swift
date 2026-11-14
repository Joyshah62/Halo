import SwiftUI

// Halo's icon: the character itself, on the desk paper, with its coral halo.
// `--export-icons <folder>` renders every size from this one drawing, so the icon always matches the app.

/// The full icon: a square of warm paper with Halo in the middle. iOS rounds the corners itself.
struct AppIconArt: View {
    var side: CGFloat = 1024
    var body: some View {
        ZStack {
            HaloStyle.paper
            // Light falling on the desk, warmest where Halo sits.
            RadialGradient(colors: [.white, .white.opacity(0)], center: UnitPoint(x: 0.5, y: 0.46), startRadius: 0, endRadius: side * 0.62)
            RadialGradient(colors: [HaloStyle.coral.opacity(0.22), HaloStyle.coral.opacity(0)], center: UnitPoint(x: 0.5, y: 0.5), startRadius: side * 0.08, endRadius: side * 0.5)
            IconCharacter(size: side * 0.84).offset(y: side * 0.035)
        }
        .frame(width: side, height: side)
    }
}

/// For browser tabs and toolbars: Halo drawn simply (body, halo, eyes; no glow, arms or shadow) on a clear
/// background, so it reads at 16 px and sits on light and dark toolbars alike.
struct IconMark: View {
    var side: CGFloat
    private static let bodyTop = Color(red: 0.40, green: 0.38, blue: 0.98)
    private static let bodyBottom = Color(red: 0.20, green: 0.15, blue: 0.72)
    private static let dark = Color(red: 0.09, green: 0.07, blue: 0.30)
    var body: some View {
        Canvas { context, size in
            let s = size.width
            // The body: a rounded dome, a little narrower than the square.
            let body = CGRect(x: s * 0.1, y: s * 0.33, width: s * 0.8, height: s * 0.65)
            let dome = Path(roundedRect: body, cornerSize: CGSize(width: body.width * 0.46, height: body.height * 0.52), style: .continuous)
            context.fill(dome, with: .linearGradient(Gradient(colors: [Self.bodyTop, Self.bodyBottom]), startPoint: CGPoint(x: s / 2, y: body.minY), endPoint: CGPoint(x: s / 2, y: body.maxY)))
            // The halo, tilted toward us.
            let ring = max(1.6, s * 0.085)
            context.stroke(Path(ellipseIn: CGRect(x: s * 0.2, y: s * 0.05, width: s * 0.6, height: s * 0.19)), with: .color(HaloStyle.coral), lineWidth: ring)
            // Eyes: happy arcs when there is room for them, bright dots when there isn't.
            let eyeY = body.minY + body.height * 0.38
            for dx in [-0.17, 0.17] as [CGFloat] {
                let x = s / 2 + dx * s
                if s < 30 {
                    let r = max(1.5, s * 0.075)
                    context.fill(Path(ellipseIn: CGRect(x: x - r, y: eyeY - r, width: r * 2, height: r * 2)), with: .color(.white))
                } else {
                    var arc = Path()
                    arc.addArc(center: CGPoint(x: x, y: eyeY + s * 0.04), radius: s * 0.075, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                    context.stroke(arc, with: .color(.white), style: StrokeStyle(lineWidth: max(2, s * 0.05), lineCap: .round))
                }
            }
            // A smile once it can be seen.
            if s >= 44 {
                var smile = Path()
                smile.addArc(center: CGPoint(x: s / 2, y: eyeY + s * 0.1), radius: s * 0.075, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                context.fill(smile, with: .color(Self.dark))
            }
        }
        .frame(width: side, height: side)
    }
}

/// The character, still, in its happy pose: eyes open, smiling, halo on.
private struct IconCharacter: View {
    let size: CGFloat
    var body: some View {
        TutorAvatar(cue: TutorCue(base: .happy), size: size, still: 0)
            .frame(width: size, height: size * 1.12)
    }
}

enum AppIconExport {
    /// Writes the app icon and the browser icons into `folder` (a path on the Mac when run in the simulator).
    @MainActor static func run(into folder: String) {
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        func save<V: View>(_ view: V, _ name: String, side: CGFloat, opaque: Bool) {
            let renderer = ImageRenderer(content: view.frame(width: side, height: side).environment(\.colorScheme, .light))
            renderer.scale = 1; renderer.isOpaque = opaque
            guard let image = renderer.uiImage, let data = image.pngData() else { print("icon: could not render \(name)"); return }
            do { try data.write(to: base.appendingPathComponent(name)); print("icon: wrote \(name)") } catch { print("icon: \(name): \(error)") }
        }
        save(AppIconArt(side: 1024), "icon-1024.png", side: 1024, opaque: true)
        save(AppIconArt(side: 512), "icon-512.png", side: 512, opaque: true)
        save(AppIconArt(side: 180), "apple-touch-icon.png", side: 180, opaque: true)
        for side in [16, 32, 48, 64, 128, 256] as [CGFloat] { save(IconMark(side: side), "mark-\(Int(side)).png", side: side, opaque: false) }
    }
}
