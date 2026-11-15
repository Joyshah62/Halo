import SwiftUI
import WebKit
import SafariServices

// "Go deeper": Halo leaves the page and looks the question up on the live web. The board fills in
// as things arrive: what it searched for, an explanation with numbered sources, a video it has
// actually watched (so it can skip to the part that answers the question), and real pictures.
//
// It is also a way down. Halo stays docked under the board with the next question ready: type it,
// say it, tap one of the questions Halo thinks you'll have, or "dig into" any part of the answer.
// Each one takes the board a level deeper, and the line of rings along the top is the way back up.

extension View {
    /// Shows the web board over this view whenever Halo is looking something up.
    func diveBoard(_ store: StudyStore, when shown: Bool = true) -> some View {
        overlay {
            if shown, let dive = store.dive {
                DiveBoard(store: store, dive: dive).transition(.move(edge: .bottom).combined(with: .opacity)).zIndex(10)
            }
        }
    }
}

@MainActor
struct DiveBoard: View {
    @ObservedObject var store: StudyStore
    let dive: DeepDive
    @State private var followUp = ""
    @State private var zoomed: DiveImage?
    @State private var link: WebLink?
    @State private var spin = false
    @State private var playerFailed = false
    @State private var ideasOpen = true
    @FocusState private var asking: Bool

