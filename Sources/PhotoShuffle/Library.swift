import Foundation

/// All read/write queries the interface needs.
enum Library {
    private static var db: Database { Database.shared }

    private static let itemColumns = "p.id, p.path, p.live_path, p.kind, p.taken, p.favorite"

    private static func item(_ r: SQLRow, from o: Int32 = 0) -> MediaItem {
        MediaItem(id: r.int(o), path: r.text(o + 1) ?? "", livePath: r.text(o + 2), kind: Int(r.int(o + 3)),
                  taken: r.optDouble(o + 4), favorite: r.int(o + 5) != 0)
    }

    // MARK: Slideshow

    private static func whereClause(_ f: SlideFilter) -> (String, [SQLValue]) {
        var parts = ["p.hidden = 0"]
        var args: [SQLValue] = []
        if !UserDefaults.standard.bool(forKey: Keys.includeVideos) { parts.append("p.kind = 0") }
        if f.favoritesOnly { parts.append("p.favorite = 1") }
        if let y = f.year {
            parts.append("p.year = ?")
            args.append(.i(y))
        }
        if f.onThisDay {
            let doy = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
            parts.append("p.taken IS NOT NULL AND ABS(CAST(strftime('%j', p.taken, 'unixepoch', 'localtime') AS INTEGER) - ?) <= 3")
            args.append(.i(doy))
        }
        if let pid = f.personId {
            parts.append("p.id IN (SELECT photo_id FROM faces WHERE person_id = ?)")
            args.append(.int(pid))
        } else if let label = f.label {
            parts.append("p.id IN (SELECT photo_id FROM labels WHERE label = ? AND conf >= 0.3)")
            args.append(.text(label))
        } else if f.categoryId == MediaCategory.people.id {
            parts.append("p.people = 1")
        } else if let cat = MediaCategory.byId(f.categoryId), cat.bit != 0 {
            parts.append("(p.cats & ?) != 0")
            args.append(.int(cat.bit))
        }
        return (parts.joined(separator: " AND "), args)
    }

    static func randomItems(_ f: SlideFilter, limit: Int) -> [MediaItem] {
        let (w, args) = whereClause(f)
        return db.query("SELECT \(itemColumns) FROM photos p WHERE \(w) ORDER BY RANDOM() LIMIT \(limit)", args) { item($0) }
    }

    static func count(_ f: SlideFilter) -> Int {
        let (w, args) = whereClause(f)
        return Int(db.scalar("SELECT COUNT(*) FROM photos p WHERE \(w)", args))
    }

    static func years() -> [YearCount] {
        db.query("SELECT year, COUNT(*) FROM photos WHERE hidden = 0 AND year IS NOT NULL GROUP BY year ORDER BY year DESC") {
            YearCount(year: Int($0.int(0)), count: Int($0.int(1)))
        }
    }

    static func topLabels() -> [LabelCount] {
        db.query("""
            SELECT label, COUNT(*) AS c FROM labels WHERE conf >= 0.4
            GROUP BY label HAVING c >= 3 ORDER BY c DESC LIMIT 400
            """) { LabelCount(id: $0.text(0) ?? "", count: Int($0.int(1))) }
    }

    static func setFavorite(_ id: Int64, _ favorite: Bool) {
        db.run("UPDATE photos SET favorite = ? WHERE id = ?", [.i(favorite ? 1 : 0), .int(id)])
    }

    static func hide(_ id: Int64) {
        db.run("UPDATE photos SET hidden = 1 WHERE id = ?", [.int(id)])
    }

    static func unhideAll() {
        db.run("UPDATE photos SET hidden = 0 WHERE hidden = 1")
    }

    static func names(inPhoto id: Int64) -> [String] {
        db.query("""
            SELECT DISTINCT pe.name FROM faces f JOIN persons pe ON pe.id = f.person_id
            WHERE f.photo_id = ? AND pe.name IS NOT NULL AND pe.hidden = 0
            """, [.int(id)]) { $0.text(0) ?? "" }.filter { !$0.isEmpty }
    }

    // MARK: People

    private static let personSelect = """
        SELECT pe.id, pe.name, pe.face_count,
               (SELECT f.id FROM faces f WHERE f.person_id = pe.id ORDER BY f.quality DESC LIMIT 1)
        FROM persons pe
        """

    private static func summaries(_ rows: [(Int64, String?, Int, Int64?)]) -> [PersonSummary] {
        let refs = faceRefs(rows.compactMap { $0.3 })
        return rows.map { row in
            PersonSummary(id: row.0, name: row.1, count: row.2, coverFace: row.3.flatMap { refs[$0] })
        }
    }

    private static func personRow(_ r: SQLRow) -> (Int64, String?, Int, Int64?) {
        (r.int(0), r.text(1), Int(r.int(2)), r.optInt(3))
    }

    /// Named people first, then frequent unknown faces, both by number of photos.
    static func persons() -> [PersonSummary] {
        let rows = db.query("""
            \(personSelect)
            WHERE pe.hidden = 0 AND (pe.name IS NOT NULL OR pe.face_count >= 3)
            ORDER BY (pe.name IS NULL), pe.face_count DESC
            LIMIT 800
            """) { personRow($0) }
        return summaries(rows)
    }

