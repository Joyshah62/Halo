import SwiftUI
import os

/// How Halo, the lesson tutor, is feeling right now. Drives the avatar's face, glow and motion.
enum TutorMood: Equatable {
    case idle, attentive, thinking, speaking, listening, happy, unsure
    /// The companion's extra moods: dozing when nothing has happened for a while, beaming with sparkles
    /// after the student gets something right, and a wink when it is tapped.
    case sleepy, proud, wink
    /// Smiling moods share a face.
    var joyful: Bool { self == .happy || self == .proud }

    var label: String {
        switch self {
        case .idle: return "Halo is here"
        case .attentive: return "Halo is reading along"
        case .thinking: return "Halo is thinking"
        case .speaking: return "Halo is explaining"
        case .listening: return "Halo is listening"
        case .happy: return "Halo is delighted"
        case .unsure: return "Halo wants another look"
        case .sleepy: return "Halo is dozing. Tap to wake it"
        case .proud: return "Halo is proud of you"
        case .wink: return "Halo is here"
        }
    }
    var tint: Color {
        switch self {
        case .thinking: return HaloStyle.ink
        case .listening: return Color(red: 0.1, green: 0.62, blue: 0.62)
        case .happy, .proud: return HaloKit.leaf
        case .unsure: return HaloKit.amber
        case .sleepy: return Color(red: 0.45, green: 0.45, blue: 0.75)
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
    /// When an idle Halo nods off (the companion only; nil keeps it awake).
    var sleepAt: Date?

    func mood(at now: Date) -> TutorMood {
        if base == .listening { return .listening }
        if let reaction, now < reactionUntil { return reaction }
        if now < speakingUntil { return .speaking }
        if base == .idle, let sleepAt, now > sleepAt { return .sleepy }
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

/// Halo as a character: a small ink-blue creature under a floating coral halo. It has eyes that look around
/// and blink, a mouth that moves with the voice, and two stubby arms that do the talking for it: a hand to
/// its chin while it thinks, cupped to its ear while it listens, a pencil while it watches you write,
/// both arms up when you get something right. Drawn flat, in the app's own ink and coral, so it belongs on the paper.
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

    private static let bodyTop = Color(red: 0.40, green: 0.38, blue: 0.98)
    private static let bodyBottom = Color(red: 0.20, green: 0.15, blue: 0.72)
    private static let limb = Color(red: 0.27, green: 0.23, blue: 0.86)
    private static let dark = Color(red: 0.09, green: 0.07, blue: 0.30)
    private static let blush = Color(red: 1.0, green: 0.52, blue: 0.5)

    private func speakingLevel(_ t: Double) -> CGFloat {
        if let measured = voiceLevel() { return max(0.08, measured) }
        // Syllable-like jaw motion for voices without a meter.
        let syllables = abs(sin(t * 10.5)) * 0.55 + abs(sin(t * 6.7 + 1.3)) * 0.35
        let phrase = 0.65 + 0.35 * sin(t * 1.7)
        return CGFloat(syllables * phrase)
    }

    private func draw(in context: inout GraphicsContext, size canvas: CGSize, t: Double, mood: TutorMood) {
        let s = min(canvas.width, canvas.height / 1.12)
        let talk: CGFloat = mood == .speaking ? speakingLevel(t) : 0
        let mic = mood == .listening ? min(1, micLevel() * 1.4) : 0
        let tint = mood.tint
        // Floating: slow when dozing, a bounce when delighted.
        let hop = mood.joyful ? CGFloat(abs(sin(t * 6.5))) : 0
        let bob = CGFloat(sin(t * (mood == .sleepy ? 0.8 : 1.6))) * s * 0.016 - hop * s * 0.045
        let ground = canvas.height * 0.56 + s * 0.33
        let center = CGPoint(x: canvas.width / 2, y: canvas.height * 0.56 + bob)
        // Squash and stretch: breathing, a little with each syllable, and on the way down from a hop.
        let breathe = CGFloat(sin(t * (mood == .sleepy ? 1.1 : 2.1))) * (mood == .sleepy ? 0.022 : 0.012)
        let squash = breathe + talk * 0.02 + mic * 0.03 + (mood.joyful ? (0.5 - hop) * 0.05 : 0)
        let bw = s * 0.62 * (1 + squash), bh = s * 0.60 * (1 - squash)
        let a = bw / 2, top = -bh * 0.52, bottom = bh * 0.48

        // Shadow on the desk, smaller while it is in the air.
        let lift = (ground - (center.y + bottom)) / (s * 0.1)
        let shadowWidth = bw * (0.82 - min(0.3, max(0, lift) * 0.12))
        context.fill(Path(ellipseIn: CGRect(x: canvas.width / 2 - shadowWidth / 2, y: ground + s * 0.035, width: shadowWidth, height: s * 0.05)), with: .color(.black.opacity(0.10)))

        // A soft glow in the colour of the mood.
        let aura = s * (0.52 + 0.02 * CGFloat(sin(t * 2.4)) + talk * 0.05 + mic * 0.1)
        context.fill(Path(ellipseIn: CGRect(x: center.x - aura, y: center.y - aura, width: aura * 2, height: aura * 2)),
                     with: .radialGradient(Gradient(colors: [tint.opacity(0.24), tint.opacity(0.07), tint.opacity(0)]), center: center, startRadius: s * 0.2, endRadius: aura))

        // Listening: ripples that ride the microphone level.
        if mood == .listening {
            for i in 0..<3 {
                let phase = (t * 0.8 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let rr = s * (0.36 + CGFloat(phase) * (0.2 + mic * 0.16))
                context.stroke(Path(ellipseIn: CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)),
                               with: .color(tint.opacity((1 - phase) * 0.45)), lineWidth: max(1.5, s * 0.012))
            }
        }

        // Everything below is drawn in the creature's own space, so the whole of it can lean.
        let lean: CGFloat = mood == .unsure ? -0.09 : mood == .listening ? 0.07 : mood == .thinking ? -0.04 : mood == .sleepy ? 0.05 + 0.02 * CGFloat(sin(t * 0.8)) : CGFloat(sin(t * 0.9)) * 0.02
        var g = context
        g.translateBy(x: center.x, y: center.y)
        g.rotate(by: .radians(lean))

        // Feet.
        for side in [-1.0, 1.0] {
            let step = mood.joyful ? CGFloat(sin(t * 6.5 + side)) * s * 0.012 : 0
            g.fill(Path(ellipseIn: CGRect(x: CGFloat(side) * a * 0.42 - s * 0.075, y: bottom - s * 0.035 + step, width: s * 0.15, height: s * 0.085)), with: .color(Self.bodyBottom))
        }

        // The body: a rounded drop, a little wider at the bottom.
        var body = Path()
        body.move(to: CGPoint(x: 0, y: top))
        body.addCurve(to: CGPoint(x: a, y: bh * 0.08), control1: CGPoint(x: a * 0.66, y: top), control2: CGPoint(x: a, y: top + bh * 0.26))
        body.addCurve(to: CGPoint(x: a * 0.66, y: bottom), control1: CGPoint(x: a, y: bh * 0.36), control2: CGPoint(x: a * 0.94, y: bottom))
        body.addQuadCurve(to: CGPoint(x: -a * 0.66, y: bottom), control: CGPoint(x: 0, y: bottom + bh * 0.05))
        body.addCurve(to: CGPoint(x: -a, y: bh * 0.08), control1: CGPoint(x: -a * 0.94, y: bottom), control2: CGPoint(x: -a, y: bh * 0.36))
        body.addCurve(to: CGPoint(x: 0, y: top), control1: CGPoint(x: -a, y: top + bh * 0.26), control2: CGPoint(x: -a * 0.66, y: top))
        body.closeSubpath()
        let fade: Double = mood == .sleepy ? 0.82 : 1
        g.fill(body, with: .linearGradient(Gradient(colors: [Self.bodyTop.opacity(fade), HaloStyle.ink.opacity(fade), Self.bodyBottom.opacity(fade)]),
                                           startPoint: CGPoint(x: -a * 0.3, y: top), endPoint: CGPoint(x: a * 0.3, y: bottom)))
        g.drawLayer { layer in
            layer.clip(to: body)
            // A pale tummy and a soft light from the top left.
            layer.fill(Path(ellipseIn: CGRect(x: -a * 0.52, y: bh * 0.12, width: a * 1.04, height: bh * 0.5)), with: .color(.white.opacity(0.13)))
            layer.fill(Path(ellipseIn: CGRect(x: -a * 0.78, y: top + bh * 0.04, width: a * 0.9, height: bh * 0.3)),
                       with: .linearGradient(Gradient(colors: [.white.opacity(0.30), .white.opacity(0)]), startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + bh * 0.34)))
        }

        drawHalo(in: &g, y: top - s * 0.085, s: s, t: t, mood: mood)
        drawFace(in: &g, s: s, bh: bh, t: t, mood: mood, talk: talk)
        drawArms(in: &g, s: s, a: a, bh: bh, t: t, mood: mood, talk: talk)

        // Proud: little stars twinkling around it.
        if mood == .proud {
            for i in 0..<5 {
                let angle = t * 1.1 + Double(i) * 1.257
                let p = CGPoint(x: center.x + CGFloat(cos(angle)) * s * 0.47, y: center.y - s * 0.05 + CGFloat(sin(angle)) * s * 0.4)
                let size = s * (0.035 + 0.025 * CGFloat(abs(sin(t * 3 + Double(i)))))
                var star = Path()
                star.move(to: CGPoint(x: p.x, y: p.y - size)); star.addQuadCurve(to: CGPoint(x: p.x + size, y: p.y), control: p)
                star.addQuadCurve(to: CGPoint(x: p.x, y: p.y + size), control: p); star.addQuadCurve(to: CGPoint(x: p.x - size, y: p.y), control: p)
                star.addQuadCurve(to: CGPoint(x: p.x, y: p.y - size), control: p)
                context.fill(star, with: .color(i % 2 == 0 ? Color(red: 1, green: 0.78, blue: 0.2) : HaloStyle.coral))
            }
        }
        // Sleepy: z's drifting up and away.
        if mood == .sleepy {
            for i in 0..<3 {
                let phase = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let p = CGPoint(x: center.x + s * (0.27 + CGFloat(phase) * 0.17), y: center.y - s * (0.26 + CGFloat(phase) * 0.3))
                context.draw(Text("z").font(.system(size: s * (0.085 + CGFloat(phase) * 0.075), weight: .heavy, design: .rounded)).foregroundColor(tint.opacity((1 - phase) * 0.85)), at: p)
            }
        }
        // Thinking: a thought on its way, three dots growing as they rise.
        if mood == .thinking {
            for i in 0..<3 {
                let pulse = 0.75 + 0.25 * CGFloat(sin(t * 4 - Double(i) * 0.9))
                let dot = s * (0.022 + CGFloat(i) * 0.013) * pulse
                let p = CGPoint(x: center.x + s * (0.30 + CGFloat(i) * 0.07), y: center.y - s * (0.30 + CGFloat(i) * 0.085))
                context.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2)), with: .color(HaloStyle.coral.opacity(0.9)))
            }
        }
    }

    /// The ring over its head: it spins while Halo thinks, glows when it is pleased, and slips when it dozes.
    private func drawHalo(in g: inout GraphicsContext, y: CGFloat, s: CGFloat, t: Double, mood: TutorMood) {
        let float = CGFloat(sin(t * 1.6 + 0.8)) * s * 0.014
        let tilt: CGFloat = mood == .sleepy ? 0.34 : mood == .unsure ? -0.2 : CGFloat(sin(t * 0.9)) * 0.06
        let rect = CGRect(x: -s * 0.215, y: -s * 0.052, width: s * 0.43, height: s * 0.104)
        var ring = g
        ring.translateBy(x: mood == .sleepy ? s * 0.07 : 0, y: y + float + (mood == .sleepy ? s * 0.05 : mood.joyful ? -s * 0.02 : 0))
        ring.rotate(by: .radians(tilt))
        let spin = mood == .thinking ? t * 6 : t * 0.8
        let glow = mood == .sleepy ? 0.12 : mood.joyful || mood == .speaking ? 0.5 : 0.28
        ring.stroke(Path(ellipseIn: rect), with: .color(HaloStyle.coral.opacity(glow)), lineWidth: s * 0.062)
        ring.stroke(Path(ellipseIn: rect), with: .conicGradient(
            Gradient(colors: [HaloStyle.coral, Color(red: 1, green: 0.78, blue: 0.45), .white, HaloStyle.coral]),
            center: .zero, angle: .radians(spin)), lineWidth: s * 0.03)
    }

    private func drawFace(in g: inout GraphicsContext, s: CGFloat, bh: CGFloat, t: Double, mood: TutorMood, talk: CGFloat) {
        // Where the eyes look (as a fraction of how far a pupil can travel).
        var gaze: CGPoint
        switch mood {
        case .thinking: gaze = CGPoint(x: 0.7 + 0.15 * sin(t * 1.3), y: -0.8)
        case .attentive: gaze = CGPoint(x: 0.45 + 0.2 * sin(t * 0.8), y: 0.8)
        case .listening: gaze = CGPoint(x: 0.25, y: -0.1)
        case .speaking, .happy, .proud, .wink: gaze = CGPoint(x: 0.15 * sin(t * 0.7), y: 0)
        case .unsure: gaze = CGPoint(x: -0.5, y: 0.2)
        case .sleepy: gaze = .zero
        default: gaze = CGPoint(x: 0.75 * sin(t * 0.43), y: 0.4 * sin(t * 0.31))
        }
        let white = GraphicsContext.Shading.color(.white)
        let eyeW = s * 0.118, eyeH = s * 0.15
        let eyeY = -bh * 0.13, eyeX = s * 0.118

        // Blink every few seconds, sometimes twice.
        let cycle = t.truncatingRemainder(dividingBy: 4.3)
        let blinking = cycle < 0.13 || (Int(t / 4.3) % 3 == 0 && cycle > 0.3 && cycle < 0.43)
        let open: CGFloat = blinking ? 0.1 : (mood == .thinking ? 0.82 : mood == .listening ? 1.1 : mood == .unsure ? 0.9 : 1)

        for side in [-1.0, 1.0] {
            let x = CGFloat(side) * eyeX
            if mood == .sleepy {
                // Closed: lids curving down.
                var lid = Path()
                lid.move(to: CGPoint(x: x - eyeW * 0.5, y: eyeY + eyeH * 0.1))
                lid.addQuadCurve(to: CGPoint(x: x + eyeW * 0.5, y: eyeY + eyeH * 0.1), control: CGPoint(x: x, y: eyeY + eyeH * 0.5))
                g.stroke(lid, with: white, style: StrokeStyle(lineWidth: s * 0.022, lineCap: .round))
            } else if mood.joyful || (mood == .wink && side > 0) {
                // Smiling eyes.
                var arc = Path()
                arc.move(to: CGPoint(x: x - eyeW * 0.55, y: eyeY + eyeH * 0.2))
                arc.addQuadCurve(to: CGPoint(x: x + eyeW * 0.55, y: eyeY + eyeH * 0.2), control: CGPoint(x: x, y: eyeY - eyeH * 0.55))
                g.stroke(arc, with: white, style: StrokeStyle(lineWidth: s * 0.028, lineCap: .round))
            } else {
                let h = max(s * 0.012, eyeH * open)
                let eye = Path(roundedRect: CGRect(x: x - eyeW / 2, y: eyeY - h / 2, width: eyeW, height: h), cornerRadius: min(eyeW, h) / 2)
                g.fill(eye, with: white)
                if open > 0.3 {
                    // A dark pupil that travels, with a spark of light in it.
                    let pr = eyeW * 0.31
                    let px = x + gaze.x * (eyeW / 2 - pr) * 0.9, py = eyeY + gaze.y * (h / 2 - pr) * 0.75
                    g.drawLayer { layer in
                        layer.clip(to: eye)
                        layer.fill(Path(ellipseIn: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2)), with: .color(Self.dark))
                        layer.fill(Path(ellipseIn: CGRect(x: px - pr * 0.1, y: py - pr * 0.75, width: pr * 0.6, height: pr * 0.6)), with: white)
                    }
                }
            }
            if mood == .unsure || mood == .thinking {
                var brow = Path()
                let lift = mood == .unsure ? CGFloat(side) * s * 0.02 : (side > 0 ? -s * 0.02 : s * 0.006)
                brow.move(to: CGPoint(x: x - eyeW * 0.5, y: eyeY - eyeH * 0.78 + lift))
                brow.addLine(to: CGPoint(x: x + eyeW * 0.5, y: eyeY - eyeH * 0.78 - lift))
                g.stroke(brow, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: s * 0.02, lineCap: .round))
            }
        }

        // Cheeks: always a little, more when it is pleased.
        let glow: Double = mood.joyful || mood == .wink ? 0.85 : mood == .speaking ? 0.6 : mood == .sleepy ? 0.5 : 0.38
        for side in [-1.0, 1.0] {
            g.fill(Path(ellipseIn: CGRect(x: CGFloat(side) * s * 0.205 - s * 0.042, y: eyeY + eyeH * 0.62, width: s * 0.084, height: s * 0.046)), with: .color(Self.blush.opacity(glow)))
        }

        // Mouth.
        let my = eyeY + eyeH * 1.02
        let line = StrokeStyle(lineWidth: s * 0.022, lineCap: .round)
        switch mood {
        case .speaking:
            let w = s * (0.085 + talk * 0.03), h = s * (0.022 + talk * 0.085)
            let mouth = Path(roundedRect: CGRect(x: -w / 2, y: my - h * 0.3, width: w, height: h), cornerRadius: min(w, h) / 2)
            g.fill(mouth, with: .color(Self.dark))
            if h > s * 0.05 { g.drawLayer { layer in layer.clip(to: mouth); layer.fill(Path(ellipseIn: CGRect(x: -w * 0.4, y: my + h * 0.3, width: w * 0.8, height: h * 0.7)), with: .color(Self.blush)) } }
        case .happy, .proud:
            // A wide open grin.
            var grin = Path()
            grin.move(to: CGPoint(x: -s * 0.085, y: my - s * 0.012))
            grin.addQuadCurve(to: CGPoint(x: s * 0.085, y: my - s * 0.012), control: CGPoint(x: 0, y: my + s * 0.012))
            grin.addQuadCurve(to: CGPoint(x: -s * 0.085, y: my - s * 0.012), control: CGPoint(x: 0, y: my + s * 0.135))
            g.fill(grin, with: .color(Self.dark))
            g.drawLayer { layer in layer.clip(to: grin); layer.fill(Path(ellipseIn: CGRect(x: -s * 0.05, y: my + s * 0.04, width: s * 0.1, height: s * 0.07)), with: .color(Self.blush)) }
        case .thinking:
            // Pushed to one side.
            var purse = Path()
            purse.move(to: CGPoint(x: s * 0.0, y: my + s * 0.012)); purse.addQuadCurve(to: CGPoint(x: s * 0.075, y: my), control: CGPoint(x: s * 0.04, y: my + s * 0.028))
            g.stroke(purse, with: white, style: line)
        case .unsure:
            var wave = Path()
            wave.move(to: CGPoint(x: -s * 0.06, y: my + s * 0.012))
            wave.addCurve(to: CGPoint(x: s * 0.06, y: my + s * 0.012), control1: CGPoint(x: -s * 0.02, y: my - s * 0.014), control2: CGPoint(x: s * 0.02, y: my + s * 0.038))
            g.stroke(wave, with: white, style: line)
        case .listening:
            let o = s * 0.036
            g.fill(Path(ellipseIn: CGRect(x: -o / 2, y: my - o * 0.2, width: o, height: o * 0.9)), with: .color(Self.dark))
        case .sleepy:
            let o = s * 0.03
            g.fill(Path(ellipseIn: CGRect(x: -o / 2, y: my, width: o, height: o)), with: .color(Self.dark))
        default:
            var smile = Path()
            smile.move(to: CGPoint(x: -s * 0.06, y: my))
            smile.addQuadCurve(to: CGPoint(x: s * 0.06, y: my), control: CGPoint(x: 0, y: my + s * 0.058))
            g.stroke(smile, with: white, style: line)
        }
    }

    /// Two short arms. Where the hands are is most of what Halo is "saying".
    private func drawArms(in g: inout GraphicsContext, s: CGFloat, a: CGFloat, bh: CGFloat, t: Double, mood: TutorMood, talk: CGFloat) {
        let sway = CGFloat(sin(t * 1.6)) * s * 0.008
        // Hand positions, left then right, relative to the middle of the body.
        var left = CGPoint(x: -a * 1.13, y: bh * 0.30 + sway), right = CGPoint(x: a * 1.13, y: bh * 0.30 - sway)
        var pencil = false
        switch mood {
        case .happy, .proud:
            let wiggle = CGFloat(sin(t * 9)) * s * 0.02
            left = CGPoint(x: -a * 1.28 - wiggle, y: -bh * 0.40); right = CGPoint(x: a * 1.28 + wiggle, y: -bh * 0.40)
        case .thinking:
            right = CGPoint(x: a * 0.42, y: bh * 0.27 + CGFloat(sin(t * 3)) * s * 0.006)          // a hand to its chin
        case .listening:
            right = CGPoint(x: a * 1.02, y: -bh * 0.20)                                           // cupped to its ear
        case .speaking:
            left = CGPoint(x: -a * 1.22, y: bh * 0.16 - talk * bh * 0.16 * CGFloat(0.5 + 0.5 * sin(t * 3.1)))
            right = CGPoint(x: a * 1.22, y: bh * 0.16 - talk * bh * 0.16 * CGFloat(0.5 + 0.5 * cos(t * 2.3)))
        case .attentive:
            right = CGPoint(x: a * 1.08 + CGFloat(sin(t * 7)) * s * 0.014, y: bh * 0.16 + CGFloat(cos(t * 9)) * s * 0.008); pencil = true
        case .unsure:
            left = CGPoint(x: -a * 1.34, y: bh * 0.02); right = CGPoint(x: a * 1.34, y: bh * 0.02)   // a shrug
        case .wink:
            right = CGPoint(x: a * 1.30 + CGFloat(sin(t * 12)) * s * 0.03, y: -bh * 0.30)            // a wave
        case .sleepy:
            left.y = bh * 0.34; right.y = bh * 0.34
        default: break
        }
        for (side, hand) in [(-1.0, left), (1.0, right)] {
            let shoulder = CGPoint(x: CGFloat(side) * a * 0.90, y: bh * 0.10)
            var arm = Path()
            arm.move(to: shoulder)
            arm.addQuadCurve(to: hand, control: CGPoint(x: (shoulder.x + hand.x) / 2 + CGFloat(side) * s * 0.035, y: (shoulder.y + hand.y) / 2 + s * 0.012))
            g.stroke(arm, with: .color(Self.limb), style: StrokeStyle(lineWidth: s * 0.068, lineCap: .round))
            if pencil, side > 0 {
                // A coral pencil, held at a writing angle.
                var p = g
                p.translateBy(x: hand.x, y: hand.y); p.rotate(by: .radians(0.55))
                p.fill(Path(roundedRect: CGRect(x: -s * 0.016, y: -s * 0.12, width: s * 0.032, height: s * 0.19), cornerRadius: s * 0.008), with: .color(HaloStyle.coral))
                var tip = Path(); tip.move(to: CGPoint(x: -s * 0.016, y: s * 0.07)); tip.addLine(to: CGPoint(x: s * 0.016, y: s * 0.07)); tip.addLine(to: CGPoint(x: 0, y: s * 0.11)); tip.closeSubpath()
                p.fill(tip, with: .color(Color(red: 0.98, green: 0.85, blue: 0.62)))
                p.fill(Path(ellipseIn: CGRect(x: -s * 0.006, y: s * 0.096, width: s * 0.012, height: s * 0.016)), with: .color(Self.dark))
            }
            let hr = s * 0.044
            g.fill(Path(ellipseIn: CGRect(x: hand.x - hr, y: hand.y - hr, width: hr * 2, height: hr * 2)), with: .color(Self.bodyTop))
        }
    }
}