    private struct WebLink: Identifiable { let url: URL; var id: String { url.absoluteString } }
    private static let highlight = HaloKit.highlight

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 940
            ZStack {
                // Each dive is its own page: a deeper one rises from below while the last one falls away, and it opens at the top.
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        way
                        header
                        trail
                        if let error = dive.error { failure(error) }
                        if wide {
                            HStack(alignment: .top, spacing: 30) {
                                VStack(alignment: .leading, spacing: 24) { explanation; sources }.frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading, spacing: 26) { videoPanel; pictures }.frame(width: min(500, geometry.size.width * 0.41))
                            }
                        } else {
                            videoPanel; explanation; pictures; sources
                        }
                    }
                    .padding(.horizontal, wide ? 44 : 22).padding(.top, 30).padding(.bottom, 24)
                    .frame(maxWidth: 1240).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .id(dive.id)
                .transition(.asymmetric(insertion: .offset(y: 110).combined(with: .opacity), removal: .scale(scale: 0.94, anchor: .top).combined(with: .opacity)))
                // While the next question is being typed, what is on the board steps back.
                if asking {
                    HaloStyle.text.opacity(0.16).ignoresSafeArea().onTapGesture { asking = false }.transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .animation(.easeOut(duration: 0.2), value: asking)
        }
        .background(DeskPaper().ignoresSafeArea())
        .overlay { if let zoomed { viewer(zoomed) } }
        .sheet(item: $link) { SafariPage(url: $0.url).ignoresSafeArea() }
        .onChange(of: "\(dive.selected ?? "")@\(dive.playFrom)@\(dive.playing)") { _, _ in playerFailed = false }
        .onChange(of: dive.id) { _, _ in zoomed = nil; ideasOpen = true }
        .onChange(of: dive.answer != nil) { _, found in if found { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
        .onAppear { spin = true; RemoteImageCache.relay = try? HaloClient.endpoint(store.serverURL, path: "api/dive/picture") }
    }

    // MARK: the way down
    /// Every dive on this trip as a line of rings, the one on show filled in. Tap one to come back up to it.
    @ViewBuilder private var way: some View {
        let all = store.diveBack + [dive] + store.diveAhead
        if all.count > 1 {
            ScrollViewReader { line in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Label("\(store.diveBack.count + 1) deep", systemImage: "arrow.down").labelStyle(.titleAndIcon)
                        .font(HaloKit.text(11, .bold)).textCase(.uppercase).tracking(1.1).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(HaloStyle.coral, in: Capsule()).padding(.trailing, 14)
                        .contentTransition(.numericText())
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, item in
                        let here = item.id == dive.id, ahead = index > store.diveBack.count
                        if index > 0 {
                            Capsule().fill(HaloStyle.coral.opacity(ahead ? 0.18 : 0.4)).frame(width: 24, height: 2.5).padding(.horizontal, 8)
                        }
                        Button { store.revisitDive(item.id) } label: {
                            HStack(spacing: 7) {
                                Circle().fill(here ? HaloStyle.coral : Color.white).frame(width: 13, height: 13)
                                    .overlay(Circle().stroke(HaloStyle.coral.opacity(ahead ? 0.45 : 1), lineWidth: 2.5))
                                Text(item.plan?.title ?? item.question).hand(here ? 24 : 22)
                                    .foregroundStyle(here ? HaloStyle.text : HaloStyle.ink.opacity(ahead ? 0.55 : 1)).lineLimit(1).frame(maxWidth: here ? 460 : 220, alignment: .leading).fixedSize()
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).allowsHitTesting(!here).id(item.id)
                        .accessibilityLabel(here ? "You are here: \(item.plan?.title ?? item.question)" : "Back to \(item.plan?.title ?? item.question)")
                    }
                }.padding(.vertical, 2)
            }
            // A long way down still opens on where you are.
            .onAppear { line.scrollTo(dive.id, anchor: .trailing) }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle().stroke(HaloStyle.coral.opacity(0.18), lineWidth: 6)
                Circle().trim(from: 0, to: dive.searching ? 0.28 : 1)
                    .stroke(HaloStyle.coral, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(dive.searching && spin ? 360 : 0))
                    .animation(dive.searching ? .linear(duration: 1.1).repeatForever(autoreverses: false) : .spring(duration: 0.6), value: spin)
                    .animation(.spring(duration: 0.6), value: dive.searching)
                Image(systemName: dive.searching ? "globe" : "checkmark").font(.system(size: 20, weight: .semibold)).foregroundStyle(HaloStyle.coral)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 58, height: 58).padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(dive.searching ? "HALO IS LOOKING THIS UP" : "HALO WENT AND FOUND OUT").font(HaloKit.text(11, .bold)).tracking(1.4).foregroundStyle(HaloStyle.coral)
                Text(dive.plan?.title ?? dive.question).font(HaloKit.title(38, .regular)).foregroundStyle(HaloStyle.text)
                    .lineLimit(2).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
                if dive.plan != nil {
                    Text("“\(dive.question)”").hand(24).foregroundStyle(HaloStyle.ink).lineLimit(2)
                }
                if let caption = dive.caption {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 14, weight: .semibold)).foregroundStyle(HaloStyle.coral)
                            .symbolEffect(.variableColor.iterative, isActive: true).padding(.top, 3)
                        Text(caption).font(HaloKit.text(15.5)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HaloStyle.coral.opacity(0.25)))
                    .padding(.top, 4).transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if dive.answer != nil {
                    Button { store.saveDive() } label: {
                        Label(dive.saved ? "In your notes" : "Save to my notes", systemImage: dive.saved ? "checkmark" : "square.and.arrow.down")
                            .font(HaloKit.text(14, .semibold)).lineLimit(1).fixedSize().padding(.horizontal, 14).padding(.vertical, 9)
                            .background(dive.saved ? Color.white : HaloStyle.ink, in: Capsule())
                            .overlay(Capsule().stroke(HaloStyle.ink.opacity(dive.saved ? 0.25 : 0)))
                            .foregroundStyle(dive.saved ? HaloStyle.ink : .white)
                    }.buttonStyle(.plain).disabled(dive.saved).transition(.scale.combined(with: .opacity))
                }
                HomeButton { Task { await store.goHome() } }
                Button { store.closeDive() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38)
                        .background(Color.white, in: Circle()).overlay(Circle().stroke(HaloStyle.ink.opacity(0.12))).foregroundStyle(HaloStyle.text)
                }.buttonStyle(.plain).accessibilityLabel("Close")
            }
        }
    }

    // MARK: what Halo is doing, live
    private struct Step: Identifiable { let id: String; let text: String; let done: Bool; let icon: String }
    private var steps: [Step] {
        var list: [Step] = []
        guard let plan = dive.plan else { return [Step(id: "plan", text: "working out what to look for…", done: false, icon: "sparkle.magnifyingglass")] }
        if let answer = dive.answer {
            let sites = Array(NSOrderedSet(array: answer.sources.map(\.site))).compactMap { $0 as? String }.prefix(3).joined(separator: ", ")
            list.append(Step(id: "web", text: answer.sources.isEmpty ? "searched the web" : "read \(answer.sources.count) page\(answer.sources.count == 1 ? "" : "s"): \(sites)", done: true, icon: "magnifyingglass"))
        } else { list.append(Step(id: "web", text: "searching: \(plan.web)", done: false, icon: "magnifyingglass")) }
        if let videos = dive.videos {
            if !videos.isEmpty { list.append(Step(id: "videos", text: "found \(videos.count) video\(videos.count == 1 ? "" : "s")", done: true, icon: "play.rectangle")) }
        } else { list.append(Step(id: "videos", text: "YouTube: \(plan.video)", done: false, icon: "play.rectangle")) }
        for video in dive.videos ?? [] {
            if dive.watching.contains(video.id) { list.append(Step(id: "watch" + video.id, text: "watching \(video.channel.isEmpty ? "the video" : video.channel)’s video…", done: false, icon: "eye")) }
            else if let moment = dive.moments[video.id] { list.append(Step(id: "watch" + video.id, text: "watched it: your answer is at \(moment.clock)", done: true, icon: "eye")) }
        }
        if let images = dive.images {
            if !images.isEmpty { list.append(Step(id: "images", text: "picked \(images.count) picture\(images.count == 1 ? "" : "s")", done: true, icon: "photo")) }
        } else { list.append(Step(id: "images", text: "pictures: \(plan.image)", done: false, icon: "photo")) }
        return list
    }
    private var trail: some View {
        FlowRow(spacing: 9) {
            ForEach(steps) { step in
                HStack(spacing: 7) {
                    ZStack {
                        if step.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.13, green: 0.55, blue: 0.35)).transition(.scale.combined(with: .opacity)) }
                        else { Image(systemName: step.icon).foregroundStyle(HaloStyle.coral).symbolEffect(.pulse, isActive: true) }
                    }.font(HaloKit.text(14, .semibold)).frame(width: 18)
                    Text(step.text).hand(21).foregroundStyle(HaloStyle.text.opacity(step.done ? 0.75 : 1)).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.white.opacity(step.done ? 0.6 : 0.95), in: Capsule())
                .overlay(Capsule().stroke(step.done ? HaloStyle.ink.opacity(0.08) : HaloStyle.coral.opacity(0.35)))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: steps.map { $0.id + ($0.done ? "1" : "0") })
    }
    private func failure(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.red)
            Text(message).font(HaloKit.text(15)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Try again") { store.startDive(dive.question, context: dive.context, deeper: true) }.font(HaloKit.text(14, .semibold)).foregroundStyle(HaloStyle.ink)
        }
        .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.red.opacity(0.25)))
    }

    // MARK: the explanation, with its sources
    @ViewBuilder private var explanation: some View {
        if let answer = dive.answer {
            VStack(alignment: .leading, spacing: 22) {
                if let scene = answer.scene3d, scene.isSupported { Scene3DCard(store: store, scene: scene) }
                ForEach(Array(answer.sections.enumerated()), id: \.offset) { index, section in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)").font(.custom("Caveat-Regular", size: 34)).foregroundStyle(HaloStyle.coral).frame(width: 24, alignment: .leading).offset(y: -6)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.heading).font(HaloKit.title(22, .semibold)).foregroundStyle(HaloStyle.text).fixedSize(horizontal: false, vertical: true)
                            Text(section.text).font(HaloKit.text(17)).foregroundStyle(HaloStyle.text.opacity(0.88)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            FlowRow(spacing: 6) {
                                ForEach(section.cites, id: \.self) { n in
                                    if answer.sources.indices.contains(n - 1) {
                                        let source = answer.sources[n - 1]
                                        Button { open(source.url) } label: {
                                            HStack(spacing: 5) {
                                                Text("\(n)").font(HaloKit.text(10.5, .bold)).foregroundStyle(.white).frame(width: 17, height: 17).background(HaloStyle.ink, in: Circle())
                                                Text(source.site).font(HaloKit.text(12.5, .medium)).foregroundStyle(HaloStyle.ink).lineLimit(1)
                                            }
                                            .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 3.5).background(HaloStyle.ink.opacity(0.07), in: Capsule())
                                        }.buttonStyle(.plain)
                                    }
                                }
                                // Every part of the answer is a door to the next level down.
                                Button { go("Go deeper: \(section.heading)", about: "\(section.heading). \(section.text)") } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.turn.down.right").font(.system(size: 10.5, weight: .bold))
                                        Text("dig into this").hand(21)
                                    }
                                    .foregroundStyle(HaloStyle.coral).padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Dig into \(section.heading)")
                            }.padding(.top, 2)
                        }
                    }
                }
                if !answer.takeaway.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("KEEP THIS").font(HaloKit.text(10.5, .bold)).tracking(1.2).foregroundStyle(HaloStyle.text.opacity(0.5))
                        Text(answer.takeaway).hand(28).foregroundStyle(HaloStyle.text).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Self.highlight, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 4).rotationEffect(.degrees(-0.7)).padding(.top, 4)
                }
            }
            .padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
            .transition(.opacity.combined(with: .offset(y: 24)))
        } else if dive.error == nil {
            VStack(alignment: .leading, spacing: 14) {
                Text(dive.plan == nil ? "Thinking about your question…" : "Reading what the web says…").hand(26).foregroundStyle(HaloStyle.ink)
                ForEach(0..<7, id: \.self) { row in
                    RoundedRectangle(cornerRadius: 5).fill(HaloStyle.ink.opacity(0.07)).frame(height: 13).frame(maxWidth: row % 3 == 2 ? 300 : .infinity, alignment: .leading)
                }
            }
            .padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .modifier(Breathing())
        }
    }
    @ViewBuilder private var sources: some View {
        if let list = dive.answer?.sources, !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                label("WHERE THIS CAME FROM")
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.offset) { index, source in
                        Button { open(source.url) } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)").font(HaloKit.text(11.5, .bold)).foregroundStyle(.white).frame(width: 21, height: 21).background(HaloStyle.ink, in: Circle())
                                RemoteImage(url: URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(source.site)"), fill: false) { _ in Image(systemName: "globe").foregroundStyle(.secondary) }
                                    .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(source.title).font(HaloKit.text(15, .medium)).foregroundStyle(HaloStyle.text).lineLimit(1)
                                    Text(source.site).font(HaloKit.text(12.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(HaloStyle.ink.opacity(0.5))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if index < list.count - 1 { Divider().padding(.leading, 49) }
                    }
                }
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 12, y: 5)
            }.transition(.opacity.combined(with: .offset(y: 24)))
        }
    }

    // MARK: the video Halo watched
    @ViewBuilder private var videoPanel: some View {
        if let video = dive.video {
            VStack(alignment: .leading, spacing: 12) {
                label("WATCH IT EXPLAINED")
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        if dive.playing {
                            YouTubePlayer(id: video.id, start: dive.playFrom, failed: { playerFailed = true }).id("\(video.id)@\(dive.playFrom)")
                                .overlay(alignment: .bottomLeading) {
                                    // Always a way out if the network won't play it here.
                                    Button { openInYouTube(video, at: dive.playFrom) } label: {
                                        Label(playerFailed ? "Couldn’t play here. Open in YouTube" : "Open in YouTube", systemImage: "arrow.up.right.square")
                                            .font(HaloKit.text(12.5, .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(playerFailed ? HaloStyle.coral : Color.black.opacity(0.55), in: Capsule()).foregroundStyle(.white)
                                    }.buttonStyle(.plain).padding(10)
                                }
                        } else {
                            Button { store.playVideo(from: 0) } label: {
                                ZStack {
                                    Color.black
                                    RemoteImage(url: video.thumbnail, fill: true) { _ in Color.black }
                                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                                    Image(systemName: "play.fill").font(.system(size: 26)).foregroundStyle(HaloStyle.coral).offset(x: 2)
                                        .frame(width: 68, height: 68).background(.white, in: Circle()).shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                                    if !video.length.isEmpty {
                                        Text(video.length).font(HaloKit.text(12, .semibold).monospacedDigit()).foregroundStyle(.white)
                                            .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
                                    }
                                }
                            }.buttonStyle(.plain).accessibilityLabel("Play \(video.title)")
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit).clipped()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.title).font(HaloKit.text(16.5, .semibold)).foregroundStyle(HaloStyle.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text([video.channel, video.views].filter { !$0.isEmpty }.joined(separator: " · ")).font(HaloKit.text(13)).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
                    watchedNote(video)
                }
                .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
                if let others = dive.videos, others.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(others) { other in
                                Button { store.selectVideo(other) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        RemoteImage(url: other.thumbnail, fill: true) { _ in Color.black.opacity(0.1) }
                                            .frame(width: 148, height: 83).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(HaloStyle.coral, lineWidth: other.id == video.id ? 3 : 0))
                                        Text(other.title).font(HaloKit.text(12, .medium)).foregroundStyle(HaloStyle.text).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(other.length).font(HaloKit.text(11).monospacedDigit()).foregroundStyle(.secondary)
                                    }.frame(width: 148, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 2).padding(.horizontal, 2)
                    }
                }
            }.transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
        } else if dive.videos == nil, dive.error == nil {
            VStack(alignment: .leading, spacing: 12) {
                label("WATCH IT EXPLAINED")
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white)
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle").font(.system(size: 30)).foregroundStyle(HaloStyle.coral.opacity(0.7))
                        Text("Finding a video worth your time…").hand(23).foregroundStyle(HaloStyle.ink)
                    }
                }.aspectRatio(16 / 9, contentMode: .fit).modifier(Breathing())
            }
        }
    }
    /// The strip under the video: Halo is watching it, or has, and can skip to the part that matters.
    @ViewBuilder private func watchedNote(_ video: DiveVideo) -> some View {
        if let moment = dive.moments[video.id] {
            Button { store.playVideo(from: moment.start) } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(spacing: 1) {
                        Image(systemName: "forward.fill").font(.system(size: 13, weight: .bold))
                        Text(moment.clock).font(HaloKit.text(15, .bold).monospacedDigit())
                    }
                    .foregroundStyle(.white).frame(width: 62, height: 50).background(HaloStyle.coral, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HALO WATCHED THIS FOR YOU").font(HaloKit.text(10, .bold)).tracking(1.1).foregroundStyle(HaloStyle.coral)
                        Text("Skip to \(moment.clock): it \(moment.why.prefix(1).lowercased() + moment.why.dropFirst())").hand(22).foregroundStyle(HaloStyle.text)
                            .lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(HaloStyle.coral.opacity(0.09))
            }.buttonStyle(.plain).transition(.move(edge: .bottom).combined(with: .opacity))
        } else if dive.watching.contains(video.id) {
            HStack(spacing: 10) {
                Image(systemName: "eye").font(.system(size: 16, weight: .semibold)).foregroundStyle(HaloStyle.coral).symbolEffect(.pulse, isActive: true)
                Text("Halo is watching this for you, to find the part you need…").hand(21).foregroundStyle(HaloStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).background(HaloStyle.ink.opacity(0.05))
            .transition(.opacity)
        }
    }

    // MARK: real pictures, pinned like prints
    @ViewBuilder private var pictures: some View {
        if let images = dive.images, !images.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                label("SEE IT")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], alignment: .center, spacing: 22) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        Button { withAnimation(.spring(duration: 0.35)) { zoomed = image } } label: { print(image, tilt: [-2.2, 1.6, 1.9, -1.4][index % 4]) }
                            .buttonStyle(.plain).transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
        } else if dive.images == nil, dive.error == nil, dive.plan != nil {
            VStack(alignment: .leading, spacing: 14) {
                label("SEE IT")
                HStack(spacing: 18) {
                    ForEach(0..<2, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3).fill(Color.white).frame(height: 150).rotationEffect(.degrees(i == 0 ? -2.2 : 1.6)).shadow(color: .black.opacity(0.08), radius: 8, y: 4)
                    }
                }.modifier(Breathing())
            }
        }
    }
    private func print(_ image: DiveImage, tilt: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            RemoteImage(url: URL(string: image.thumb), fill: false) { failed in
                Rectangle().fill(HaloStyle.ink.opacity(0.06)).overlay { if failed { Image(systemName: "photo").foregroundStyle(.secondary) } else { ProgressView() } }
            }
            .frame(maxWidth: .infinity).frame(height: 150).background(Color(white: 0.97))
            Text(image.title).hand(19).foregroundStyle(HaloStyle.text).lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        }
        .padding(.horizontal, 9).padding(.top, 9).padding(.bottom, 8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 5)
        .overlay(alignment: .top) {
            // A strip of tape.
            RoundedRectangle(cornerRadius: 1.5).fill(Self.highlight.opacity(0.85)).frame(width: 62, height: 19).rotationEffect(.degrees(-tilt * 1.6)).offset(y: -9)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        }
        .rotationEffect(.degrees(tilt))
    }
    private func viewer(_ image: DiveImage) -> some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea().onTapGesture { withAnimation(.easeOut(duration: 0.2)) { zoomed = nil } }
            VStack(spacing: 14) {
                RemoteImage(url: URL(string: image.thumb), fill: false) { _ in ProgressView().tint(.white).frame(width: 200, height: 200) }
                    .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).frame(maxWidth: 900, maxHeight: 620)
                Text(image.title).hand(28).foregroundStyle(.white).multilineTextAlignment(.center)
                HStack(spacing: 14) {
                    Text([image.credit, image.license, "Wikimedia Commons"].filter { !$0.isEmpty }.joined(separator: " · ")).font(HaloKit.text(13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    if !image.page.isEmpty { Button("See the original") { zoomed = nil; open(image.page) }.font(HaloKit.text(13, .semibold)).foregroundStyle(.white) }
                }
                Button { zoomed = nil; go("Explain this picture: \(image.title)", about: "A picture they were shown, titled “\(image.title)”.") } label: {
                    Label("Ask Halo about this", systemImage: "arrow.turn.down.right")
                }.buttonStyle(PillButtonStyle())
            }.padding(34).allowsHitTesting(true)
        }.transition(.opacity).zIndex(5)
    }

    // MARK: keep going
    private var typed: String { followUp.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Where to go from here: the questions Halo expects next, then two that work for anything.
    private var ideas: [String] {
        guard let answer = dive.answer else { return [] }
        var list = (answer.next ?? []).filter { !$0.isEmpty }
        if list.isEmpty { list = answer.sections.prefix(2).map { "More on “\($0.heading)”" } }
        // Halo's three questions on their own (the stock ones only fill in when it has fewer): they wrap rather than scroll, and three fit in two lines on a 10.5-inch iPad.
        return Array((list + ["Explain it more simply", "Give me a real-world example"]).prefix(max(3, min(list.count, 4))))
    }
    private var showIdeas: Bool { ideasOpen && !ideas.isEmpty && typed.isEmpty && !store.diveListening && !dive.playing }
    /// Halo is busy with this bar: hearing a question, or still putting the answer together.
    private var alive: Bool { store.diveListening || (dive.answer == nil && dive.error == nil) }

    /// Halo, docked under the board whatever is on it, with the next question ready to go.
    private var dock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showIdeas {
                // Wrapped onto as many lines as they need, so every question can be read whole on a 10.5-inch iPad.
                FlowRow(spacing: 8) {
                    ForEach(Array(ideas.enumerated()), id: \.element) { index, idea in
                        Button { go(idea) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .bold)).foregroundStyle(HaloStyle.coral)
                                Text(idea).hand(21).foregroundStyle(HaloStyle.ink).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color.white, in: Capsule()).overlay(Capsule().stroke(HaloStyle.ink.opacity(0.12)))
                            .shadow(color: .black.opacity(0.1), radius: 7, y: 3)
                        }.buttonStyle(.plain).arrives(index)
                    }
                }
                .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                .id(dive.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 12) {
                Button { withAnimation(.spring(duration: 0.35, bounce: 0.2)) { ideasOpen.toggle() } } label: {
                    TutorAvatar(cue: store.diveCue, size: 86, voiceLevel: { [store] in store.player.outputLevel }, micLevel: { [store] in CGFloat(store.speech.meter.value) })
                        .offset(y: -4).frame(width: 66, height: 66)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().stroke(HaloStyle.coral.opacity(alive ? 0.6 : 0.18), lineWidth: 2))
                        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                }
                .buttonStyle(.plain).disabled(ideas.isEmpty)
                .accessibilityLabel(showIdeas ? "Halo. Put its ideas away" : "Halo. Ideas for what to ask next")
                bar
            }
        }
        .frame(maxWidth: 840).frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 12)
        // The board fades out under the dock instead of being cut off by it.
        .background {
            LinearGradient(stops: [.init(color: HaloStyle.paper.opacity(0), location: 0), .init(color: HaloStyle.paper.opacity(0.95), location: 0.14), .init(color: HaloStyle.paper, location: 0.3), .init(color: HaloStyle.paper, location: 1)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        }
        .animation(.spring(duration: 0.4, bounce: 0.18), value: showIdeas)
        .animation(.spring(duration: 0.3), value: typed.isEmpty)
    }
    private var bar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.diveListening, !store.diveHeard.isEmpty {
                Text(store.diveHeard).font(HaloKit.text(17))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HaloComposer(text: $followUp, recording: store.diveListening,
                         microphone: { store.listenForDive() }, focus: $asking, send: send)
        }
    }
    private func send() { if !typed.isEmpty { go(typed) } }
    /// One level down, from wherever it was asked: the bar, an idea, a part of the answer, a picture.
    private func go(_ question: String, about part: String = "") {
        followUp = ""; asking = false
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        store.diveDeeper(question, about: part)
    }

    private func openInYouTube(_ video: DiveVideo, at start: Int) {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)&t=\(max(0, start))s") else { return }
        UIApplication.shared.open(url)
    }
    private func label(_ text: String) -> some View {
        Text(text).font(HaloKit.text(11, .bold)).tracking(1.3).foregroundStyle(HaloStyle.text.opacity(0.5)).padding(.leading, 4)
    }
    private func open(_ address: String) {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        link = WebLink(url: url)
    }
}

