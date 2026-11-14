import SwiftUI

// Halo's look, shared by every page: a desk pad of dotted paper, a coral ring, serif titles,
// small tracked labels, things Halo "wrote" in its handwriting, yellow sticky notes and taped prints.

enum HaloKit {
    static let highlight = Color(red: 1.0, green: 0.93, blue: 0.62)
    static let leaf = Color(red: 0.13, green: 0.55, blue: 0.35)
    static let amber = Color(red: 0.71, green: 0.33, blue: 0.04)
    static func hand(_ size: CGFloat) -> Font { .custom("Caveat-Regular", size: size) }

    // Halo's type. Three voices, all bundled and open source:
    //   title  Fraunces: a soft, slightly irregular old-style serif, for titles and anything Halo "says" in print.
    //   text   Nunito: a rounded humanist sans, for everything you read or tap.
    //   hand   Caveat: Halo's handwriting (also what its answers are drawn from, stroke by stroke).
    // Both are variable fonts, so a weight is a point on an axis, not a separate file.
    private static func variable(_ family: String, _ size: CGFloat, _ axes: [Int: CGFloat]) -> Font {
        let descriptor = UIFontDescriptor(fontAttributes: [.family: family, UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes])
        return Font(UIFont(descriptor: descriptor, size: size))
    }
    private static func axis(_ weight: Font.Weight, lightest: CGFloat) -> CGFloat {
        switch weight {
        case .ultraLight, .thin, .light: return max(lightest, 300)
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }
    private static let wght = 0x77676874, opsz = 0x6F70737A, soft = 0x534F4654, wonk = 0x574F4E4B
    /// Body and interface text.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        // Nunito runs a touch lighter than the system font at the same weight.
        variable("Nunito", size, [wght: min(900, axis(weight, lightest: 300) + (weight == .regular ? 40 : 80))])
    }
    /// Titles. Softened all the way, and a little heavier than its "regular", which is thin at text sizes.
    static func title(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        variable("Fraunces", size, [wght: axis(weight, lightest: 300) + (size < 24 ? 40 : 0), opsz: min(144, max(9, size)), soft: 100, wonk: 0])
    }
}

extension Text {
    /// Halo's handwriting. Caveat's "?", "!" and a few capitals lean a sixth of their size past their own width, and
    /// SwiftUI draws nothing outside a text's measured width: the last character of a line lost its right side.
    /// A no-break space after the text makes the measured width cover the lean.
    func hand(_ size: CGFloat) -> Text { Text("\(self)\u{00A0}").font(HaloKit.hand(size)) }
}

/// Paper with a faint dot grid, like a desk pad.
struct DeskPaper: View {
    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 26
            var dots = Path()
            var y: CGFloat = gap / 2
            while y < size.height {
                var x: CGFloat = gap / 2
                while x < size.width { dots.addEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6)); x += gap }
                y += gap
            }
            context.fill(dots, with: .color(HaloStyle.ink.opacity(0.11)))
        }
        .background(HaloStyle.paper)
    }
}