/// Every mood side by side, for looking at the character (`--avatars`).
struct AvatarSheet: View {
    private let moods: [(String, TutorMood)] = [("idle", .idle), ("watching you write", .attentive), ("thinking", .thinking), ("speaking", .speaking), ("listening", .listening),
                                                 ("happy", .happy), ("proud", .proud), ("unsure", .unsure), ("wink", .wink), ("sleepy", .sleepy)]
    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                PageHeader(eyebrow: "Halo", title: "Meet Halo", note: "one face for every moment")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 18) {
                    ForEach(moods, id: \.0) { name, mood in
                        VStack(spacing: 4) {
                            TutorAvatar(cue: TutorCue(base: mood), size: 190)
                            Text(name).font(HaloKit.hand(27)).foregroundStyle(HaloStyle.ink)
                        }.haloCard(padding: 16)
                    }
                }
                HStack(spacing: 30) {
                    ForEach([104, 78, 56] as [CGFloat], id: \.self) { size in TutorAvatar(cue: TutorCue(base: .idle), size: size) }
                    Text("how it looks small").font(HaloKit.hand(24)).foregroundStyle(HaloStyle.ink)
                }
            }
            .padding(32).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .background(DeskPaper().ignoresSafeArea())
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
                    Text(mood.label.uppercased()).font(HaloKit.text(10.5, .bold)).tracking(1.3).foregroundStyle(mood.tint)
                }
                karaoke(words, lit: lit)
                    .font(HaloKit.title(fontSize)).lineSpacing(4)
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