/// The rim of the ask bar. While Halo is listening or searching, its colours run round the rim like a halo.
private struct HaloEdge: View {
    var alive: Bool
    var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if alive, !reduceMotion {
            TimelineView(.animation) { timeline in
                let turn = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6 * 360
                let sweep = AngularGradient(colors: [HaloStyle.coral, HaloKit.highlight, HaloStyle.ink, HaloStyle.coral.opacity(0.2), HaloStyle.coral], center: .center, angle: .degrees(turn))
                ZStack {
                    Capsule().strokeBorder(sweep, lineWidth: 6).blur(radius: 8).opacity(0.75)
                    Capsule().strokeBorder(sweep, lineWidth: 2.5)
                }
            }
            .transition(.opacity)
        } else {
            Capsule().strokeBorder(focused || alive ? HaloStyle.coral.opacity(0.6) : HaloStyle.ink.opacity(0.12), lineWidth: focused || alive ? 1.5 : 1)
        }
    }
}

/// A soft ring behind the microphone button that swells with the student's voice.
private struct MicPulse: View {
    let meter: LevelMeter
    var body: some View {
        TimelineView(.animation) { _ in
            Circle().fill(HaloStyle.coral.opacity(0.25)).scaleEffect(1.12 + 0.6 * CGFloat(meter.value))
        }
    }
}

