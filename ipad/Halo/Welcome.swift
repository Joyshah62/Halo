import SwiftUI

/// The upload moment. Halo just read the whole document: it speaks a two-sentence brief,
/// writes the three ideas that matter in its own hand, and offers where to start.
@MainActor
struct WelcomeCard: View {
    @ObservedObject var store: StudyStore
    let map: DocumentMap
    @State private var revealed = 0
    private var tricky: Int { map.pages.filter { $0.difficulty >= 3 }.count }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        HaloRing(size: 44, symbol: "checkmark").padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow("Halo read it first", color: HaloStyle.coral)
                            Text(map.title).font(.system(size: 27, design: .serif)).foregroundStyle(HaloStyle.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        CloseButton { store.dismissWelcome() }
                    }
                    FlowRow(spacing: 8) {
                        ScribbleChip(text: map.subject.lowercased(), icon: "books.vertical")
                        ScribbleChip(text: "\(map.pages.count) pages", icon: "doc.text")
                        if tricky > 0 { ScribbleChip(text: "\(tricky) tricky", icon: "exclamationmark.triangle") }
                    }
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "waveform").font(.system(size: 14, weight: .semibold)).foregroundStyle(HaloStyle.coral)
                            .symbolEffect(.variableColor.iterative, isActive: revealed < map.keyIdeas.count).padding(.top, 3)
                        Text(map.say).font(.system(size: 16.5)).foregroundStyle(HaloStyle.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                    Sticky(label: "The three ideas to keep", tilt: -0.6) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(map.keyIdeas.enumerated()), id: \.offset) { index, idea in
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Text("\(index + 1)").font(HaloKit.hand(30)).foregroundStyle(HaloStyle.coral).frame(width: 16, alignment: .leading)
                                    Text(idea).font(HaloKit.hand(27)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
                                }
                                .opacity(index < revealed ? 1 : 0).offset(x: index < revealed ? 0 : -8)
                                .animation(.easeOut(duration: 0.45).delay(0.1), value: revealed)
                            }
                        }
                    }
                    pageStrip
                    HStack(spacing: 10) {
                        Button { store.startFromWelcome(page: map.startHere - 1) } label: {
                            Label("Start at page \(map.startHere)", systemImage: "arrow.turn.down.right").frame(maxWidth: .infinity)
                        }.buttonStyle(PillButtonStyle())
                        Button { store.startFromWelcome(page: max(0, (map.pages.first?.page ?? 1) - 1)) } label: { Text("From the top").frame(maxWidth: .infinity) }
                            .buttonStyle(PillButtonStyle(color: HaloStyle.ink, filled: false))
                    }
                    Text("circle anything with your Pencil and ask").font(HaloKit.hand(21)).foregroundStyle(HaloStyle.ink.opacity(0.8)).frame(maxWidth: .infinity)
                }
                .padding(26)
            }
            .scrollIndicators(.visible)
            .frame(width: min(500, geometry.size.width - 40), height: min(760, geometry.size.height - 48))
            .background(DeskPaper().clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(HaloStyle.coral.opacity(0.3), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 34, y: 16)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            // Reveal the handwriting line by line, roughly in time with the spoken brief.
            for i in 1...max(1, map.keyIdeas.count) {
                try? await Task.sleep(for: .milliseconds(i == 1 ? 900 : 1100))
                revealed = i
            }
        }
    }
    private var pageStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Where it gets hard")
            HStack(spacing: 3) {
                ForEach(map.pages, id: \.page) { page in
                    Button { store.startFromWelcome(page: page.page - 1) } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(page.difficulty >= 3 ? HaloStyle.coral : page.difficulty == 2 ? HaloStyle.coral.opacity(0.4) : HaloStyle.ink.opacity(0.12))
                            .frame(height: page.difficulty >= 3 ? 22 : page.difficulty == 2 ? 16 : 11)
                            .frame(height: 22, alignment: .bottom)
                    }.buttonStyle(.plain).help("Page \(page.page): \(page.topic)").accessibilityLabel("Page \(page.page), \(page.topic)")
                }
            }
            if let hard = map.pages.first(where: { $0.difficulty >= 3 && !$0.note.isEmpty }) {
                Text("p.\(hard.page): \(hard.note)").font(HaloKit.hand(21)).foregroundStyle(HaloStyle.coral).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Shown while Halo reads a freshly imported document.
@MainActor
struct ReadingBanner: View {
    let progress: String
    var body: some View {
        HStack(spacing: 11) {
            HaloRing(size: 22, working: true)
            Text(progress).font(HaloKit.hand(23)).foregroundStyle(HaloStyle.text)
        }
        .padding(.leading, 12).padding(.trailing, 18).padding(.vertical, 8)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().stroke(HaloStyle.coral.opacity(0.35)))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }
}

/// First launch: thirty seconds that make every answer personal.
@MainActor
struct OnboardingView: View {
    @ObservedObject var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: LearnerProfile
    init(store: StudyStore) { self.store = store; _profile = State(initialValue: store.learner) }
    private let levels = ["High school", "First-year undergrad", "Upper-level undergrad", "Grad school", "Self-taught"]
    private let styles = ["Examples first, then the rule", "The idea first, then examples", "Quick and direct", "Slow and thorough"]
    /// How Halo would explain one small idea in each style, so the choice is something you can see.
    private var sample: String {
        switch profile.style {
        case styles[0]: return "You drive 60 km in an hour: that’s a rate. Now shrink the hour to an instant. That’s a derivative."
        case styles[1]: return "A derivative is how fast something is changing right now. Your speedometer is one."
        case styles[2]: return "Derivative = rate of change at a point = slope of the tangent."
        case styles[3]: return "Let’s build it. Average speed over an hour. Then a minute. Then a second. Keep shrinking… what’s left is the derivative."
        default: return "Pick a style and I’ll show you how I’d explain a derivative."
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(eyebrow: "Make it yours", title: profile.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Hey. I’m Halo." : "Nice to meet you, \(profile.name.trimmingCharacters(in: .whitespaces)).",
                           note: "tell me a little about you, and I’ll explain things your way") {
                    Button("Skip") { store.finishOnboarding(nil); dismiss() }.font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).padding(.top, 8)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow("About you")
                    DeskField(prompt: "First name", text: $profile.name, icon: "person").textContentType(.givenName)
                    DeskField(prompt: "What are you studying? (e.g. Calc II, Bio 101)", text: $profile.course, icon: "book")
                }.haloCard().arrives(1)
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow("Where you are")
                    ChoiceChips(options: levels, selection: $profile.level)
                }.haloCard().arrives(2)
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("How you like things explained")
                    ChoiceChips(options: styles, selection: $profile.style)
                    Sticky(label: profile.style.isEmpty ? nil : "So I’d say it like this", tilt: -0.5) {
                        Text(sample).font(HaloKit.hand(25)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity).animation(.easeOut(duration: 0.25), value: profile.style)
                    }.padding(.top, 2)
                }.haloCard().arrives(3)
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow("What you’re working toward (optional)")
                    DeskField(prompt: "An exam, a project, just curious…", text: $profile.goal, icon: "flag")
                }.haloCard().arrives(4)
                Button { store.finishOnboarding(profile); dismiss() } label: { Label("Let’s go", systemImage: "arrow.right").frame(maxWidth: .infinity).padding(.vertical, 3) }
                    .buttonStyle(PillButtonStyle()).arrives(5)
                Text("This stays on your iPad and goes to your Halo server with each question so the explanation fits you. Change it any time in Settings.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 34)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DeskPaper().ignoresSafeArea())
    }
}
