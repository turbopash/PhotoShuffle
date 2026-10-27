import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    static func opt(_ s: String?) -> SQLValue {
        if let s = s { return .text(s) }
        return .null
    }

    static func i(_ v: Int) -> SQLValue { .int(Int64(v)) }
}

struct SQLRow {
    fileprivate let stmt: OpaquePointer

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }

    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    func blob(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return Data(bytes: p, count: n)
    }
}

/// Small thread-safe SQLite wrapper. Every call is serialized on one queue.
final class Database {
    static let shared = Database()

    fileprivate var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "PhotoShuffle.database")
    private var statements: [String: OpaquePointer] = [:]

    private init() {
        let url = AppPaths.support.appendingPathComponent("library.sqlite")
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            NSLog("PhotoShuffle: cannot open database at %@", url.path)
        }
        rawExec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-32000;")
        rawExec(Database.schema)
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS photos(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        live_path TEXT,
        kind INTEGER NOT NULL DEFAULT 0,
        mtime REAL NOT NULL DEFAULT 0,
        taken REAL,
        year INTEGER,
        analyzed INTEGER NOT NULL DEFAULT 0,
        people INTEGER NOT NULL DEFAULT 0,
        cats INTEGER NOT NULL DEFAULT 0,
        favorite INTEGER NOT NULL DEFAULT 0,
        hidden INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_photos_analyzed ON photos(analyzed, id);
    CREATE INDEX IF NOT EXISTS idx_photos_year ON photos(year);
    CREATE INDEX IF NOT EXISTS idx_photos_taken ON photos(taken);
    CREATE TABLE IF NOT EXISTS labels(
        photo_id INTEGER NOT NULL,
        label TEXT NOT NULL,
        conf REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_labels_label ON labels(label, conf);
    CREATE INDEX IF NOT EXISTS idx_labels_photo ON labels(photo_id);
    CREATE TABLE IF NOT EXISTS persons(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        centroid BLOB,
        face_count INTEGER NOT NULL DEFAULT 0,
        hidden INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS faces(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        photo_id INTEGER NOT NULL,
        x REAL NOT NULL,
        y REAL NOT NULL,
        w REAL NOT NULL,
        h REAL NOT NULL,
        roll REAL NOT NULL DEFAULT 0,
        quality REAL NOT NULL DEFAULT 0,
        emb BLOB,
        person_id INTEGER,
        locked INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(person_id, quality);
    CREATE INDEX IF NOT EXISTS idx_faces_photo ON faces(photo_id);
    CREATE TABLE IF NOT EXISTS not_same(
        a INTEGER NOT NULL,
        b INTEGER NOT NULL,
        PRIMARY KEY(a, b)
    );
    CREATE TABLE IF NOT EXISTS meta(
        key TEXT PRIMARY KEY,
        value BLOB
    );
    """

    // MARK: Low level

    private func rawExec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            if let err = err {
                NSLog("PhotoShuffle SQL error: %@", String(cString: err))
                sqlite3_free(err)
            }
        }
    }

    fileprivate func step(_ sql: String, _ args: [SQLValue], _ row: (SQLRow) -> Void) {
        if statements.count > 300 {
            for (_, s) in statements { sqlite3_finalize(s) }
            statements.removeAll()
        }
        var prepared = statements[sql]
        if prepared == nil {
            var s: OpaquePointer?
            if sqlite3_prepare_v2(handle, sql, -1, &s, nil) != SQLITE_OK || s == nil {
                NSLog("PhotoShuffle SQL prepare error: %@ — %@", String(cString: sqlite3_errmsg(handle)), sql)
                return
            }
            statements[sql] = s
            prepared = s
        }
        guard let st = prepared else { return }
        sqlite3_reset(st)
        sqlite3_clear_bindings(st)
        for (i, value) in args.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .int(let v):
                sqlite3_bind_int64(st, idx, v)
            case .double(let v):
                sqlite3_bind_double(st, idx, v)
            case .text(let v):
                sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                if d.isEmpty {
                    sqlite3_bind_null(st, idx)
                } else {
                    _ = d.withUnsafeBytes { buf in
                        sqlite3_bind_blob(st, idx, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                    }
                }
            case .null:
                sqlite3_bind_null(st, idx)
            }
        }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW {
                row(SQLRow(stmt: st))
            } else {
                if rc != SQLITE_DONE {
                    NSLog("PhotoShuffle SQL step error: %@ — %@", String(cString: sqlite3_errmsg(handle)), sql)
                }
                break
            }
        }
        sqlite3_reset(st)
    }

    // MARK: Public API

    func run(_ sql: String, _ args: [SQLValue] = []) {
        queue.sync { step(sql, args) { _ in } }
    }

    @discardableResult
    func insert(_ sql: String, _ args: [SQLValue] = []) -> Int64 {
        queue.sync { () -> Int64 in
            step(sql, args) { _ in }
            return sqlite3_last_insert_rowid(handle)
        }
    }

    func query<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (SQLRow) -> T) -> [T] {
        queue.sync { () -> [T] in
            var out: [T] = []
            step(sql, args) { out.append(map($0)) }
            return out
        }
    }

    func scalar(_ sql: String, _ args: [SQLValue] = []) -> Int64 {
        query(sql, args) { $0.int(0) }.first ?? 0
    }

    func transaction(_ body: (Transaction) -> Void) {
        queue.sync {
            rawExec("BEGIN IMMEDIATE")
            body(Transaction(db: self))
            rawExec("COMMIT")
        }
    }

    struct Transaction {
        fileprivate let db: Database

        func run(_ sql: String, _ args: [SQLValue] = []) {
            db.step(sql, args) { _ in }
        }

        @discardableResult
        func insert(_ sql: String, _ args: [SQLValue] = []) -> Int64 {
            db.step(sql, args) { _ in }
            return sqlite3_last_insert_rowid(db.handle)
        }

        func query<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (SQLRow) -> T) -> [T] {
            var out: [T] = []
            db.step(sql, args) { out.append(map($0)) }
            return out
        }
    }
}
