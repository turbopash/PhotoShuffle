import SwiftUI
import AppKit

/// Picks random photos for the current filter, preloads the next one and runs the timer.
final class SlideshowModel: ObservableObject {
    struct Slide: Identifiable {
        let id = UUID()
        var item: MediaItem
        let image: NSImage?
        let backdrop: NSImage?
        let names: [String]
    }

    @Published var filter = SlideFilter() {
        didSet { if filter != oldValue { restart() } }
    }
    @Published private(set) var current: Slide?
    @Published private(set) var isPlaying = true
    @Published private(set) var matchCount = 0
    @Published private(set) var namedPeople: [PersonSummary] = []
    @Published private(set) var isLoading = false

    private var queue: [MediaItem] = []
    private var history: [MediaItem] = []
    private var historyPos = -1
    private var recentOrder: [Int64] = []
    private var recentSet = Set<Int64>()
    private var timer: Timer?
    private var generation = 0
    private var showToken = 0
    private var active = false
    private var refilling = false
    private var skipCount = 0
    private var preloaded: (id: Int64, payload: SlidePayload)?

    private var slideSeconds: Double {
        max(3, UserDefaults.standard.double(forKey: Keys.slideSeconds))
    }

    static func screenPixels() -> Int {
        guard let screen = NSScreen.main else { return 2560 }
        let px = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        return Int(min(3200, max(1600, px)))
    }

    // MARK: Lifecycle

    func activate() {
        active = true
        if current == nil { restart() } else { scheduleTimer() }
        refreshPeople()
    }