    static func namedPersons() -> [PersonSummary] {
        let rows = db.query("""
            \(personSelect)
            WHERE pe.hidden = 0 AND pe.name IS NOT NULL
            ORDER BY pe.face_count DESC
            """) { personRow($0) }
        return summaries(rows)
    }

    static func person(_ id: Int64) -> PersonSummary? {
        personsByIds([id]).first
    }

    static func personsByIds(_ ids: [Int64]) -> [PersonSummary] {
        guard !ids.isEmpty else { return [] }
        var rows: [(Int64, String?, Int, Int64?)] = []
        for chunk in ids.chunked(300) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            rows += db.query("\(personSelect) WHERE pe.hidden = 0 AND pe.id IN (\(marks))", chunk.map { SQLValue.int($0) }) { personRow($0) }
        }
        let byId = Dictionary(rows.map { ($0.0, $0) }, uniquingKeysWith: { a, _ in a })
        return summaries(ids.compactMap { byId[$0] })
    }

    static func faceRefs(_ ids: [Int64]) -> [Int64: FaceRef] {
        var out: [Int64: FaceRef] = [:]
        for chunk in ids.chunked(300) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let refs = db.query("""
                SELECT f.id, f.photo_id, f.x, f.y, f.w, f.h, ph.path, ph.kind
                FROM faces f JOIN photos ph ON ph.id = f.photo_id
                WHERE f.id IN (\(marks))
                """, chunk.map { SQLValue.int($0) }) { r in
                FaceRef(id: r.int(0), photoId: r.int(1), path: r.text(6) ?? "", kind: Int(r.int(7)),
                        x: r.double(2), y: r.double(3), w: r.double(4), h: r.double(5))
            }
            for ref in refs { out[ref.id] = ref }
        }
        return out
    }

    static func photos(ofPerson pid: Int64) -> [PersonPhoto] {
        let rows = db.query("""
            SELECT f.id, f.x, f.y, f.w, f.h, \(itemColumns)
            FROM faces f JOIN photos p ON p.id = f.photo_id
            WHERE f.person_id = ? AND p.hidden = 0
            ORDER BY p.taken DESC
            LIMIT 6000
            """, [.int(pid)]) { r -> PersonPhoto in
            let media = item(r, from: 5)
            let face = FaceRef(id: r.int(0), photoId: media.id, path: media.path, kind: media.kind,
                               x: r.double(1), y: r.double(2), w: r.double(3), h: r.double(4))
            return PersonPhoto(face: face, item: media)
        }
        var seen = Set<Int64>()
        return rows.filter { seen.insert($0.item.id).inserted }
    }

    static func suggestions(for pid: Int64) -> [PersonSummary] {
        let me = person(pid)
        let raw = FaceClusterer.shared.suggestions(for: pid)
        guard !raw.isEmpty else { return [] }
        let rejected = Set(db.query("SELECT b FROM not_same WHERE a = ? UNION SELECT a FROM not_same WHERE b = ?",
                                    [.int(pid), .int(pid)]) { $0.int(0) })
        let candidates = personsByIds(raw.map { $0.0 }.filter { !rejected.contains($0) })
        var out: [PersonSummary] = []
        for s in candidates {
            if me?.name != nil && s.name != nil { continue }
            out.append(s)
            if out.count >= 12 { break }
        }
        return out
    }

    static func rejectPair(_ a: Int64, _ b: Int64) {
        db.run("INSERT OR IGNORE INTO not_same(a, b) VALUES(?, ?)", [.int(min(a, b)), .int(max(a, b))])
    }

    static func setPersonHidden(_ id: Int64) {
        db.run("UPDATE persons SET hidden = 1 WHERE id = ?", [.int(id)])
    }

    static func namedPerson(matching name: String, excluding id: Int64) -> PersonSummary? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let rows = db.query("SELECT id, name FROM persons WHERE name IS NOT NULL AND id <> ?", [.int(id)]) { r in
            (r.int(0), r.text(1) ?? "")
        }
        guard let match = rows.first(where: { $0.1.lowercased() == wanted }) else { return nil }
        return person(match.0)
    }

    // MARK: Stats & maintenance

    static func stats() -> LibraryStats {
        var s = LibraryStats()
        s.total = Int(db.scalar("SELECT COUNT(*) FROM photos"))
        s.analyzed = Int(db.scalar("SELECT COUNT(*) FROM photos WHERE analyzed <> 0"))
        s.faces = Int(db.scalar("SELECT COUNT(*) FROM faces"))
        s.people = Int(db.scalar("SELECT COUNT(*) FROM persons WHERE hidden = 0 AND (name IS NOT NULL OR face_count >= 3)"))
        s.named = Int(db.scalar("SELECT COUNT(*) FROM persons WHERE name IS NOT NULL"))
        s.hidden = Int(db.scalar("SELECT COUNT(*) FROM photos WHERE hidden = 1"))
        return s
    }

    /// Used when the photo folder changes. Named people (and what they look like) are kept.
    static func clearForNewRoot() {
        FaceClusterer.shared.flush()
        db.transaction { tx in
            tx.run("DELETE FROM labels")
            tx.run("DELETE FROM faces")
            tx.run("DELETE FROM photos")
            tx.run("DELETE FROM persons WHERE name IS NULL")
            tx.run("UPDATE persons SET face_count = 0")
            tx.run("DELETE FROM not_same")
        }
        AppPaths.resetFaceCache()
        FaceClusterer.shared.load()
    }
}
