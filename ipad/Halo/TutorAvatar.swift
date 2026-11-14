import SwiftUI
import os

/// How Halo, the lesson tutor, is feeling right now. Drives the avatar's face, glow and motion.
enum TutorMood: Equatable {
    case idle, attentive, thinking, speaking, listening, happy, unsure

    var label: String {
        switch self {
        case .idle: return "Halo is here"
        case .attentive: return "Halo is reading along"
        case .thinking: return "Halo is thinking"
        case .speaking: return "Halo is explaining"
        case .listening: return "Halo is listening"
        case .happy: return "Halo is delighted"
        case .unsure: return "Halo wants another look"
        }
    }
    var tint: Color {
        switch self {
        case .thinking: return HaloStyle.ink
        case .listening: return Color(red: 0.1, green: 0.62, blue: 0.62)
        case .happy: return HaloKit.leaf
        case .unsure: return HaloKit.amber
        default: return HaloStyle.coral
        }
    }
}

/// Everything the avatar needs to decide its mood frame by frame, so speech and reactions can
/// expire on their own without the coach scheduling timers.
struct TutorCue: Equatable {
    var base: TutorMood = .idle
    var speakingUntil = Date.distantPast
    var reaction: TutorMood?
    var reactionUntil = Date.distantPast

    func mood(at now: Date) -> TutorMood {
        if base == .listening { return .listening }
        if let reaction, now < reactionUntil { return reaction }
        if now < speakingUntil { return .speaking }
        return base
    }
}

