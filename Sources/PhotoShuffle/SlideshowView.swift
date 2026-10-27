import SwiftUI
import AppKit
import AVFoundation
import Combine

enum ChipPopover: Hashable {
    case person, label, year, speed
}

extension Binding where Value == ChipPopover? {
    func isPresent(_ kind: ChipPopover) -> Binding<Bool> {
        Binding<Bool>(
            get: { self.wrappedValue == kind },
            set: { newValue in
                if newValue {
                    self.wrappedValue = kind
                } else if self.wrappedValue == kind {
                    self.wrappedValue = nil
                }
            }
        )
    }
}

struct SlideshowView: View {
    @ObservedObject var model: SlideshowModel
    @EnvironmentObject var app: AppState
    @EnvironmentObject var indexer: Indexer
    @AppStorage(Keys.kenBurns) var kenBurns = true
    @AppStorage(Keys.videoSound) var videoSound = false
    @AppStorage(Keys.slideSeconds) var slideSeconds = 6.0
    @AppStorage(Keys.includeVideos) var includeVideos = true

    @State var controlsVisible = true
    @State var hideTask: DispatchWorkItem?
    @State var monitor: Any?
    @State var popover: ChipPopover?

    var body: some View {
        ZStack {
            Color.black

            if let slide = model.current {
                SlideView(slide: slide, duration: slideSeconds, kenBurns: kenBurns, videoSound: videoSound) {
                    model.videoEnded(slide.id)
                }
                .id(slide.id)
                .transition(.opacity)
                .onTapGesture(count: 2) { toggleFullScreen() }
            } else {
                EmptySlideshowView(model: model)
            }

            controls
                .opacity(controlsVisible || model.current == nil ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: controlsVisible)

            shortcuts
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel]) { event in
                pokeControls()
                return event
            }
            model.activate()
            pokeControls()
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            hideTask?.cancel()
            model.deactivate()
        }
        .onReceive(indexer.$libraryVersion.dropFirst()) { _ in
            model.libraryChanged()
        }
        .onChange(of: includeVideos) { _ in model.restart() }
        .onChange(of: slideSeconds) { _ in model.timingChanged() }
        .onChange(of: popover) { value in
            if value == nil { pokeControls() }
        }
    }

    // MARK: Overlay

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if let slide = model.current {
                    SlideInfoView(slide: slide)
                }
                Spacer()
                if model.matchCount > 0 {
                    Text("\(Fmt.number(model.matchCount)) фото")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(20)
            .background(
                LinearGradient(colors: [Color.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )

            Spacer()

            VStack(spacing: 12) {
                FilterBar(model: model, popover: $popover, openPeople: { app.tab = .people })
                ControlBar(model: model, popover: $popover)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
            .padding(.top, 40)
            .background(
                LinearGradient(colors: [.clear, Color.black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
        }
        .foregroundColor(.white)
    }

    private var shortcuts: some View {
        ZStack {
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.next() }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.prev() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.toggleFavorite() }.keyboardShortcut("f", modifiers: [])
            Button("") { model.hideCurrent() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { toggleFullScreen() }.keyboardShortcut(.return, modifiers: [])
            Button("") { exitFullScreenIfNeeded() }.keyboardShortcut(.escape, modifiers: [])
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func pokeControls() {
        if !controlsVisible { controlsVisible = true }
        hideTask?.cancel()
        let task = DispatchWorkItem {
            if popover == nil && model.current != nil {
                controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: task)
    }
}

// MARK: - Slide

struct SlideView: View {
    let slide: SlideshowModel.Slide
    let duration: Double
    let kenBurns: Bool
    let videoSound: Bool
    let onVideoEnd: () -> Void

    @State var zoomed = false
    @State var showLive = false
    @State var anchor: UnitPoint = SlideView.anchors.randomElement() ?? .center

    private static let anchors: [UnitPoint] = [.center, .topLeading, .topTrailing, .bottomLeading, .bottomTrailing,
                                               .top, .bottom, .leading, .trailing]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let backdrop = slide.backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .opacity(0.5)
                        .clipped()
                }

                if slide.item.isVideo {
                    ZStack {
                        if let poster = slide.image {
                            Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
                        }
                        VideoPlayerView(url: slide.item.url, muted: !videoSound, onEnd: onVideoEnd)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else if let image = slide.image {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                        if showLive, let live = slide.item.livePath {
                            VideoPlayerView(url: URL(fileURLWithPath: live), muted: true, onEnd: {
                                withAnimation(.easeOut(duration: 0.6)) { showLive = false }
                            })
                            .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(kenBurns && zoomed ? 1.08 : 1.0, anchor: anchor)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear {
            if kenBurns && !slide.item.isVideo {
                DispatchQueue.main.async {
                    withAnimation(.linear(duration: duration + 2.5)) { zoomed = true }
                }
            }
            if !slide.item.isVideo && slide.item.livePath != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation(.easeIn(duration: 0.35)) { showLive = true }
                }
            }
        }
    }
}

struct SlideInfoView: View {
    let slide: SlideshowModel.Slide

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let date = slide.item.date {
                Text(Fmt.date(date))
                    .font(.system(size: 19, weight: .semibold))
            }
            HStack(spacing: 6) {
                Image(systemName: slide.item.isVideo ? "video.fill" : (slide.item.livePath != nil ? "livephoto" : "folder.fill"))
                    .font(.system(size: 11))
                Text(slide.item.folderName)
                    .lineLimit(1)
                if !slide.names.isEmpty {
                    Text("·")
                    Text(slide.names.joined(separator: ", "))
                        .lineLimit(1)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .opacity(0.85)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 520, alignment: .leading)
    }
}

struct EmptySlideshowView: View {
    @ObservedObject var model: SlideshowModel
    @EnvironmentObject var indexer: Indexer

    var body: some View {
        VStack(spacing: 14) {
            switch indexer.phase {
            case .diskMissing:
                Image(systemName: "externaldrive.badge.xmark").font(.system(size: 54, weight: .light))
                Text("Подключите диск с фотографиями").font(.title2.weight(.semibold))
                Text("Показ начнётся сам, как только диск появится").foregroundColor(.secondary)
            case .scanning(let n):
                ProgressView()
                Text("Ищем фото на диске…").font(.title2.weight(.semibold))
                Text("Найдено: \(Fmt.number(n))").foregroundColor(.secondary).monospacedDigit()
            default:
                if model.isLoading {
                    ProgressView()
                } else if model.filter.isDefault {
                    Image(systemName: "photo").font(.system(size: 54, weight: .light))
                    Text("Фото пока нет").font(.title2.weight(.semibold))
                    Text("Проверьте папку в настройках").foregroundColor(.secondary)
                } else {
                    Image(systemName: "magnifyingglass").font(.system(size: 48, weight: .light))
                    Text("По этому фильтру пока ничего нет").font(.title2.weight(.semibold))
                    Text(indexer.phase.isWorking ? "Фото ещё анализируются — загляните чуть позже" : "Попробуйте другой фильтр")
                        .foregroundColor(.secondary)
                    Button("Показать все фото") { model.filter = SlideFilter() }
                        .buttonStyle(CapsuleButtonStyle())
                        .padding(.top, 6)
                }
            }
        }
        .foregroundColor(.white)
        .padding(.bottom, 120)
    }
}

// MARK: - Bottom bars

struct Chip: View {
    let title: String
    let icon: String
    let selected: Bool
    var dropdown = false
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if dropdown {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundColor(selected ? .black : .white)
            .background(Capsule().fill(selected ? Color.white : Color.white.opacity(hover ? 0.2 : 0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct FilterBar: View {
    @ObservedObject var model: SlideshowModel
    @Binding var popover: ChipPopover?
    let openPeople: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MediaCategory.chips) { category in
                    Chip(title: category.title, icon: category.icon, selected: model.filter.isCategory(category.id)) {
                        model.selectCategory(category.id)
                    }
                }

                Divider().frame(height: 18).padding(.horizontal, 2)

                Chip(title: model.personTitle, icon: "person.crop.circle", selected: model.filter.personId != nil, dropdown: true) {
                    popover = .person
                }
                .popover(isPresented: $popover.isPresent(.person), arrowEdge: .top) {
                    PersonPickerPopover(model: model, close: { popover = nil }, openPeople: openPeople)
                }

                Chip(title: model.labelTitle, icon: "sparkles",
                     selected: model.filter.label != nil || MediaCategory.extra.contains { model.filter.isCategory($0.id) },
                     dropdown: true) {
                    popover = .label
                }
                .popover(isPresented: $popover.isPresent(.label), arrowEdge: .top) {
                    LabelPickerPopover(model: model, close: { popover = nil })
                }

                Chip(title: model.yearTitle, icon: "calendar", selected: model.filter.year != nil || model.filter.onThisDay, dropdown: true) {
                    popover = .year
                }
                .popover(isPresented: $popover.isPresent(.year), arrowEdge: .top) {
                    YearPickerPopover(model: model, close: { popover = nil })
                }

                Chip(title: "Избранное", icon: model.filter.favoritesOnly ? "heart.fill" : "heart", selected: model.filter.favoritesOnly) {
                    model.filter.favoritesOnly.toggle()
                }
            }
            .padding(6)
        }
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08)))
        .frame(maxWidth: 1180)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RoundIcon: View {
    let symbol: String
    var size: CGFloat = 15
    var tint: Color = .white
    var help: String = ""
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct ControlBar: View {
    @ObservedObject var model: SlideshowModel
    @Binding var popover: ChipPopover?

    var body: some View {
        let favorite = model.current?.item.favorite ?? false
        HStack(spacing: 4) {
            RoundIcon(symbol: "backward.fill", help: "Предыдущее  ←") { model.prev() }
            RoundIcon(symbol: model.isPlaying ? "pause.fill" : "play.fill", size: 21, help: "Пауза / продолжить  пробел") { model.togglePlay() }
            RoundIcon(symbol: "forward.fill", help: "Следующее  →") { model.next() }

            Divider().frame(height: 22).padding(.horizontal, 6)

            RoundIcon(symbol: favorite ? "heart.fill" : "heart", tint: favorite ? .pink : .white, help: "В избранное  F") {
                model.toggleFavorite()
            }
            RoundIcon(symbol: "eye.slash", help: "Больше не показывать это фото  ⌫") { model.hideCurrent() }
            RoundIcon(symbol: "folder", help: "Показать в Finder") { model.revealInFinder() }

            Divider().frame(height: 22).padding(.horizontal, 6)

            RoundIcon(symbol: "timer", help: "Скорость и эффекты") { popover = .speed }
                .popover(isPresented: $popover.isPresent(.speed), arrowEdge: .top) {
                    SpeedPopover()
                }
            RoundIcon(symbol: "arrow.up.left.and.arrow.down.right", help: "Во весь экран  ↩") { toggleFullScreen() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08)))
    }
}

// MARK: - Popovers

struct PersonPickerPopover: View {
    @ObservedObject var model: SlideshowModel
    let close: () -> Void
    let openPeople: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Показывать только").font(.headline)
            row(title: "Всех людей", selected: model.filter.isCategory(MediaCategory.people.id)) {
                Image(systemName: "person.2.fill").frame(width: 30, height: 30)
            } action: {
                model.selectPerson(nil)
                close()
            }
            Divider()
            if model.namedPeople.isEmpty {
                Text("Пока никто не подписан. Откройте раздел «Люди», нажмите на лицо и введите имя.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Открыть «Люди»") {
                    close()
                    openPeople()
                }
                .buttonStyle(CapsuleButtonStyle())
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.namedPeople) { person in
                            row(title: person.name ?? "", detail: Fmt.number(person.count), selected: model.filter.personId == person.id) {
                                FaceAvatar(face: person.coverFace, size: 30)
                            } action: {
                                model.selectPerson(person.id)
                                close()
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private func row<Icon: View>(title: String, detail: String = "", selected: Bool,
                                 @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                Text(title).lineLimit(1)
                Spacer()
                if !detail.isEmpty { Text(detail).font(.caption).foregroundColor(.secondary) }
                if selected { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LabelPickerPopover: View {
    @ObservedObject var model: SlideshowModel
    let close: () -> Void
    @State var labels: [LabelCount] = []
    @State var query = ""
    @State var loading = true

    private var filtered: [LabelCount] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return labels }
        return labels.filter { LabelNames.title($0.id).lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Что показывать").font(.headline)
            HStack(spacing: 6) {
                ForEach(MediaCategory.extra) { category in
                    Chip(title: category.title, icon: category.icon, selected: model.filter.isCategory(category.id)) {
                        model.selectCategory(category.id)
                        close()
                    }
                }
            }
            SearchField(prompt: "Например: собака, торт, горы", text: $query)
            if loading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .frame(height: 80)
            } else if labels.isEmpty {
                Text("Предметы появятся по мере анализа фото.")
                    .foregroundColor(.secondary)
                    .frame(height: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { label in
                            Button {
                                model.selectLabel(label.id)
                                close()
                            } label: {
                                HStack {
                                    Text(LabelNames.title(label.id))
                                    Spacer()
                                    Text(Fmt.number(label.count)).font(.caption).foregroundColor(.secondary)
                                    if model.filter.label == label.id {
                                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 320)
            }
        }
        .padding(14)
        .frame(width: 330)
        .task {
            let result = await Task.detached(priority: .userInitiated) { Library.topLabels() }.value
            labels = result
            loading = false
        }
    }
}

struct YearPickerPopover: View {
    @ObservedObject var model: SlideshowModel
    let close: () -> Void
    @State var years: [YearCount] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Когда").font(.headline)
            HStack(spacing: 6) {
                Chip(title: "Все годы", icon: "calendar", selected: model.filter.year == nil && !model.filter.onThisDay) {
                    model.setYear(nil, onThisDay: false)
                    close()
                }
                Chip(title: "В этот день", icon: "sparkles", selected: model.filter.onThisDay) {
                    model.setYear(nil, onThisDay: true)
                    close()
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(years) { entry in
                        Button {
                            model.setYear(entry.year, onThisDay: false)
                            close()
                        } label: {
                            VStack(spacing: 2) {
                                Text(String(entry.year)).font(.system(size: 14, weight: .semibold))
                                Text(Fmt.number(entry.count)).font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(model.filter.year == entry.year ? Color.accentColor : Color.white.opacity(0.07)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(14)
        .frame(width: 330)
        .task {
            years = await Task.detached(priority: .userInitiated) { Library.years() }.value
        }
    }
}

struct SpeedPopover: View {
    @AppStorage(Keys.slideSeconds) var slideSeconds = 6.0
    @AppStorage(Keys.kenBurns) var kenBurns = true
    @AppStorage(Keys.includeVideos) var includeVideos = true
    @AppStorage(Keys.videoSound) var videoSound = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Показ").font(.headline)
            HStack {
                Text("Каждое фото")
                Spacer()
                Text("\(Int(slideSeconds)) сек").monospacedDigit().foregroundColor(.secondary)
            }
            Slider(value: $slideSeconds, in: 3...30, step: 1)
            Toggle("Плавный наезд камеры", isOn: $kenBurns)
            Toggle("Показывать видео", isOn: $includeVideos)
            Toggle("Звук у видео", isOn: $videoSound)
        }
        .padding(16)
        .frame(width: 280)
    }
}

// MARK: - Video

struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    let muted: Bool
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEnd: onEnd) }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        let player = AVPlayer(url: url)
        player.isMuted = muted
        player.actionAtItemEnd = .pause
        view.playerLayer.player = player
        context.coordinator.observe(player)
        player.play()
        return view
    }

    func updateNSView(_ view: PlayerContainerView, context: Context) {
        view.playerLayer.player?.isMuted = muted
    }

    static func dismantleNSView(_ view: PlayerContainerView, coordinator: Coordinator) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
        coordinator.stop()
    }

    final class Coordinator {
        private let onEnd: () -> Void
        private var token: NSObjectProtocol?

        init(onEnd: @escaping () -> Void) {
            self.onEnd = onEnd
        }

        func observe(_ player: AVPlayer) {
            token = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                           object: player.currentItem, queue: .main) { [weak self] _ in
                self?.onEnd()
            }
        }

        func stop() {
            if let token = token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }
}

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