/// A gentle pulse for things that are still on their way.
struct Breathing: ViewModifier {
    @State private var dim = false
    func body(content: Content) -> some View {
        content.opacity(dim ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// Halo's ring. It draws itself when it appears, spins while Halo is working, and can hold a symbol.
struct HaloRing: View {
    var size: CGFloat = 58
    var working = false
    var symbol: String?
    @State private var drawn = false
    @State private var spin = false
    private var line: CGFloat { max(2.5, size * 0.1) }
    var body: some View {
        ZStack {
            Circle().stroke(HaloStyle.coral.opacity(0.18), lineWidth: line)
            Circle().trim(from: 0, to: working ? 0.28 : (drawn ? 1 : 0))
                .stroke(HaloStyle.coral, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90 + (working && spin ? 360 : 0)))
                .animation(working ? .linear(duration: 1.1).repeatForever(autoreverses: false) : .spring(duration: 0.6), value: spin)
                .animation(.easeOut(duration: 0.9), value: drawn)
                .animation(.spring(duration: 0.6), value: working)
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(HaloStyle.coral)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size, height: size)
        .onAppear { drawn = true; spin = true }
        .accessibilityHidden(true)
    }
}

/// The small tracked label over a title or a group ("WHAT HALO DOES").
struct Eyebrow: View {
    let text: String
    var color: Color = HaloStyle.text.opacity(0.5)
    init(_ text: String, color: Color = HaloStyle.text.opacity(0.5)) { self.text = text; self.color = color }
    var body: some View { Text(text.uppercased()).font(HaloKit.text(11, .bold)).tracking(1.3).foregroundStyle(color) }
}

/// How a page opens: the ring, a coral label, a serif title and (optionally) a handwritten line under it.
struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var note: String?
    var working = false
    var symbol: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            HaloRing(working: working, symbol: symbol).padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(eyebrow, color: HaloStyle.coral)
                Text(title).font(HaloKit.title(38, .regular)).foregroundStyle(HaloStyle.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let note, !note.isEmpty { Text(note).hand(24).foregroundStyle(HaloStyle.ink).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}
extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, note: String? = nil, working: Bool = false, symbol: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, note: note, working: working, symbol: symbol) { EmptyView() }
    }
}

/// The round white ✕ in a page's corner.
struct CloseButton: View {
    var label = "Close"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38)
                .background(Color.white, in: Circle()).overlay(Circle().stroke(HaloStyle.ink.opacity(0.12))).foregroundStyle(HaloStyle.text)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// A fact or a step, written by hand in a pill: "read 6 pages", "3 tricky pages".
struct ScribbleChip: View {
    let text: String
    var icon: String?
    var tint: Color = HaloStyle.coral
    var done = false
    var body: some View {
        HStack(spacing: 7) {
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(HaloKit.leaf).font(.system(size: 14, weight: .semibold)) }
            else if let icon { Image(systemName: icon).foregroundStyle(tint).font(.system(size: 13, weight: .semibold)) }
            Text(text).hand(21).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color.white.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(HaloStyle.ink.opacity(0.1)))
    }
}

/// A yellow sticky note, set down slightly crooked.
struct Sticky<Content: View>: View {
    var label: String?
    var tilt: Double = -0.7
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label { Text(label.uppercased()).font(HaloKit.text(10.5, .bold)).tracking(1.2).foregroundStyle(HaloStyle.text.opacity(0.5)) }
            content
        }
        .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .background(HaloKit.highlight, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 4)
        .rotationEffect(.degrees(tilt))
    }
}

/// A print taped to the desk: white border, a strip of tape, a slight tilt.
struct Taped<Content: View>: View {
    var tilt: Double = -1.6
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 9).padding(.top, 9).padding(.bottom, 8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.16), radius: 9, y: 5)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 1.5).fill(HaloKit.highlight.opacity(0.85)).frame(width: 62, height: 19)
                    .rotationEffect(.degrees(-tilt * 1.6)).offset(y: -9).shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            }
            .rotationEffect(.degrees(tilt))
    }
}

extension View {
    /// The white card everything sits on.
    func haloCard(radius: CGFloat = 22, padding: CGFloat = 24) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }
    func breathing() -> some View { modifier(Breathing()) }
    /// Slides up and fades in a moment after the page appears, so a page assembles itself in order.
    func arrives(_ order: Int) -> some View { modifier(Arrival(order: order)) }
}
private struct Arrival: ViewModifier {
    let order: Int
    @State private var here = false
    func body(content: Content) -> some View {
        content.opacity(here ? 1 : 0).offset(y: here ? 0 : 18)
            .onAppear { withAnimation(.spring(duration: 0.55, bounce: 0.18).delay(0.07 * Double(order))) { here = true } }
    }
}