/// A thread-safe audio level (0…1), written from the audio thread and read by the avatar each frame.
final class LevelMeter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Float(0))
    var value: Float {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// Halo as a living character: a glowing orb with a floating halo ring, a face that blinks, looks
/// around, and talks in time with the voice, ripples while it listens and orbits sparks while it thinks.
struct TutorAvatar: View {
    var cue: TutorCue
    var size: CGFloat = 140
    /// The voice's loudness (nil when there is no meter, e.g. system speech: the mouth then animates on its own).
    var voiceLevel: () -> CGFloat? = { nil }
    /// The microphone's loudness while listening.
    var micLevel: () -> CGFloat = { 0 }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let now = timeline.date
            let mood = cue.mood(at: now)
            Canvas { context, canvas in
                draw(in: &context, size: canvas, t: reduceMotion ? 0 : now.timeIntervalSinceReferenceDate, mood: mood)
            }
            .accessibilityLabel(mood.label)
        }
        .frame(width: size, height: size * 1.12)
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
    }

    private func speakingLevel(_ t: Double) -> CGFloat {
        if let measured = voiceLevel() { return max(0.08, measured) }
        // Syllable-like jaw motion for voices without a meter.
        let syllables = abs(sin(t * 10.5)) * 0.55 + abs(sin(t * 6.7 + 1.3)) * 0.35
        let phrase = 0.65 + 0.35 * sin(t * 1.7)
        return CGFloat(syllables * phrase)
    }

    private func draw(in context: inout GraphicsContext, size canvas: CGSize, t: Double, mood: TutorMood) {
        let s = min(canvas.width, canvas.height / 1.12)
        let bob = CGFloat(sin(t * 1.6)) * s * 0.018 + (mood == .happy ? CGFloat(abs(sin(t * 7))) * -s * 0.03 : 0)
        let center = CGPoint(x: canvas.width / 2, y: canvas.height * 0.56 + bob)
        let talk: CGFloat = mood == .speaking ? speakingLevel(t) : 0
        let mic = mood == .listening ? min(1, micLevel() * 1.4) : 0
        let breathe = 1 + CGFloat(sin(t * 2.1)) * 0.015
        let r = s * 0.34 * breathe * (1 + talk * 0.035 + mic * 0.05)
        let tint = mood.tint

        // Ground shadow, shrinking as the orb floats up.
        let shadowWidth = r * (1.25 - bob / (s * 0.1))
        context.fill(Path(ellipseIn: CGRect(x: canvas.width / 2 - shadowWidth / 2, y: canvas.height * 0.56 + r * 1.08, width: shadowWidth, height: r * 0.16)),
                     with: .color(.black.opacity(0.09)))

        // Aura.
        let aura = r * (1.55 + 0.06 * CGFloat(sin(t * 2.4)) + talk * 0.18 + mic * 0.35)
        context.fill(Path(ellipseIn: CGRect(x: center.x - aura, y: center.y - aura, width: aura * 2, height: aura * 2)),
                     with: .radialGradient(Gradient(colors: [tint.opacity(0.32), tint.opacity(0.1), tint.opacity(0)]), center: center, startRadius: r * 0.6, endRadius: aura))

        // Listening: ripples that ride the microphone level.
        if mood == .listening {
            for i in 0..<3 {
                let phase = (t * 0.8 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let rr = r * (1.05 + CGFloat(phase) * (0.7 + mic * 0.6))
                context.stroke(Path(ellipseIn: CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)),
                               with: .color(tint.opacity((1 - phase) * 0.5)), lineWidth: max(1.5, s * 0.012))
            }
        }

        // The orb: a deep gradient with soft colour blobs drifting inside, then a glassy highlight.
        let orb = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        let angle = t * 0.35
        context.fill(orb, with: .linearGradient(
            Gradient(colors: [HaloStyle.ink, Color(red: 0.48, green: 0.24, blue: 0.86), HaloStyle.coral]),
            startPoint: CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r),
            endPoint: CGPoint(x: center.x - CGFloat(cos(angle)) * r, y: center.y - CGFloat(sin(angle)) * r)))
        context.drawLayer { layer in
            layer.clip(to: orb)
            layer.addFilter(.blur(radius: r * 0.28))
            let blobs: [(Color, Double, Double, CGFloat)] = [
                (HaloStyle.coral, 0.9, 0.0, 0.62), (Color(red: 1, green: 0.72, blue: 0.4), 0.6, 2.1, 0.45),
                (Color(red: 0.35, green: 0.5, blue: 1), 0.75, 4.2, 0.55), (tint, 1.1, 1.0, 0.4)
            ]
            for (color, speed, offset, scale) in blobs {
                let p = CGPoint(x: center.x + CGFloat(cos(t * speed + offset)) * r * 0.5, y: center.y + CGFloat(sin(t * speed * 1.3 + offset)) * r * 0.5)
                let br = r * scale
                layer.fill(Path(ellipseIn: CGRect(x: p.x - br, y: p.y - br, width: br * 2, height: br * 2)), with: .color(color.opacity(0.75)))
            }
        }
        context.fill(Path(ellipseIn: CGRect(x: center.x - r * 0.62, y: center.y - r * 0.82, width: r * 0.9, height: r * 0.5)),
                     with: .linearGradient(Gradient(colors: [.white.opacity(0.45), .white.opacity(0)]), startPoint: CGPoint(x: center.x, y: center.y - r * 0.82), endPoint: CGPoint(x: center.x, y: center.y - r * 0.32)))
        context.stroke(orb, with: .color(.white.opacity(0.25)), lineWidth: max(1, s * 0.008))

        drawHalo(in: &context, center: center, r: r, t: t, mood: mood)
        drawFace(in: &context, center: center, r: r, t: t, mood: mood, talk: talk)

        // Thinking: sparks orbiting the orb.
        if mood == .thinking {
            for i in 0..<3 {
                let a = t * 2.2 + Double(i) * 2.09
                let p = CGPoint(x: center.x + CGFloat(cos(a)) * r * 1.35, y: center.y + CGFloat(sin(a)) * r * 0.5 - r * 0.15)
                let dot = r * (0.07 + 0.03 * CGFloat(sin(a * 2)))
                context.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2)), with: .color(HaloStyle.coral.opacity(0.85)))
            }
        }
    }

    private func drawHalo(in context: inout GraphicsContext, center: CGPoint, r: CGFloat, t: Double, mood: TutorMood) {
        let float = CGFloat(sin(t * 1.6 + 0.8)) * r * 0.05
        let tilt = mood == .unsure ? -0.16 : CGFloat(sin(t * 0.9)) * 0.06
        let rect = CGRect(x: -r * 0.72, y: -r * 0.17, width: r * 1.44, height: r * 0.34)
        var ring = context
        ring.translateBy(x: center.x, y: center.y - r * 1.22 + float)
        ring.rotate(by: .radians(tilt))
        let spin = mood == .thinking ? t * 6 : t * 0.8
        let glow = mood == .happy || mood == .speaking ? 0.55 : 0.3
        ring.stroke(Path(ellipseIn: rect), with: .color(HaloStyle.coral.opacity(glow)), lineWidth: r * 0.2)
        ring.stroke(Path(ellipseIn: rect), with: .conicGradient(
            Gradient(colors: [HaloStyle.coral, Color(red: 1, green: 0.78, blue: 0.45), .white, HaloStyle.coral]),
            center: .zero, angle: .radians(spin)), lineWidth: r * 0.09)
    }

    private func drawFace(in context: inout GraphicsContext, center: CGPoint, r: CGFloat, t: Double, mood: TutorMood, talk: CGFloat) {
        // Where the eyes look.
        var gaze: CGPoint
        switch mood {
        case .thinking: gaze = CGPoint(x: 0.14 + 0.04 * sin(t * 1.3), y: -0.13)
        case .attentive: gaze = CGPoint(x: 0.02 * sin(t * 0.8), y: 0.12)
        case .listening, .speaking, .happy: gaze = CGPoint(x: 0.03 * sin(t * 0.7), y: 0)
        default: gaze = CGPoint(x: 0.1 * sin(t * 0.43), y: 0.05 * sin(t * 0.31))
        }
        gaze = CGPoint(x: gaze.x * r, y: gaze.y * r)
        let faceTilt = mood == .unsure ? -0.1 : 0.0
        var face = context
        face.translateBy(x: center.x, y: center.y)
        face.rotate(by: .radians(faceTilt))

        // Blink every few seconds, sometimes twice.
        let cycle = t.truncatingRemainder(dividingBy: 4.3)
        let blinking = cycle < 0.13 || (Int(t / 4.3) % 3 == 0 && cycle > 0.3 && cycle < 0.43)
        let open: CGFloat = blinking ? 0.12 : (mood == .thinking ? 0.75 : mood == .listening ? 1.12 : 1)
        let eyeW = r * 0.17, eyeH = r * 0.27 * open
        let eyeY = -r * 0.1 + gaze.y
        let white = GraphicsContext.Shading.color(.white)
        for side in [-1.0, 1.0] {
            let x = CGFloat(side) * r * 0.32 + gaze.x
            if mood == .happy {
                var arc = Path()
                arc.move(to: CGPoint(x: x - eyeW * 0.75, y: eyeY + eyeW * 0.2))
                arc.addQuadCurve(to: CGPoint(x: x + eyeW * 0.75, y: eyeY + eyeW * 0.2), control: CGPoint(x: x, y: eyeY - eyeW * 1.1))
                face.stroke(arc, with: white, style: StrokeStyle(lineWidth: r * 0.075, lineCap: .round))
            } else {
                face.fill(Path(roundedRect: CGRect(x: x - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: max(r * 0.03, eyeH)), cornerRadius: eyeW / 2), with: white)
            }
            if mood == .unsure || mood == .thinking {
                var brow = Path()
                let lift = mood == .unsure ? CGFloat(side) * r * 0.05 : -r * 0.03
                brow.move(to: CGPoint(x: x - eyeW * 0.8, y: eyeY - r * 0.25 + lift))
                brow.addLine(to: CGPoint(x: x + eyeW * 0.8, y: eyeY - r * 0.25 - lift))
                face.stroke(brow, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: r * 0.05, lineCap: .round))
            }
        }

        // Cheeks.
        if mood == .happy || mood == .speaking {
            for side in [-1.0, 1.0] {
                let rect = CGRect(x: CGFloat(side) * r * 0.55 - r * 0.12, y: r * 0.12, width: r * 0.24, height: r * 0.12)
                face.fill(Path(ellipseIn: rect), with: .color(Color(red: 1, green: 0.6, blue: 0.6).opacity(0.55)))
            }
        }

        // Mouth.
        let mouthY = r * 0.3 + gaze.y * 0.4
        let mx = gaze.x * 0.5
        switch mood {
        case .speaking:
            let w = r * (0.26 + talk * 0.06), h = r * (0.05 + talk * 0.24)
            face.fill(Path(roundedRect: CGRect(x: mx - w / 2, y: mouthY - h / 2, width: w, height: h), cornerRadius: min(w, h) / 2), with: white)
        case .happy:
            var smile = Path()
            smile.move(to: CGPoint(x: mx - r * 0.24, y: mouthY - r * 0.05))
            smile.addQuadCurve(to: CGPoint(x: mx + r * 0.24, y: mouthY - r * 0.05), control: CGPoint(x: mx, y: mouthY + r * 0.32))
            smile.closeSubpath()
            face.fill(smile, with: white)
        case .thinking:
            let o = r * 0.09
            face.fill(Path(ellipseIn: CGRect(x: mx + r * 0.08 - o / 2, y: mouthY - o / 2, width: o, height: o * 1.1)), with: white)
        case .unsure:
            var wave = Path()
            wave.move(to: CGPoint(x: mx - r * 0.18, y: mouthY))
            wave.addCurve(to: CGPoint(x: mx + r * 0.18, y: mouthY), control1: CGPoint(x: mx - r * 0.06, y: mouthY - r * 0.07), control2: CGPoint(x: mx + r * 0.06, y: mouthY + r * 0.07))
            face.stroke(wave, with: white, style: StrokeStyle(lineWidth: r * 0.055, lineCap: .round))
        case .listening:
            let o = r * 0.12
            face.fill(Path(ellipseIn: CGRect(x: mx - o / 2, y: mouthY - o * 0.4, width: o, height: o * 0.8)), with: white)
        default:
            var smile = Path()
            smile.move(to: CGPoint(x: mx - r * 0.16, y: mouthY - r * 0.02))
            smile.addQuadCurve(to: CGPoint(x: mx + r * 0.16, y: mouthY - r * 0.02), control: CGPoint(x: mx, y: mouthY + r * 0.13))
            face.stroke(smile, with: white, style: StrokeStyle(lineWidth: r * 0.06, lineCap: .round))
        }
    }
}