/// A picture from the web. Loaded once and remembered, and tried again if the first attempt fails
/// (the board redraws often while results arrive, which makes AsyncImage give up).
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    let fill: Bool
    @ViewBuilder var placeholder: (_ failed: Bool) -> Placeholder
    @State private var picture: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let picture {
                if fill { Color.clear.overlay { Image(uiImage: picture).resizable().scaledToFill() }.clipped() }
                else { Image(uiImage: picture).resizable().scaledToFit() }
            } else { placeholder(failed) }
        }
        .task(id: url) {
            guard let url else { failed = true; return }
            picture = RemoteImageCache.known(url); failed = false
            if picture != nil { return }
            // The download belongs to the cache, not to this view, so a redraw can't cut it short.
            let image = await RemoteImageCache.load(url)
            if let image { withAnimation(.easeOut(duration: 0.25)) { picture = image } } else if !Task.isCancelled { failed = true }
        }
    }
}
@MainActor
enum RemoteImageCache {
    private static let images = NSCache<NSURL, UIImage>()
    private static var loading: [URL: Task<UIImage?, Never>] = [:]
    /// The Halo server's picture route, set by the board when it opens.
    static var relay: URL?
    static func known(_ url: URL) -> UIImage? { images.object(forKey: url as NSURL) }
    static func load(_ url: URL) async -> UIImage? {
        if let image = known(url) { return image }
        if let running = loading[url] { return await running.value }
        let server = relay
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            // Straight from the web first; if this network can't reach that host, the Halo server fetches it instead.
            var through: URL?
            if let base = server, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) {
                parts.queryItems = [URLQueryItem(name: "u", value: url.absoluteString)]; through = parts.url
            }
            for source in [url, through, url].compactMap({ $0 }) {
                var request = URLRequest(url: source); request.timeoutInterval = 12
                if let (data, _) = try? await URLSession.shared.data(for: request), let image = UIImage(data: data) { return image }
            }
            return nil
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// A YouTube video playing in place, from a given second. YouTube asks apps to say who is embedding
/// the player (a Referer), or it refuses to play; so the embed page is requested directly with one.
private struct YouTubePlayer: UIViewRepresentable {
    let id: String
    let start: Int
    var failed: () -> Void = {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let failed: () -> Void
        init(_ failed: @escaping () -> Void) { self.failed = failed }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
        private func report(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            print("[video] could not load the player:", error.localizedDescription); failed()
        }
        // Taps on "Watch on YouTube" and the like leave the app instead of replacing the player.
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url { UIApplication.shared.open(url); decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(failed) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = false; view.scrollView.contentInsetAdjustmentBehavior = .never
        let origin = "https://\((Bundle.main.bundleIdentifier ?? "halo.app").lowercased())"
        var parts = URLComponents(string: "https://www.youtube.com/embed/\(id)")!
        parts.queryItems = [("playsinline", "1"), ("autoplay", "1"), ("start", "\(max(0, start))"), ("rel", "0"), ("origin", origin)].map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: parts.url!)
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        view.load(request)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.loadHTMLString("", baseURL: nil) }
}

/// A source opened inside the app, so the student never leaves their work.
private struct SafariPage: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(HaloStyle.ink)
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
