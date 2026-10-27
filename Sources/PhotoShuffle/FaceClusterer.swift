import Foundation
import Accelerate

/// Groups faces into people. Every face fingerprint is compared with the "average face" of each
/// known person; close enough joins that person, otherwise a new (unnamed) person is created.
final class FaceClusterer {
    static let shared = FaceClusterer()
    static let dim = Projection.outDim

    private let lock = NSLock()
    private let db = Database.shared

    private var mean: [Float]?
    private var ids: [Int64] = []
    private var slot: [Int64: Int] = [:]
    private var sums: [[Float]] = []
    private var counts: [Int] = []
    private var centroids: [Float] = []
    private var dirty = Set<Int64>()
    private var pendingWithoutMean = 0

    private var dim: Int { FaceClusterer.dim }

    var threshold: Float {
        let v = UserDefaults.standard.double(forKey: Keys.faceSimilarity)
        return Float(v > 0 ? v : 0.62)
    }

    // MARK: Loading

    func load() {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
    }

    private func loadLocked() {
        let meanData = db.query("SELECT value FROM meta WHERE key = 'face_mean'") { $0.blob(0) }.compactMap { $0 }.first
        if let m = meanData?.floats(), m.count == dim { mean = m } else { mean = nil }

        ids = []; slot = [:]; sums = []; counts = []; centroids = []; dirty = []
        let rows = db.query("SELECT id, centroid, face_count FROM persons") { r in (r.int(0), r.blob(1), Int(r.int(2))) }
        for row in rows {
            guard let blob = row.1 else { continue }
            let sum = blob.floats()
            guard sum.count == dim else { continue }
            appendCluster(id: row.0, sum: sum, count: row.2)
        }
        if mean == nil {
            pendingWithoutMean = Int(db.scalar("SELECT COUNT(*) FROM faces WHERE emb IS NOT NULL"))
        }
    }

    // MARK: Math helpers

    static func normalized(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        let norm = sqrt(sumSquares)
        guard norm > 1e-6 else { return v }
        return v.map { $0 / norm }
    }

    private func prepared(_ raw: [Float]) -> [Float]? {
        guard let m = mean, raw.count == m.count else { return nil }
        var centered = [Float](repeating: 0, count: raw.count)
        for j in 0..<raw.count { centered[j] = raw[j] - m[j] }
        return FaceClusterer.normalized(centered)
    }

    private func appendCluster(id: Int64, sum: [Float], count: Int) {
        slot[id] = ids.count
        ids.append(id)
        sums.append(sum)
        counts.append(count)
        centroids.append(contentsOf: FaceClusterer.normalized(sum))
    }

    private func updateCentroid(_ i: Int) {
        let c = FaceClusterer.normalized(sums[i])
        centroids.replaceSubrange(i * dim..<(i + 1) * dim, with: c)
    }

    private func add(_ v: [Float], to i: Int) {
        for j in 0..<dim { sums[i][j] += v[j] }
        counts[i] += 1
        updateCentroid(i)
        dirty.insert(ids[i])
    }

    private func subtract(_ v: [Float], from i: Int) {
        for j in 0..<dim { sums[i][j] -= v[j] }
        counts[i] = max(0, counts[i] - 1)
        updateCentroid(i)
        dirty.insert(ids[i])
    }

    private func removeCluster(_ id: Int64) {
        guard let i = slot[id] else { return }
        ids.remove(at: i)
        sums.remove(at: i)
        counts.remove(at: i)
        centroids.removeSubrange(i * dim..<(i + 1) * dim)
        slot[id] = nil
        for k in i..<ids.count { slot[ids[k]] = k }
        dirty.remove(id)
    }

    private func scores(for v: [Float]) -> [Float] {
        let k = ids.count
        guard k > 0 else { return [] }
        var out = [Float](repeating: 0, count: k)
        vDSP_mmul(centroids, 1, v, 1, &out, 1, vDSP_Length(k), 1, vDSP_Length(dim))
        return out
    }

    // MARK: Assignment