/// A burst of confetti that fires each time `trigger` changes.
struct ConfettiBurst: View {
    var trigger: Int
    @State private var start: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let colors: [Color] = [HaloStyle.coral, HaloStyle.ink, HaloKit.highlight, HaloKit.leaf, Color(red: 0.48, green: 0.24, blue: 0.86)]
    private static func noise(_ seed: Double, _ k: Double) -> Double {
        let v: Double = sin(seed * k) * 43758.5453
        return v.truncatingRemainder(dividingBy: 1).magnitude
    }
    var body: some View {
        TimelineView(.animation(paused: start == nil)) { timeline in
            Canvas { context, size in
                guard let start else { return }
                let elapsed = timeline.date.timeIntervalSince(start)
                guard elapsed < 2.4 else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.45)
                for i in 0..<70 {
                    // Deterministic pseudo-random per particle.
                    let seed: Double = Double(i) * 12.9898
                    let angle: Double = Self.noise(seed, 1.1) * .pi * 2
                    let speed: Double = 180 + Self.noise(seed, 2.3) * 320
                    let dx: Double = cos(angle) * speed * elapsed
                    let rise: Double = sin(angle) * speed * elapsed - 120 * elapsed
                    let fall: Double = 420 * elapsed * elapsed
                    let x = origin.x + CGFloat(dx)
                    let y = origin.y + CGFloat(rise + fall)
                    var piece = context
                    piece.opacity = max(0, 1 - elapsed / 2.4)
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(elapsed * (4 + Self.noise(seed, 3.7) * 8)))
                    let w: CGFloat = 5 + CGFloat(Self.noise(seed, 4.1)) * 6
                    piece.fill(Path(roundedRect: CGRect(x: -w / 2, y: -w * 0.3, width: w, height: w * 0.6), cornerRadius: 1.5),
                               with: .color(Self.colors[i % Self.colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in if !reduceMotion { start = Date() } }
    }
}

/// What Halo is saying, in a speech bubble. Words light up as they're spoken, karaoke-style.
struct TutorBubble: View {
    var text: String
    var spokenAt: Date
    var duration: TimeInterval
    var cue: TutorCue
    var fontSize: CGFloat = 22
    var tail: Edge = .leading
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let now = timeline.date
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            let progress = duration <= 0 ? 1 : min(1, max(0, now.timeIntervalSince(spokenAt) / duration))
            let lit = Int((Double(words.count) * progress).rounded(.up))
            let mood = cue.mood(at: now)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle().fill(mood.tint).frame(width: 8, height: 8)
                        .scaleEffect(mood == .idle || mood == .attentive ? 1 : 1 + 0.35 * CGFloat(abs(sin(now.timeIntervalSinceReferenceDate * 4))))
                    Text(mood.label.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1.3).foregroundStyle(mood.tint)
                }
                karaoke(words, lit: lit)
                    .font(.system(size: fontSize, design: .serif)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(text)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(BubbleShape(tail: tail).fill(Color.white).shadow(color: HaloStyle.ink.opacity(0.12), radius: 16, y: 8))
    }
    private func karaoke(_ words: [Substring], lit: Int) -> Text {
        let said: String = words.prefix(lit).joined(separator: " ")
        let rest: String = words.dropFirst(lit).joined(separator: " ")
        let gap: String = lit > 0 && lit < words.count ? " " : ""
        let first: Text = Text(said).foregroundColor(HaloStyle.text)
        let second: Text = Text(gap + rest).foregroundColor(HaloStyle.text.opacity(0.18))
        return first + second
    }
}

/// A rounded bubble with a small tail pointing at the avatar.
struct BubbleShape: Shape {
    var tail: Edge = .leading
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 22, style: .continuous)
        var t = Path()
        switch tail {
        case .top:
            t.move(to: CGPoint(x: rect.midX - 14, y: rect.minY + 1)); t.addLine(to: CGPoint(x: rect.midX, y: rect.minY - 13)); t.addLine(to: CGPoint(x: rect.midX + 14, y: rect.minY + 1))
        default:
            let y = min(rect.maxY - 30, rect.minY + 46)
            t.move(to: CGPoint(x: rect.minX + 1, y: y - 12)); t.addLine(to: CGPoint(x: rect.minX - 13, y: y + 2)); t.addLine(to: CGPoint(x: rect.minX + 1, y: y + 12))
        }
        t.closeSubpath()
        path.addPath(t)
        return path
    }
}