/// The solid coral (or ink) capsule: the one thing on a page to tap.
struct PillButtonStyle: ButtonStyle {
    var color: Color = HaloStyle.coral
    var filled = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(HaloKit.text(15, .semibold)).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(filled ? color.opacity(enabled ? 1 : 0.35) : Color.white, in: Capsule())
            .overlay(Capsule().stroke(color.opacity(filled ? 0 : 0.3)))
            .foregroundStyle(filled ? .white : color)
            .scaleEffect(configuration.isPressed ? 0.96 : 1).animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Pick one of a few answers by tapping it.
struct ChoiceChips: View {
    let options: [String]
    @Binding var selection: String
    var body: some View {
        FlowRow(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let on = selection == option
                Button { withAnimation(.spring(duration: 0.25)) { selection = on ? "" : option } } label: {
                    Text(option).font(HaloKit.text(14.5, .medium)).padding(.horizontal, 13).padding(.vertical, 8)
                        .background(on ? HaloStyle.ink : HaloStyle.ink.opacity(0.07), in: Capsule())
                        .foregroundStyle(on ? .white : HaloStyle.ink)
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// A text field that looks like it belongs on the desk.
struct DeskField: View {
    let prompt: String
    @Binding var text: String
    var icon: String?
    var body: some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(HaloStyle.coral).frame(width: 20) }
            TextField(prompt, text: $text).font(HaloKit.text(16)).textFieldStyle(.plain)
        }
        .padding(.horizontal, 14).frame(height: 46)
        .background(HaloStyle.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HaloStyle.ink.opacity(0.12)))
    }
}

/// What a page shows when there is nothing on it yet.
struct EmptyDesk: View {
    let title: String
    let note: String
    var symbol = "circle.dashed"
    var body: some View {
        VStack(spacing: 12) {
            HaloRing(size: 54, symbol: symbol)
            Text(title).font(HaloKit.title(24)).foregroundStyle(HaloStyle.text).multilineTextAlignment(.center)
            Text(note).hand(23).foregroundStyle(HaloStyle.ink).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
        }
        .padding(.vertical, 34).padding(.horizontal, 20).frame(maxWidth: .infinity)
    }
}

/// The same conversation controls on every desk: microphone, growing text field, send.
/// Context actions belong below this row so they never squeeze the student's words.
struct HaloComposer: View {
    @Binding var text: String
    var prompt = "Ask Halo…"
    var recording = false
    var enabled = true
    var canSend = true
    var microphone: (() -> Void)?
    var focus: FocusState<Bool>.Binding?
    var send: () -> Void
    @FocusState private var focused: Bool

    private var ready: Bool { enabled && canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if let microphone {
                Button { if let focus { focus.wrappedValue = false } else { focused = false }; microphone() } label: {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                        .foregroundStyle(.white).background(HaloStyle.coral, in: Circle())
                }.buttonStyle(.plain).disabled(!enabled)
                    .accessibilityLabel(recording ? "Stop listening" : "Talk to Halo")
            }
            TextField(prompt, text: $text, axis: .vertical)
                .font(HaloKit.text(17)).textFieldStyle(.plain).lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(HaloStyle.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .focused(focus ?? $focused).submitLabel(.send).onSubmit { if ready { send() } }
                .disabled(!enabled).accessibilityLabel("Your question")
            Button { if ready { send() } } label: {
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                    .frame(width: 44, height: 44).foregroundStyle(ready ? Color.white : HaloStyle.ink.opacity(0.5))
                    .background(ready ? HaloStyle.ink : HaloStyle.ink.opacity(0.1), in: Circle())
                    .animation(.spring(duration: 0.25), value: ready)
            }
            // Not `.disabled`: that fades the whole button until it looks broken. With nothing to send it reads as waiting, and does nothing.
            .buttonStyle(.plain).allowsHitTesting(ready).accessibilityLabel("Send to Halo")
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke((focus?.wrappedValue ?? focused) || recording ? HaloStyle.coral.opacity(0.6) : HaloStyle.ink.opacity(0.15)))
    }
}
