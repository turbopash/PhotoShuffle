import Foundation
import Combine

/// Background worker: finds files, reads dates, recognizes people and objects.
/// Resumable — everything is saved as it goes, so quitting or unplugging the disk loses nothing.
final class Indexer: ObservableObject {
    static let shared = Indexer()

    enum Phase: Equatable {
        case idle
        case diskMissing
        case scanning(Int)
        case dates(Int, Int)
        case analyzing(Int, Int)
        case done(Int)

        var isWorking: Bool {
            switch self {
            case .scanning, .dates, .analyzing: return true
            default: return false
            }
        }

        var title: String {
            switch self {
            case .idle: return ""
            case .diskMissing: return "Диск с фото не подключён"
            case .scanning(let n): return "Поиск фото: \(Fmt.number(n))"
            case .dates(let d, let t): return "Чтение дат: \(Fmt.percent(d, t))"
            case .analyzing(let d, let t): return "Анализ: \(Fmt.number(d)) из \(Fmt.number(t))"
            case .done(let n): return "\(Fmt.number(n)) фото"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isPaused = false
    @Published private(set) var libraryVersion = 0

    private let db = Database.shared
    private let lock = NSLock()
    private var running = false
    private var cancelFlag = false
    private var pauseFlag = false
    private var diskGoneFlag = false
    private var pendingRestart = false
    private var pendingClear = false

    private let publishLock = NSLock()
    private var lastPublish = Date.distantPast

    fileprivate struct ScanEntry {
        let path: String
        let live: String?
        let kind: Int
        let mtime: Double
    }

    fileprivate struct Pending {
        let id: Int64
        let path: String
        let kind: Int
    }

    // MARK: Control (main thread)

    func start() {
        guard let rootPath = UserDefaults.standard.string(forKey: Keys.root) else { return }
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        cancelFlag = false
        diskGoneFlag = false
        lock.unlock()

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let thread = Thread { [weak self] in
            self?.run(root: root)
            self?.finished()
        }
        thread.name = "PhotoShuffle.indexer"
        thread.qualityOfService = .utility
        thread.stackSize = 8 << 20
        thread.start()
    }

    /// Stops the current pass (if any) and starts again, optionally wiping the library first.
    func restart(clearLibrary: Bool = false) {
        lock.lock()
        if running {
            cancelFlag = true
            pendingRestart = true
            pendingClear = pendingClear || clearLibrary
            lock.unlock()
            return
        }
        lock.unlock()
        if clearLibrary {
            Library.clearForNewRoot()
            notifyLibraryChanged()
        }
        start()
    }

    func togglePause() {
        lock.lock()
        pauseFlag.toggle()
        let paused = pauseFlag
        lock.unlock()
        isPaused = paused
    }

    func notifyLibraryChanged() {
        DispatchQueue.main.async { self.libraryVersion += 1 }
    }

    // MARK: Worker helpers

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelFlag
    }

    private var diskGone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return diskGoneFlag
    }

    private func setDiskGone(_ value: Bool) {
        lock.lock()
        diskGoneFlag = value
        lock.unlock()
    }