    /// Returns the person id the face was assigned to (and stores it), or nil if grouping isn't ready yet.
    @discardableResult
    func ingest(faceId: Int64, raw: [Float]) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        if mean == nil {
            pendingWithoutMean += 1
            if pendingWithoutMean >= 300 {
                computeMeanLocked()
                assignUnassignedLocked(progress: nil)
            }
            return nil
        }
        guard let v = prepared(raw) else { return nil }
        let pid = assignLocked(v)
        db.run("UPDATE faces SET person_id = ? WHERE id = ?", [.int(pid), .int(faceId)])
        return pid
    }

    private func assignLocked(_ v: [Float]) -> Int64 {
        let s = scores(for: v)
        if !s.isEmpty {
            var best: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(s, 1, &best, &index, vDSP_Length(s.count))
            if best >= threshold {
                add(v, to: Int(index))
                return ids[Int(index)]
            }
        }
        let pid = db.insert("INSERT INTO persons(name, face_count) VALUES(NULL, 0)")
        appendCluster(id: pid, sum: [Float](repeating: 0, count: dim), count: 0)
        add(v, to: ids.count - 1)
        return pid
    }

    private func computeMeanLocked() {
        let rows = db.query("SELECT emb FROM faces WHERE emb IS NOT NULL ORDER BY quality DESC LIMIT 6000") { $0.blob(0) }
        var acc = [Float](repeating: 0, count: dim)
        var n = 0
        for blob in rows {
            guard let f = blob?.floats(), f.count == dim else { continue }
            for j in 0..<dim { acc[j] += f[j] }
            n += 1
        }
        guard n > 0 else { return }
        let m = acc.map { $0 / Float(n) }
        mean = m
        db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('face_mean', ?)", [.blob(m.data)])
    }

    private func assignUnassignedLocked(progress: ((Int, Int) -> Void)?) {
        guard mean != nil else { return }
        let rows = db.query("SELECT id, emb FROM faces WHERE person_id IS NULL AND locked = 0 AND emb IS NOT NULL ORDER BY quality DESC") { r in
            (r.int(0), r.blob(1))
        }
        var updates: [(Int64, Int64)] = []
        func write() {
            guard !updates.isEmpty else { return }
            let batch = updates
            updates.removeAll()
            db.transaction { tx in
                for (face, person) in batch {
                    tx.run("UPDATE faces SET person_id = ? WHERE id = ?", [.int(person), .int(face)])
                }
            }
        }
        for (i, row) in rows.enumerated() {
            guard let blob = row.1, let v = prepared(blob.floats()) else { continue }
            updates.append((row.0, assignLocked(v)))
            if updates.count >= 1000 {
                write()
                progress?(i + 1, rows.count)
            }
        }
        write()
        progress?(rows.count, rows.count)
        flushLocked()
    }

    /// Called at the end of indexing: makes sure grouping happens even for small libraries.
    func finalizeIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if mean == nil {
            let n = db.scalar("SELECT COUNT(*) FROM faces WHERE emb IS NOT NULL")
            guard n >= 5 else { return }
            computeMeanLocked()
        }
        assignUnassignedLocked(progress: nil)
    }

    // MARK: Persistence

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
    }

    private func flushLocked() {
        guard !dirty.isEmpty else { return }
        var items: [(Int64, Data, Int)] = []
        for id in dirty {
            guard let i = slot[id] else { continue }
            items.append((id, sums[i].data, counts[i]))
        }
        dirty.removeAll()
        db.transaction { tx in
            for (id, data, count) in items {
                tx.run("UPDATE persons SET centroid = ?, face_count = ? WHERE id = ?", [.blob(data), .int(Int64(count)), .int(id)])
            }
        }
    }

    // MARK: User actions

    func rename(_ pid: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        db.transaction { tx in
            tx.run("UPDATE persons SET name = ? WHERE id = ?", [SQLValue.opt(trimmed.isEmpty ? nil : trimmed), .int(pid)])
            if !trimmed.isEmpty {
                tx.run("UPDATE faces SET locked = 1 WHERE person_id = ? AND locked = 0", [.int(pid)])
            }
        }
    }

    /// Moves every face of `source` to `target` and deletes `source`.
    func merge(_ source: Int64, into target: Int64) {
        guard source != target else { return }
        lock.lock()
        defer { lock.unlock() }
        let names = db.query("SELECT id, name FROM persons WHERE id IN (?, ?)", [.int(source), .int(target)]) { r in
            (r.int(0), r.text(1))
        }
        let sourceName = names.first(where: { $0.0 == source }).flatMap { $0.1 }
        let targetName = names.first(where: { $0.0 == target }).flatMap { $0.1 }
        let finalName = (targetName?.isEmpty == false) ? targetName : sourceName

        db.transaction { tx in
            tx.run("UPDATE faces SET person_id = ? WHERE person_id = ?", [.int(target), .int(source)])
            if let n = finalName, !n.isEmpty {
                tx.run("UPDATE persons SET name = ? WHERE id = ?", [.text(n), .int(target)])
                tx.run("UPDATE faces SET locked = 1 WHERE person_id = ? AND locked = 0", [.int(target)])
            }
            tx.run("DELETE FROM persons WHERE id = ?", [.int(source)])
            tx.run("UPDATE not_same SET a = ? WHERE a = ?", [.int(target), .int(source)])
            tx.run("UPDATE not_same SET b = ? WHERE b = ?", [.int(target), .int(source)])
        }

        if let si = slot[source], let ti = slot[target] {
            for j in 0..<dim { sums[ti][j] += sums[si][j] }
            counts[ti] += counts[si]
            updateCentroid(ti)
            dirty.insert(target)
        }
        removeCluster(source)
        flushLocked()
    }

    /// "This is not him/her": detaches a face and never puts it back automatically.
    func removeFace(_ faceId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let rows = db.query("SELECT person_id, emb FROM faces WHERE id = ?", [.int(faceId)]) { r in (r.optInt(0), r.blob(1)) }
        guard let row = rows.first, let pid = row.0 else { return }
        db.run("UPDATE faces SET person_id = NULL, locked = 2 WHERE id = ?", [.int(faceId)])
        if let i = slot[pid], let blob = row.1, let v = prepared(blob.floats()) {
            subtract(v, from: i)
        }
        flushLocked()
        let remaining = db.scalar("SELECT COUNT(*) FROM faces WHERE person_id = ?", [.int(pid)])
        if remaining == 0 {
            let isNamed = db.scalar("SELECT COUNT(*) FROM persons WHERE id = ? AND name IS NOT NULL", [.int(pid)]) > 0
            if !isNamed {
                db.run("DELETE FROM persons WHERE id = ?", [.int(pid)])
                removeCluster(pid)
            }
        }
    }

    /// People whose average face looks close to this one.
    func suggestions(for pid: Int64, limit: Int = 30) -> [(Int64, Float)] {
        lock.lock()
        defer { lock.unlock() }
        guard let i = slot[pid] else { return [] }
        let c = Array(centroids[i * dim..<(i + 1) * dim])
        let s = scores(for: c)
        let floor = threshold - 0.15
        var out: [(Int64, Float)] = []
        for j in 0..<s.count where j != i && s[j] >= floor && counts[j] > 0 {
            out.append((ids[j], s[j]))
        }
        out.sort { $0.1 > $1.1 }
        return Array(out.prefix(limit))
    }

    /// Re-groups all faces that the user hasn't confirmed. Names are kept.
    func recluster(progress: @escaping (Int, Int) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
        computeMeanLocked()
        guard mean != nil else { return }

        db.transaction { tx in
            tx.run("UPDATE faces SET person_id = NULL WHERE locked = 0")
            tx.run("UPDATE faces SET person_id = NULL WHERE person_id IN (SELECT id FROM persons WHERE name IS NULL)")
            tx.run("DELETE FROM persons WHERE name IS NULL")
        }

        ids = []; slot = [:]; sums = []; counts = []; centroids = []; dirty = []
        let named = db.query("SELECT id, centroid FROM persons") { r in (r.int(0), r.blob(1)) }
        for person in named {
            let embs = db.query("SELECT emb FROM faces WHERE person_id = ? AND emb IS NOT NULL", [.int(person.0)]) { $0.blob(0) }
            var sum = [Float](repeating: 0, count: dim)
            var n = 0
            for blob in embs {
                guard let data = blob, let v = prepared(data.floats()) else { continue }
                for j in 0..<dim { sum[j] += v[j] }
                n += 1
            }
            if n == 0, let old = person.1?.floats(), old.count == dim { sum = old }
            appendCluster(id: person.0, sum: sum, count: n)
            dirty.insert(person.0)
        }
        assignUnassignedLocked(progress: progress)
    }
}
