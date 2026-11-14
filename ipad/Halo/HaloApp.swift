import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct HaloApp: App {
    @StateObject private var store = StudyStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryView(store: store)
                .tint(HaloStyle.ink)
                // Halo is ink on paper. Dark Mode would put white text on the light page.
                .preferredColorScheme(.light)
                .task { await store.loadLibrary(); await store.runLaunchScript() }
                .onOpenURL { url in Task { await store.importPDF(url) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { store.lesson.hush(); store.cancelAnswer(); store.speech.stop(); Task { await store.flush(); await store.flushLoose() } }
                }
        }
    }
}

enum HaloStyle {
    static let coral = Color(red: 1.0, green: 0.35, blue: 0.21)
    static let ink = Color(red: 0.22, green: 0.19, blue: 0.84)
    static let text = Color(red: 0.11, green: 0.11, blue: 0.18)
    static let paper = Color(red: 0.97, green: 0.965, blue: 0.95)
    static let green = ink
}

@MainActor
struct LibraryView: View {
    @ObservedObject var store: StudyStore
    @State private var importing = false
    @State private var settings = false
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var deletion: LibraryDocument?
    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            List {
                Section {
                    Button { importing = true } label: { Label("Import a PDF", systemImage: "plus.circle.fill").foregroundStyle(HaloStyle.coral) }
                    Button { Task { await store.openSample() } } label: { Label("Try a sample lesson", systemImage: "sparkles") }
                    Button { store.openQuickNotes() } label: {
                        HStack {
                            Label("Quick notes", systemImage: "square.and.pencil")
                            Spacer()
                            if !store.looseNotes.isEmpty { Text("\(store.looseNotes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("Your library") {
                    if store.documents.isEmpty { Text("Your lecture slides and reading live here.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(store.documents) { item in
                        Button { Task { await store.open(item); columns = .detailOnly } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.richtext").font(.title3).foregroundStyle(HaloStyle.coral)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text("\(item.pageCount) pages").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if store.document?.id == item.id { Image(systemName: "checkmark").font(.caption).foregroundStyle(HaloStyle.ink) }
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                        .contextMenu { Button("Delete from Halo", role: .destructive) { deletion = item } }
                    }
                }
            }
            .navigationTitle("halo.")
            .toolbar { ToolbarItem(placement: .bottomBar) { Button { settings = true } label: { Label("Settings", systemImage: "gearshape") } } }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 310)
        } detail: {
            NavigationStack {
                if store.pdf != nil { StudioView(store: store, openSettings: { settings = true }) }
                else { welcome }
            }
        }
        .onChange(of: store.document?.id) { _, id in compactColumn = id == nil ? .sidebar : .detail }
        .onAppear { if CommandLine.arguments.contains("--settings") { settings = true } }   // for screenshots
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await store.importPDF(url) } }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $settings) { SettingsView(store: store) }
        .fullScreenCover(isPresented: Binding(get: { store.showNotebook }, set: { if !$0 { store.closeNotebook() } })) { NotebookView(store: store) }
        .sheet(isPresented: Binding(get: { store.needsOnboarding }, set: { if !$0 { store.finishOnboarding(nil) } })) { OnboardingView(store: store).interactiveDismissDisabled() }
        .alert("Delete from Halo?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("Cancel", role: .cancel) { deletion = nil }
            Button("Delete", role: .destructive) { if let item = deletion { Task { await store.delete(item) } }; deletion = nil }
        } message: { Text("This removes Halo’s copy and its notes. The original PDF is unchanged.") }
        .diveBoard(store, when: !store.showNotebook)
        .overlay {
            if store.loading {
                VStack(spacing: 12) { HaloRing(size: 46, working: true); Text("opening your document…").font(HaloKit.hand(25)).foregroundStyle(HaloStyle.text) }
                    .padding(.horizontal, 30).padding(.vertical, 24).background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            }
        }
    }
    private var welcome: some View { LandingView(store: store, importPDF: { importing = true }) }
}

