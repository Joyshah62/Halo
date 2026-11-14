import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct HaloApp: App {
    @StateObject private var store = StudyStore()
    @Environment(\.scenePhase) private var scenePhase
    private var scenePreview: Scene3DSpec? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--scene3d"), index + 1 < args.count else { return nil }
        let scene = Scene3DSpec(model: args[index + 1])
        return scene.isSupported ? scene : nil
    }
    init() {
        // `--export-icons <folder>`: render the app icon and browser icons from the character, then carry on.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-icons"), i + 1 < args.count { MainActor.assumeIsolated { AppIconExport.run(into: args[i + 1]) } }
    }
    var body: some Scene {
        WindowGroup {
            // `--avatars`: a sheet of every mood of the character, for looking at it.
            if let scene = scenePreview { Explorer3DLibrary(store: store, first: scene.model).preferredColorScheme(.light) }
            else if CommandLine.arguments.contains("--avatars") { AvatarSheet().preferredColorScheme(.light) } else {
            LibraryView(store: store)
                .tint(HaloStyle.ink)
                // Halo is ink on paper. Dark Mode would put white text on the light page.
                .preferredColorScheme(.light)
                .task { await store.loadLibrary(); await store.runLaunchScript() }
                .onOpenURL { url in Task { await store.importDocument(url) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { store.lesson.hush(); store.cancelAnswer(); store.speech.stop(); Task { await store.flush(); await store.flushLoose() } }
                }
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
    @State private var pruneSamples = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            sidebar
                .toolbar(removing: .sidebarToggle)   // replaced by the labelled "Library" button
                .navigationTitle("halo.")
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Button { settings = true } label: { BarLabel("Settings", "gearshape") }
                    }
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 330)
        } detail: {
            NavigationStack {
                Group {
                    if store.pdf != nil { StudioView(store: store, openSettings: { settings = true }) }
                    else { welcome }
                }
                .toolbar {
                    // The library is one labelled button, here and on the start screen, instead of a bare sidebar icon.
                    ToolbarItem(placement: .topBarLeading) {
                        Button { withAnimation { columns = columns == .detailOnly ? .all : .detailOnly } } label: { BarLabel("Library", "books.vertical") }
                            .accessibilityHint("Your documents, quick notes and the sample lesson")
                    }
                }
            }
        }
        .onChange(of: store.document?.id) { _, id in compactColumn = id == nil ? .sidebar : .detail }
        // "Sup Halo": on the page or in the notebook, while the app is in front and nothing else is using the microphone.
        .onChange(of: store.wakeAllowed && scenePhase == .active, initial: true) { _, on in store.wake.setEnabled(on) }
        .onAppear {   // for screenshots
            if CommandLine.arguments.contains("--settings") { settings = true }
            if CommandLine.arguments.contains("--library") { columns = .all }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf] + ["ppt", "pptx", "doc", "docx"].compactMap { UTType(filenameExtension: $0) }, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await store.importDocument(url) } }
            case .failure(let error): store.importError = error.localizedDescription
            }
        }
        .alert("Couldn’t import document", isPresented: Binding(get: { store.importError != nil }, set: { if !$0 { store.importError = nil } })) {
            Button("OK") { store.importError = nil }
        } message: { Text(store.importError ?? "") }
        .sheet(isPresented: $settings) { SettingsView(store: store) }
        .fullScreenCover(item: $store.explorer) { Explorer3D(store: store, scene: $0) }
        .fullScreenCover(isPresented: Binding(get: { store.showNotebook }, set: { if !$0 { store.closeNotebook() } })) { NotebookView(store: store) }
        .sheet(isPresented: Binding(get: { store.needsOnboarding }, set: { if !$0 { store.finishOnboarding(nil) } })) { OnboardingView(store: store).interactiveDismissDisabled() }
        .alert("Delete from Halo?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("Cancel", role: .cancel) { deletion = nil }
            Button("Delete", role: .destructive) { if let item = deletion { Task { await store.delete(item) } }; deletion = nil }
        } message: { Text("This removes Halo’s copy and its notes. The original document is unchanged.") }
        .diveBoard(store, when: !store.showNotebook)
        .overlay {
            if store.loading {
                VStack(spacing: 12) { HaloRing(size: 46, working: true); Text(store.openingMessage).font(HaloKit.hand(25)).foregroundStyle(HaloStyle.text) }
                    .padding(.horizontal, 30).padding(.vertical, 24).background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            }
        }
    }
    private var welcome: some View { LandingView(store: store, importPDF: { importing = true }) }

    // MARK: the sidebar: start something, your documents, the sample
    private static let sampleName = "A little calculus"
    private var mine: [LibraryDocument] { store.documents.filter { $0.name != Self.sampleName } }
    private var samples: [LibraryDocument] { store.documents.filter { $0.name == Self.sampleName } }   // newest first

    private var sidebar: some View {
        List {
            Section {
                Button { importing = true } label: {
                    action("plus", "Import a document", tint: HaloStyle.coral, filled: true)
                }.buttonStyle(.plain)
                Button { store.openQuickNotes(); columns = .detailOnly } label: {
                    action("square.and.pencil", "Quick notes", count: store.looseNotes.count, tint: HaloKit.amber)
                }.buttonStyle(.plain)
            }
            .listRowSeparator(.hidden)

            if !mine.isEmpty {
                Section {
                    ForEach(mine) { row($0) }
                } header: { header("Your documents", count: mine.count) }
            }

            Section {
                if let sample = samples.first { row(sample, olderCopies: samples.count - 1) }
                else {
                    Button { Task { await store.openSample(); columns = .detailOnly } } label: {
                        action("play.fill", "Try the sample lesson", tint: HaloStyle.ink)
                    }.buttonStyle(.plain)
                }
            } header: { header("Sample lesson", count: nil) }
        }
        .listStyle(.sidebar)
        .confirmationDialog("Remove older copies of the sample lesson?", isPresented: $pruneSamples, titleVisibility: .visible) {
            Button("Remove \(max(0, samples.count - 1))", role: .destructive) {
                let old = Array(samples.dropFirst())
                Task { for item in old { await store.delete(item) } }
            }
        } message: { Text("The newest copy stays. Notes in the older copies are removed with them.") }
    }
    private func header(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(HaloKit.text(11, .bold)).tracking(1.1).foregroundStyle(.secondary)
            if let count, count > 0 { Text("\(count)").font(HaloKit.text(11, .bold).monospacedDigit()).foregroundStyle(.tertiary) }
        }
    }
    /// One of the things to start with: an icon and its name (and how many there are, for quick notes).
    private func action(_ icon: String, _ title: String, count: Int = 0, tint: Color, filled: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(filled ? .white : tint)
                .frame(width: 34, height: 34).background(filled ? tint : tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(HaloKit.text(15, .semibold)).foregroundStyle(HaloStyle.text)
            Spacer(minLength: 0)
            if count > 0 { Text("\(count)").font(HaloKit.text(13, .semibold).monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3).contentShape(Rectangle())
    }
    /// A document: its clean title, how long it is, when it was last opened. The open one is highlighted.
    private func row(_ item: LibraryDocument, olderCopies: Int = 0) -> some View {
        let open = store.document?.id == item.id
        return Button { Task { await store.open(item); columns = .detailOnly } } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: open ? "book.fill" : "book.closed").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(open ? .white : HaloStyle.coral)
                    .frame(width: 34, height: 34).background(open ? HaloStyle.coral : HaloStyle.coral.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(HaloKit.text(15, open ? .semibold : .medium)).foregroundStyle(HaloStyle.text).lineLimit(2)
                    Text(open ? "\(item.pageCount) pages" : "\(item.pageCount) pages · \(item.lastOpenedAt.formatted(.relative(presentation: .named)))")
                        .font(HaloKit.text(12)).foregroundStyle(open ? HaloStyle.coral : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(open ? HaloStyle.coral.opacity(0.09) : Color.clear)
        .swipeActions(edge: .trailing) { Button("Delete", role: .destructive) { deletion = item } }
        .contextMenu {
            if olderCopies > 0 {
                Button("Remove \(olderCopies) older cop\(olderCopies == 1 ? "y" : "ies")", systemImage: "square.stack", role: .destructive) { pruneSamples = true }
            }
            Button("Delete from Halo", systemImage: "trash", role: .destructive) { deletion = item }
        }
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// A toolbar button label that always shows its word: iPadOS reduces a toolbar `Label` to its icon.
struct BarLabel: View {
    let title: String
    let icon: String
    init(_ title: String, _ icon: String) { self.title = title; self.icon = icon }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium))
            Text(title).font(HaloKit.text(15, .semibold)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 4).contentShape(Rectangle())
    }
}

extension LibraryDocument {
    /// The file name as a title: no extension, no underscores, and none of the "(z-library.sk, 1lib.sk)" a download site leaves behind.
    var displayName: String {
        var title = name.replacingOccurrences(of: #"\.(pdf|pptx?|docx?)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(of: #"[(\[][^)\]]*(z-?lib|1lib|libgen|anna)[^)\]]*[)\]]"#, with: " ", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(of: #"[_\s]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? name : title
    }
}

/// The page, with Halo's margin docked beside it (landscape) or under it (portrait) while a note is open.
@MainActor
struct StudioView: View {
    @ObservedObject var store: StudyStore
    var openSettings: () -> Void
    var body: some View {
        GeometryReader { geometry in
            let session = store.pill != .hidden ? store.activeSession : nil
            let fullHeight = geometry.size.height + geometry.safeAreaInsets.bottom
            // Halo's notes sit to the right of the document, upright or on its side. Only a very narrow window
            // (Split View, Slide Over) puts them underneath, where a side column would leave no room for the page.
            let sideways = geometry.size.width >= 640 || CommandLine.arguments.contains("--sideways")
            let layout = sideways ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                page(pointingTo: session == nil ? nil : (sideways ? Edge.trailing : Edge.bottom))
                if let session {
                    HaloMargin(store: store, session: session, sideways: sideways)
                        .frame(width: sideways ? min(540, max(340, geometry.size.width * 0.42)) : nil,
                               height: sideways ? nil : min(520, max(330, fullHeight * 0.37)))
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
                    Text(store.displayTitle).font(HaloKit.text(17, .semibold)).lineLimit(1)
                    // Where you are, in words: the page, and the chapter when there is one.
                    Text(["Page \(store.pageIndex + 1) of \(store.pdf?.pageCount ?? 0)", store.currentChapter?.title].compactMap { $0 }.joined(separator: " · "))
                        .font(HaloKit.text(11.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: 420)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Every button says what it does (one group, so iPadOS keeps the words). Halo, the avatar, is there for anything else.
                HStack(spacing: 14) {
                    Button { store.openLesson() } label: { BarLabel("Teach me", "graduationcap") }
                        .accessibilityHint("Halo teaches this chapter one idea at a time")
                    Button { store.openNavigator(store.navigatorTab) } label: { BarLabel("Contents", "list.bullet.rectangle") }
                        .accessibilityHint("Chapters, search, and the questions you asked Halo")
                        .popover(isPresented: $store.showNavigator) { NavigatorView(store: store).frame(minWidth: 420, idealWidth: 420, minHeight: 300, idealHeight: 660) }
                    Button { store.openNotebook() } label: { BarLabel("My notes", "square.and.pencil") }
                        .accessibilityHint("Your own notes on this document")
                    Menu {
                        Button { store.openRecap() } label: { Label("Session summary", systemImage: "list.clipboard") }
                        Button { store.showBrief() } label: { Label(store.isBook ? "Halo’s read of this chapter" : "Halo’s read of this document", systemImage: "sparkles") }
                        Divider()
                        Button(action: openSettings) { Label("Settings", systemImage: "gearshape") }
                    } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17, weight: .medium)).padding(.horizontal, 4) }
                    .accessibilityLabel("More: session summary, Halo’s read, settings")
                }
            }
        }
    }
    private var recapCover: Binding<Bool> { Binding(get: { store.showRecap }, set: { if !$0 { store.closeRecap() } }) }

    /// The page and everything that floats over it. A coral arrow runs from the margin to the circle it is about.
    private func page(pointingTo edge: Edge?) -> some View {
        GeometryReader { area in
            ZStack(alignment: .top) {
                PDFReader(store: store).ignoresSafeArea(edges: .bottom)
                // (A question about the whole page has no circle to point at.)
                if let edge, store.activeSession?.region != nil, let anchor = store.anchorFrame, let arrow = arrow(from: edge, to: anchor, in: area.size) {
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
                if edge == nil, store.welcome == nil {
                    // A tap on the page puts Halo's menu away.
                    if store.showLauncher { Color.black.opacity(0.08).ignoresSafeArea().onTapGesture { store.tuckDock() } }
                    VStack {
                        if store.tool == .write { HaloDock(store: store, atTop: true, wide: area.size.width > 860, area: area.size).padding(.top, 12); Spacer() }
                        else { Spacer(); HaloDock(store: store, wide: area.size.width > 860, area: area.size).padding(.bottom, 16) }
                    }
                    .animation(.spring(duration: 0.35), value: store.tool)
                    .transition(.opacity)
                }
                ConfettiBurst(trigger: store.confetti)
                if let error = store.error, store.pill == .hidden {
                    Text(error).font(HaloKit.text(13)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9)
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
}