    func deactivate() {
        active = false
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        generation += 1
        let gen = generation
        let f = filter
        queue.removeAll()
        history.removeAll()
        historyPos = -1
        preloaded = nil
        timer?.invalidate()
        timer = nil
        isLoading = true
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([MediaItem], Int) in
                (Library.randomItems(f, limit: 40), Library.count(f))
            }.value
            guard let self = self, gen == self.generation else { return }
            self.isLoading = false
            self.matchCount = result.1
            self.queue = self.withoutRecent(result.0)
            if self.queue.isEmpty {
                withAnimation(.easeInOut(duration: 0.6)) { self.current = nil }
                return
            }
            self.advance()
        }
    }

    func libraryChanged() {
        if current == nil && !isLoading {
            restart()
        } else {
            refreshCount()
        }
        refreshPeople()
    }

    func timingChanged() {
        scheduleTimer()
    }

    // MARK: Navigation

    func next() { advance() }

    func prev() {
        guard historyPos > 0 else { return }
        historyPos -= 1
        show(history[historyPos])
    }

    func togglePlay() {
        isPlaying.toggle()
        if isPlaying { scheduleTimer() } else { timer?.invalidate(); timer = nil }
    }

    func videoEnded(_ slideId: UUID) {
        guard current?.id == slideId, isPlaying, active else { return }
        advance()
    }

    private func advance() {
        if historyPos + 1 < history.count {
            historyPos += 1
            show(history[historyPos])
            return
        }
        guard !queue.isEmpty else {
            refill(thenAdvance: true)
            return
        }
        let item = queue.removeFirst()
        history.append(item)
        if history.count > 300 { history.removeFirst(history.count - 300) }
        historyPos = history.count - 1
        show(item)
        if queue.count < 10 { refill(thenAdvance: false) }
    }

    private func show(_ item: MediaItem) {
        timer?.invalidate()
        timer = nil
        showToken += 1
        let token = showToken
        let gen = generation
        let maxPixel = SlideshowModel.screenPixels()
        let cached: SlidePayload? = preloaded?.id == item.id ? preloaded?.payload : nil
        Task { @MainActor [weak self] in
            let payload: SlidePayload
            if let cached = cached {
                payload = cached
            } else {
                payload = await Task.detached(priority: .userInitiated) {
                    ImageStore.loadSlide(item, maxPixel: maxPixel)
                }.value
            }
            guard let self = self, gen == self.generation, token == self.showToken else { return }
            guard payload.image != nil else {
                // Unreadable file — quietly skip it.
                self.skipCount += 1
                if self.skipCount < 25 { self.advance() }
                return
            }
            self.skipCount = 0
            self.markRecent(item.id)
            withAnimation(.easeInOut(duration: 1.0)) {
                self.current = Slide(item: item, image: payload.image, backdrop: payload.backdrop, names: payload.names)
            }
            self.scheduleTimer()
            self.preloadNext()
        }
    }

    private func preloadNext() {
        let upcoming: MediaItem? = historyPos + 1 < history.count ? history[historyPos + 1] : queue.first
        guard let item = upcoming, preloaded?.id != item.id else { return }
        let gen = generation
        let maxPixel = SlideshowModel.screenPixels()
        Task { @MainActor [weak self] in
            let payload = await Task.detached(priority: .utility) {
                ImageStore.loadSlide(item, maxPixel: maxPixel)
            }.value
            guard let self = self, gen == self.generation else { return }
            self.preloaded = (id: item.id, payload: payload)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard active, isPlaying, let cur = current else { return }
        // Videos advance when they finish; the timer is only a safety net for very long clips.
        let interval = cur.item.isVideo ? 90.0 : slideSeconds + 1.0
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.advance() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refill(thenAdvance: Bool) {
        guard !refilling else { return }
        refilling = true
        let gen = generation
        let f = filter
        Task { @MainActor [weak self] in
            let items = await Task.detached(priority: .utility) { Library.randomItems(f, limit: 40) }.value
            guard let self = self else { return }
            self.refilling = false
            guard gen == self.generation else { return }
            self.queue.append(contentsOf: self.withoutRecent(items))
            if thenAdvance && !self.queue.isEmpty { self.advance() }
        }
    }

    private func withoutRecent(_ items: [MediaItem]) -> [MediaItem] {
        let queued = Set(queue.map { $0.id })
        let fresh = items.filter { !recentSet.contains($0.id) && !queued.contains($0.id) }
        return fresh.isEmpty ? items.filter { !queued.contains($0.id) } : fresh
    }

    private func markRecent(_ id: Int64) {
        guard !recentSet.contains(id) else { return }
        recentOrder.append(id)
        recentSet.insert(id)
        if recentOrder.count > 500 {
            let old = recentOrder.removeFirst()
            recentSet.remove(old)
        }
    }

    private func refreshCount() {
        let f = filter
        let gen = generation
        Task { @MainActor [weak self] in
            let c = await Task.detached(priority: .utility) { Library.count(f) }.value
            guard let self = self, gen == self.generation else { return }
            self.matchCount = c
        }
    }

    func refreshPeople() {
        Task { @MainActor [weak self] in
            let people = await Task.detached(priority: .utility) { Library.namedPersons() }.value
            self?.namedPeople = people
        }
    }

    // MARK: Actions on the current photo

    func toggleFavorite() {
        guard var cur = current else { return }
        cur.item.favorite.toggle()
        let id = cur.item.id
        let favorite = cur.item.favorite
        current = cur
        for i in history.indices where history[i].id == id { history[i].favorite = favorite }
        DispatchQueue.global(qos: .utility).async { Library.setFavorite(id, favorite) }
    }

    func hideCurrent() {
        guard let cur = current else { return }
        let id = cur.item.id
        history.removeAll { $0.id == id }
        historyPos = history.count - 1
        matchCount = max(0, matchCount - 1)
        DispatchQueue.global(qos: .utility).async { Library.hide(id) }
        advance()
    }

    func revealInFinder() {
        guard let cur = current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([cur.item.url])
    }

    // MARK: Filters

    func selectCategory(_ id: String) {
        var f = filter
        f.categoryId = id
        f.personId = nil
        f.label = nil
        filter = f
    }

    func selectPerson(_ id: Int64?) {
        var f = filter
        f.categoryId = MediaCategory.people.id
        f.personId = id
        f.label = nil
        filter = f
    }

    func selectLabel(_ label: String) {
        var f = filter
        f.categoryId = "all"
        f.personId = nil
        f.label = label
        filter = f
    }

    func setYear(_ year: Int?, onThisDay: Bool) {
        var f = filter
        f.year = year
        f.onThisDay = onThisDay
        filter = f
    }

    var personTitle: String {
        guard let pid = filter.personId else { return "Кто" }
        return namedPeople.first { $0.id == pid }?.name ?? "Человек"
    }

    var labelTitle: String {
        if let label = filter.label { return LabelNames.title(label) }
        if let extra = MediaCategory.extra.first(where: { filter.isCategory($0.id) }) { return extra.title }
        return "Ещё"
    }

    var yearTitle: String {
        if filter.onThisDay { return "В этот день" }
        if let y = filter.year { return String(y) }
        return "Годы"
    }
}