/// The page, with Halo's margin docked beside it (landscape) or under it (portrait) while a note is open.
@MainActor
struct StudioView: View {
    @ObservedObject var store: StudyStore
    var openSettings: () -> Void
    var body: some View {
        GeometryReader { geometry in
            let session = store.pill != .hidden ? store.activeSession : nil
            // `--sideways` forces the landscape arrangement, for screenshots.
            let sideways = geometry.size.width > geometry.size.height || CommandLine.arguments.contains("--sideways")
            let layout = sideways ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                page(pointingTo: session == nil ? nil : (sideways ? Edge.trailing : Edge.bottom))
                if let session {
                    HaloMargin(store: store, session: session, sideways: sideways)
                        .frame(width: sideways ? min(540, max(380, geometry.size.width * 0.42)) : nil,
                               height: sideways ? nil : min(520, max(330, geometry.size.height * 0.37)))
                        .transition(.move(edge: sideways ? .trailing : .bottom))
                        .id(session.id)
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.1), value: session?.id)
            // The page just changed size: bring the circle back into view.
            .onChange(of: session?.id) { _, id in
                guard id != nil else { return }
                Task { try? await Task.sleep(for: .milliseconds(480)); store.ink?.revealCircle() }
            }
        }
        .fullScreenCover(isPresented: $store.showLesson) { LessonBoard(store: store) }
        .fullScreenCover(isPresented: recapCover) { RecapView(store: store) }
        .navigationTitle(store.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(store.displayTitle).font(.headline).lineLimit(1)
                    if let chapter = store.currentChapter { Text(chapter.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(maxWidth: 420)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button { store.openLesson() } label: { Label("Teach me", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }.accessibilityLabel("Teach me this chapter")
                    // Chapters, your sticky notes and search live in one panel.
                    Button { store.openNavigator(store.navigatorTab) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "text.magnifyingglass")
                            if noteCount > 0 { Text("\(noteCount)").font(.caption.weight(.semibold).monospacedDigit()) }
                        }
                    }.accessibilityLabel("Chapters, notes and search")
                    Button { store.openNotebook() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("My notes for this document")
                    Button { store.openRecap() } label: { Image(systemName: "list.clipboard") }.accessibilityLabel("Session summary")
                    Button { store.showBrief() } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel(store.isBook ? "Halo’s read of this chapter" : "Halo’s read of this document")
                    Text("\(store.pageIndex + 1) / \(store.pdf?.pageCount ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button(action: openSettings) { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
                .popover(isPresented: $store.showNavigator) { NavigatorView(store: store).frame(minWidth: 420, idealWidth: 420, minHeight: 620, idealHeight: 660) }
            }
        }
    }
    private var recapCover: Binding<Bool> { Binding(get: { store.showRecap }, set: { if !$0 { store.closeRecap() } }) }
    private var noteCount: Int { store.notes.sessions.filter { !$0.messages.isEmpty }.count }

    /// The page and everything that floats over it. A coral arrow runs from the margin to the circle it is about.
    private func page(pointingTo edge: Edge?) -> some View {
        GeometryReader { area in
            ZStack(alignment: .top) {
                PDFReader(store: store).ignoresSafeArea(edges: .bottom)
                if let edge, let anchor = store.anchorFrame, let arrow = arrow(from: edge, to: anchor, in: area.size) {
                    arrow.stroke(HaloStyle.coral, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                        .shadow(color: .white.opacity(0.9), radius: 1.5).allowsHitTesting(false)
                }
                if let reading = store.reading { ReadingBanner(progress: reading).padding(.top, 12) }
                if let map = store.welcome {
                    Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { store.dismissWelcome() }
                    WelcomeCard(store: store, map: map).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The Pencil palette owns the bottom edge while writing, so the bar moves up.
                // (Put away while Halo's margin is open: the conversation has the floor, and the bar would sit on the circle.)
                if edge == nil {
                    VStack {
                        if store.tool == .write { toolbar.padding(.top, 12); Spacer() }
                        else { Spacer(); toolbar.padding(.bottom, 18) }
                    }
                    .animation(.spring(duration: 0.35), value: store.tool)
                    .transition(.opacity)
                }
                if let error = store.error, store.pill == .hidden {
                    Text(error).font(.footnote).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.red.opacity(0.9), in: Capsule()).padding(.top, 12)
                        .onTapGesture { store.error = nil }
                }
            }
            .animation(.spring(duration: 0.35), value: store.welcome == nil)
        }
    }
    private func arrow(from edge: Edge, to anchor: CGRect, in size: CGSize) -> NoteTail? {
        guard anchor.maxY > 0, anchor.minY < size.height, anchor.minX < size.width else { return nil }
        let start = edge == .trailing ? CGPoint(x: size.width - 2, y: min(max(70, anchor.midY - 40), size.height - 70))
                                      : CGPoint(x: min(max(70, anchor.midX + 60), size.width - 70), y: size.height - 2)
        let end = CGPoint(x: min(max(anchor.minX, start.x), anchor.maxX), y: min(max(anchor.minY, start.y), anchor.maxY))
        guard hypot(end.x - start.x, end.y - start.y) > 26 else { return nil }
        return NoteTail(from: start, to: end)
    }
    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(ReaderTool.allCases, id: \.self) { tool in
                Button { store.tool = tool } label: {
                    Label(tool.rawValue, systemImage: tool == .circle ? "circle.dashed" : tool == .write ? "pencil.tip" : "hand.draw")
                        .font(.system(size: 13, weight: .semibold)).labelStyle(.titleAndIcon)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(store.tool == tool ? (tool == .circle ? HaloStyle.coral : HaloStyle.ink) : Color.clear, in: Capsule())
                        .foregroundStyle(store.tool == tool ? .white : HaloStyle.text)
                }.buttonStyle(.plain)
            }
            Divider().frame(height: 22).padding(.horizontal, 4)
            Button { store.tutorMode.toggle() } label: {
                Label("Tutor", systemImage: store.tutorMode ? "graduationcap.fill" : "graduationcap").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(store.tutorMode ? Color(red: 0.71, green: 0.33, blue: 0.04) : Color.clear, in: Capsule())
                    .foregroundStyle(store.tutorMode ? .white : HaloStyle.text)
            }.buttonStyle(.plain).help("Hints instead of answers")
            if store.tool == .circle {
                Button { store.circleWithFinger.toggle() } label: {
                    Image(systemName: store.circleWithFinger ? "hand.point.up.left.fill" : "hand.point.up.left").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(store.circleWithFinger ? HaloStyle.ink.opacity(0.15) : Color.clear, in: Capsule())
                        .foregroundStyle(HaloStyle.text)
                }.buttonStyle(.plain).help("Circle with a finger too")
            }
            Button { store.askAboutPage(store.pageIndex) } label: {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 8).foregroundStyle(HaloStyle.text)
            }.buttonStyle(.plain).help("Ask about this page")
            if store.demoMode { Text("DEMO").font(.system(size: 9, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 3).background(.orange.opacity(0.15), in: Capsule()) }
        }
        .padding(5)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
    }
}