    /// Returns true when the worker must stop. Blocks while paused.
    private func checkpoint() -> Bool {
        while true {
            lock.lock()
            let c = cancelFlag, p = pauseFlag
            lock.unlock()
            if c { return true }
            if !p { return false }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func publish(_ p: Phase, force: Bool = false) {
        publishLock.lock()
        let now = Date()
        if !force && now.timeIntervalSince(lastPublish) < 0.5 {
            publishLock.unlock()
            return
        }
        lastPublish = now
        publishLock.unlock()
        DispatchQueue.main.async {
            if self.phase != p { self.phase = p }
        }
    }

    private func finished() {
        FaceClusterer.shared.flush()
        lock.lock()
        running = false
        let again = pendingRestart
        let clear = pendingClear
        let wasCancelled = cancelFlag
        pendingRestart = false
        pendingClear = false
        lock.unlock()
        DispatchQueue.main.async {
            if again {
                self.restart(clearLibrary: clear)
            } else if wasCancelled {
                self.phase = .idle
            }
        }
    }

    // MARK: Main loop

    private func run(root: URL) {
        while true {
            if !waitForDisk(root) { return }
            setDiskGone(false)
            if !scan(root: root) {
                if diskGone { continue }
                return
            }
            notifyLibraryChanged()
            if !readDates(root: root) {
                if diskGone { continue }
                return
            }
            notifyLibraryChanged()
            if !analyze(root: root) {
                if diskGone { continue }
                return
            }
            break
        }
        FaceClusterer.shared.finalizeIfNeeded()
        FaceClusterer.shared.flush()
        let total = Int(db.scalar("SELECT COUNT(*) FROM photos WHERE hidden = 0"))
        publish(.done(total), force: true)
        notifyLibraryChanged()
    }

    private func waitForDisk(_ root: URL) -> Bool {
        while !FileManager.default.fileExists(atPath: root.path) {
            publish(.diskMissing, force: true)
            for _ in 0..<10 {
                if cancelled { return false }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        return true
    }

    // MARK: 1. Scan

    private func scan(root: URL) -> Bool {
        publish(.scanning(0), force: true)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in true }) else { return false }
        var byDir: [String: [(URL, Double)]] = [:]
        var found = 0
        var visited = 0
        let keySet = Set(keys)
        while let object = enumerator.nextObject() {
            guard let url = object as? URL else { continue }
            visited += 1
            if visited % 500 == 0 && checkpoint() { return false }
            let values = try? url.resourceValues(forKeys: keySet)
            if values?.isDirectory == true {
                if MediaTypes.skippedFolders.contains(url.lastPathComponent.lowercased()) { enumerator.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard MediaTypes.all.contains(ext), values?.isRegularFile == true else { continue }
            if url.lastPathComponent.hasPrefix("._") { continue }
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            byDir[url.deletingLastPathComponent().path, default: []].append((url, mtime))
            found += 1
            if found % 200 == 0 { publish(.scanning(found)) }
        }
        publish(.scanning(found), force: true)

        guard fm.fileExists(atPath: root.path) else {
            setDiskGone(true)
            return false
        }

        let entries = group(byDir)
        let existing = db.query("SELECT id, path, mtime, live_path FROM photos") { r in
            (r.int(0), r.text(1) ?? "", r.double(2), r.text(3))
        }
        var byPath: [String: (Int64, Double, String?)] = [:]
        for e in existing { byPath[e.1] = (e.0, e.2, e.3) }

        var inserts: [ScanEntry] = []
        var updates: [(Int64, ScanEntry)] = []
        var seen = Set<Int64>()
        for e in entries {
            if let old = byPath[e.path] {
                seen.insert(old.0)
                if abs(old.1 - e.mtime) > 1 || old.2 != e.live { updates.append((old.0, e)) }
            } else {
                inserts.append(e)
            }
        }
        // Never delete anything if the scan found nothing (disk glitch) — safety first.
        let removed = found > 0 ? existing.map { $0.0 }.filter { !seen.contains($0) } : []

        for chunk in inserts.chunked(1000) {
            if checkpoint() { return false }
            db.transaction { tx in
                for e in chunk {
                    tx.run("INSERT OR IGNORE INTO photos(path, live_path, kind, mtime) VALUES(?, ?, ?, ?)",
                           [.text(e.path), .opt(e.live), .i(e.kind), .double(e.mtime)])
                }
            }
            notifyLibraryChanged()
        }

        if !updates.isEmpty {
            for chunk in updates.chunked(500) {
                db.transaction { tx in
                    for (id, e) in chunk {
                        tx.run("""
                            UPDATE photos SET live_path = ?, kind = ?, mtime = ?, analyzed = 0, taken = NULL,
                                year = NULL, cats = 0, people = 0 WHERE id = ?
                            """, [.opt(e.live), .i(e.kind), .double(e.mtime), .int(id)])
                        tx.run("DELETE FROM labels WHERE photo_id = ?", [.int(id)])
                        tx.run("DELETE FROM faces WHERE photo_id = ?", [.int(id)])
                    }
                }
            }
        }

        if !removed.isEmpty {
            for chunk in removed.chunked(500) {
                db.transaction { tx in
                    for id in chunk {
                        tx.run("DELETE FROM photos WHERE id = ?", [.int(id)])
                        tx.run("DELETE FROM labels WHERE photo_id = ?", [.int(id)])
                        tx.run("DELETE FROM faces WHERE photo_id = ?", [.int(id)])
                    }
                }
            }
        }

        if !updates.isEmpty || !removed.isEmpty {
            FaceClusterer.shared.flush()
            db.transaction { tx in
                tx.run("UPDATE persons SET face_count = (SELECT COUNT(*) FROM faces WHERE faces.person_id = persons.id)")
                tx.run("DELETE FROM persons WHERE face_count = 0 AND name IS NULL")
            }
            FaceClusterer.shared.load()
        }
        return true
    }

    /// Pairs Live Photos (IMG_1234.HEIC + IMG_1234.MOV) and prefers JPEG/HEIC over RAW duplicates.
    private func group(_ byDir: [String: [(URL, Double)]]) -> [ScanEntry] {
        var out: [ScanEntry] = []
        for (_, files) in byDir {
            var stems: [String: [(URL, Double)]] = [:]
            for file in files {
                stems[file.0.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(file)
            }
            for (_, group) in stems {
                let images = group.filter { MediaTypes.photo.contains($0.0.pathExtension.lowercased()) }
                let raws = group.filter { MediaTypes.raw.contains($0.0.pathExtension.lowercased()) }
                let videos = group.filter { MediaTypes.video.contains($0.0.pathExtension.lowercased()) }
                let stills = images.isEmpty ? raws : images
                if stills.isEmpty {
                    for v in videos { out.append(ScanEntry(path: v.0.path, live: nil, kind: 1, mtime: v.1)) }
                    continue
                }
                let live = videos.first
                for (i, still) in stills.enumerated() {
                    let liveForThis = i == 0 ? live : nil
                    let mtime = max(still.1, liveForThis?.1 ?? 0)
                    out.append(ScanEntry(path: still.0.path, live: liveForThis?.0.path, kind: 0, mtime: mtime))
                }
                for v in videos.dropFirst() {
                    out.append(ScanEntry(path: v.0.path, live: nil, kind: 1, mtime: v.1))
                }
            }
        }
        return out
    }

    // MARK: 2. Dates

    private func readDates(root: URL) -> Bool {
        let total = Int(db.scalar("SELECT COUNT(*) FROM photos WHERE taken IS NULL"))
        guard total > 0 else { return true }
        var done = 0
        publish(.dates(0, total), force: true)
        while true {
            if checkpoint() { return false }
            if !FileManager.default.fileExists(atPath: root.path) {
                setDiskGone(true)
                return false
            }
            let rows = db.query("SELECT id, path, kind, mtime FROM photos WHERE taken IS NULL LIMIT 300") { r in
                (r.int(0), r.text(1) ?? "", Int(r.int(2)), r.double(3))
            }
            if rows.isEmpty { break }
            var results: [(Int64, Double, Int)] = []
            for row in rows {
                let exif = autoreleasepool { MediaReader.captureDate(path: row.1, kind: row.2) }
                let date = exif ?? (row.3 > 0 ? Date(timeIntervalSince1970: row.3) : Date())
                results.append((row.0, date.timeIntervalSince1970, Calendar.current.component(.year, from: date)))
            }
            db.transaction { tx in
                for r in results {
                    tx.run("UPDATE photos SET taken = ?, year = ? WHERE id = ?", [.double(r.1), .i(r.2), .int(r.0)])
                }
            }
            done += rows.count
            publish(.dates(done, total))
        }
        return true
    }

    // MARK: 3. Recognition

    private func analyze(root: URL) -> Bool {
        let totalAll = Int(db.scalar("SELECT COUNT(*) FROM photos"))
        let alreadyDone = Int(db.scalar("SELECT COUNT(*) FROM photos WHERE analyzed <> 0"))
        if alreadyDone >= totalAll { return true }
        publish(.analyzing(alreadyDone, totalAll), force: true)

        let feed = AnalysisFeed(db: db, done: alreadyDone)
        let workers = ProcessInfo.processInfo.activeProcessorCount >= 4 ? 2 : 1
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            self.analysisWorker(feed: feed, root: root, total: totalAll)
        }
        if cancelled || diskGone { return false }
        return true
    }

    private func analysisWorker(feed: AnalysisFeed, root: URL, total: Int) {
        while true {
            if checkpoint() { return }
            guard let item = feed.next() else { return }
            let result = autoreleasepool { MediaAnalyzer.analyze(path: item.path, kind: item.kind) }
            if result.failed && !FileManager.default.fileExists(atPath: root.path) {
                feed.stop()
                setDiskGone(true)
                return
            }
            let faceCount = save(item, result)
            let (current, shouldFlush) = feed.finished(faces: faceCount)
            if shouldFlush { FaceClusterer.shared.flush() }
            publish(.analyzing(current, total))
            if current % 1500 == 0 { notifyLibraryChanged() }
        }
    }

    /// Hands out photos to the recognition workers.
    fileprivate final class AnalysisFeed {
        private let db: Database
        private let lock = NSLock()
        private var cursor: Int64 = 0
        private var buffer: [Pending] = []
        private var stopped = false
        private var done: Int
        private var facesSinceFlush = 0

        init(db: Database, done: Int) {
            self.db = db
            self.done = done
        }

        func next() -> Pending? {
            lock.lock()
            defer { lock.unlock() }
            if stopped { return nil }
            if buffer.isEmpty {
                buffer = db.query("SELECT id, path, kind FROM photos WHERE analyzed = 0 AND id > ? ORDER BY id LIMIT 64",
                                  [.int(cursor)]) { r in
                    Pending(id: r.int(0), path: r.text(1) ?? "", kind: Int(r.int(2)))
                }
                if let last = buffer.last { cursor = last.id }
            }
            return buffer.isEmpty ? nil : buffer.removeFirst()
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        func finished(faces: Int) -> (Int, Bool) {
            lock.lock()
            defer { lock.unlock() }
            done += 1
            facesSinceFlush += faces
            let flush = facesSinceFlush >= 300
            if flush { facesSinceFlush = 0 }
            return (done, flush)
        }
    }

    private func save(_ item: Pending, _ result: AnalysisResult) -> Int {
        var newFaces: [(Int64, [Float])] = []
        db.transaction { tx in
            tx.run("DELETE FROM labels WHERE photo_id = ?", [.int(item.id)])
            tx.run("DELETE FROM faces WHERE photo_id = ?", [.int(item.id)])
            for (label, conf) in result.labels {
                tx.run("INSERT INTO labels(photo_id, label, conf) VALUES(?, ?, ?)",
                       [.int(item.id), .text(label), .double(Double(conf))])
            }
            for face in result.faces {
                let embValue: SQLValue = face.emb.map { SQLValue.blob($0.data) } ?? .null
                let faceId = tx.insert("""
                    INSERT INTO faces(photo_id, x, y, w, h, roll, quality, emb) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.int(item.id), .double(Double(face.rect.minX)), .double(Double(face.rect.minY)),
                          .double(Double(face.rect.width)), .double(Double(face.rect.height)),
                          .double(face.roll), .double(Double(face.quality)), embValue])
                if let emb = face.emb { newFaces.append((faceId, emb)) }
            }
            tx.run("UPDATE photos SET analyzed = ?, cats = ?, people = ? WHERE id = ?",
                   [.i(result.failed ? 2 : 1), .int(result.cats), .i(result.people ? 1 : 0), .int(item.id)])
        }
        for (faceId, emb) in newFaces {
            FaceClusterer.shared.ingest(faceId: faceId, raw: emb)
        }
        return newFaces.count
    }
}
