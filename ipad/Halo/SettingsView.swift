import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    private enum Link: Equatable { case unknown, testing, connected, failed(String) }
    @State private var link: Link = .unknown

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(eyebrow: "Settings", title: "Make Halo yours", note: "who you are, how it teaches, where it thinks") {
                    CloseButton(label: "Done") { dismiss() }
                }
                server.arrives(1)
                person.arrives(2)
                learning.arrives(3)
                tips.arrives(4)
            }
            .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 34)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DeskPaper().ignoresSafeArea())
        .task { await test() }
    }

    // MARK: server
    private var server: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("Your Halo server")
                Spacer()
                status
            }
            HStack(spacing: 10) {
                Image(systemName: "server.rack").font(.system(size: 15, weight: .medium)).foregroundStyle(HaloStyle.coral).frame(width: 20)
                TextField("https://your-halo-server.example", text: $store.serverURL).font(.system(size: 16, design: .monospaced)).textFieldStyle(.plain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.done).onSubmit { Task { await test() } }
                    .accessibilityLabel("Halo server URL")
                Button("Test") { Task { await test() } }.font(.system(size: 14, weight: .semibold)).foregroundStyle(HaloStyle.ink).disabled(link == .testing)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .background(HaloStyle.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HaloStyle.ink.opacity(0.12)))
            if case .failed(let why) = link { Text(why).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            Text("Use your hosted HTTPS server, or http://your-mac.local:8787 on the same Wi-Fi for development. localhost on an iPad refers to the iPad, not your Mac. API keys stay on the server.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.haloCard()
    }
    @ViewBuilder private var status: some View {
        switch link {
        case .unknown: EmptyView()
        case .testing: HStack(spacing: 7) { HaloRing(size: 16, working: true); Text("checking…").font(HaloKit.hand(20)).foregroundStyle(.secondary) }
        case .connected: HStack(spacing: 6) { Image(systemName: "checkmark.circle.fill").foregroundStyle(HaloKit.leaf); Text("connected").font(HaloKit.hand(21)).foregroundStyle(HaloKit.leaf) }
        case .failed: HStack(spacing: 6) { Image(systemName: "wifi.exclamationmark").foregroundStyle(.red); Text("can’t reach it").font(HaloKit.hand(21)).foregroundStyle(.red) }
        }
    }
    private func test() async {
        link = .testing
        do { try await HaloClient().checkHealth(server: store.serverURL); withAnimation { link = .connected } }
        catch { withAnimation { link = .failed(error.localizedDescription) } }
    }

    // MARK: who is studying
    private var person: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("About you")
            DeskField(prompt: "First name", text: $store.learner.name, icon: "person")
            DeskField(prompt: "What you’re studying", text: $store.learner.course, icon: "book")
            DeskField(prompt: "Level (e.g. first-year undergrad)", text: $store.learner.level, icon: "chart.bar")
            DeskField(prompt: "How you like things explained", text: $store.learner.style, icon: "text.bubble")
            Text("Halo uses this, plus what you’ve asked about recently, to pitch every explanation at you.").font(.footnote).foregroundStyle(.secondary)
        }.haloCard()
    }

    // MARK: how it teaches
    private var learning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("Learning").padding(.bottom, 8)
            option("graduationcap", HaloKit.amber, "Tutor mode", "Hints and questions that help you find the next step, instead of the answer.", $store.tutorMode)
            Divider().padding(.leading, 52)
            option("pencil.and.scribble", HaloKit.leaf, "Watch my working", "In Write mode, when you pause, Halo checks your lines: a tick for a right step, a circle and a hint for a wrong one.", $store.watchWork)
            Divider().padding(.leading, 52)
            option("speaker.wave.2", HaloStyle.coral, "Read answers aloud", "Halo speaks as it writes.", $store.voiceOut)
            Divider().padding(.leading, 52)
            option("airplane", HaloStyle.ink, "Offline sample answers", "Fixed answers from a calculus example. Turn this off to ask live questions about your own documents.", $store.demoMode)
        }.haloCard()
    }
    private func option(_ icon: String, _ tint: Color, _ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 38, height: 38).background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(HaloStyle.text)
                    Text(detail).font(.system(size: 13.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.tint(HaloStyle.coral).padding(.vertical, 8)
    }

    // MARK: how to use it
    private var tips: some View {
        Sticky(label: "On your iPad", tilt: -0.4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("circle with the Pencil, ask out loud").font(HaloKit.hand(25))
                Text("fingers scroll and zoom").font(HaloKit.hand(25))
                Text("tap a circle to pick that conversation back up").font(HaloKit.hand(25))
                Text("Without a Pencil, turn on finger circling in the bottom bar. Original PDFs are never changed; Halo’s copies, your handwriting and every conversation stay in its local library.")
                    .font(.footnote).foregroundStyle(HaloStyle.text.opacity(0.6)).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(HaloStyle.text)
        }
    }
}
