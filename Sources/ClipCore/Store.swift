import CryptoKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed clip history. Opened in serialized (FULLMUTEX) mode so any thread may call it.
public final class Store: @unchecked Sendable {
    public let imageDir: URL
    private var db: OpaquePointer?

    public init(directory: URL) throws {
        imageDir = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
        }
        try exec("""
            PRAGMA busy_timeout=3000;
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS clips(
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                text TEXT,
                image TEXT,
                title TEXT,
                app TEXT,
                bundle TEXT,
                created REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                expires REAL,
                size INTEGER NOT NULL DEFAULT 0,
                hash TEXT NOT NULL UNIQUE);
            CREATE INDEX IF NOT EXISTS clips_created ON clips(created DESC);
            """)
        // Catches damage in the middle of the file, which opening alone does not notice.
        guard try query("PRAGMA quick_check", row: { col($0, 0) }) == ["ok"] else {
            throw StoreError(message: "database disk image is malformed", code: SQLITE_CORRUPT)
        }
        try migrateSearchColumn()
    }

    /// `search` holds case- and accent-folded text, title and app, so "cafe" finds "Café".
    private func migrateSearchColumn() throws {
        if try !query("PRAGMA table_info(clips)", row: { col($0, 1) }).contains("search") {
            try exec("ALTER TABLE clips ADD COLUMN search TEXT")
        }
        let missing = try query("SELECT id, text, title, app FROM clips WHERE search IS NULL") {
            (sqlite3_column_int64($0, 0), Self.fold(col($0, 1), title: col($0, 2), app: col($0, 3)))
        }
        guard !missing.isEmpty else { return }
        try exec("BEGIN")
        do {
            for (id, folded) in missing { try run("UPDATE clips SET search=? WHERE id=?", folded, id) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Source bytes folded into `search`. shortcut: text past the first 1 MB of a clip is not searchable;
    /// raise it (or move to FTS5) if users search deep inside huge logs.
    static let searchLimit = 1 << 20

    /// Title and app come first so they stay searchable when a huge text hits `searchLimit`.
    static func fold(_ text: String?, title: String? = nil, app: String? = nil) -> String {
        let source = [title, app, text].compactMap { $0 }.joined(separator: "\n")
        // Folded in small pieces: one call on a long string with ß, ligatures or decomposed accents is quadratic.
        var out = ""
        var i = source.startIndex
        var budget = searchLimit
        while i < source.endIndex, budget > 0 {
            let j = source.index(i, offsetBy: 2048, limitedBy: source.endIndex) ?? source.endIndex
            let piece = source[i..<j]
            out += piece.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            budget -= piece.utf8.count
            i = j
        }
        return out
    }

    deinit { sqlite3_close_v2(db) }

    /// Opens the store; if the database is corrupt, moves it aside (kept for manual recovery) and starts fresh.
    public static func openRecovering(directory: URL) throws -> (Store, movedTo: URL?) {
        do {
            return (try Store(directory: directory), nil)
        } catch let error as StoreError where error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let fm = FileManager.default
            let dest = directory.appendingPathComponent("history.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).sqlite")
            for suffix in ["", "-wal", "-shm"] {
                let src = directory.appendingPathComponent("history.sqlite" + suffix)
                if fm.fileExists(atPath: src.path) {
                    try fm.moveItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
                }
            }
            return (try Store(directory: directory), dest)
        }
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Writes

    /// Adds a clip, or moves an identical existing one to the top. Returns its id.
    @discardableResult
    public func add(kind: ClipKind, text: String?, png: Data? = nil, app: String?, bundle: String?,
                    expires: Date? = nil, now: Date = Date()) throws -> Int64 {
        let payload = png ?? Data((kind.rawValue + "\u{0}" + (text ?? "")).utf8)
        let hash = Self.hash(payload)
        var image: String?
        if let png {
            image = hash + ".png"
            let url = imageDir.appendingPathComponent(image!)
            if !FileManager.default.fileExists(atPath: url.path) {
                // Recreated here too: the folder can be deleted while the app runs.
                try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
            }
        }
        let size = png?.count ?? (kind == .file ? fileSize(text ?? "") : (text ?? "").utf8.count)
        try run("""
            INSERT INTO clips(kind, text, image, app, bundle, created, expires, size, hash, search)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(hash) DO UPDATE SET created=excluded.created, app=excluded.app, bundle=excluded.bundle,
                expires=CASE WHEN clips.pinned=1 THEN NULL ELSE excluded.expires END,
                search=excluded.search
            """, kind.rawValue, text, image, app, bundle, now.timeIntervalSince1970,
            expires?.timeIntervalSince1970, size, hash, Self.fold(text, app: app))
        let row = try query("SELECT id, title FROM clips WHERE hash=?", hash) { (sqlite3_column_int64($0, 0), col($0, 1)) }.first
        // A re-copy of a renamed clip keeps its name searchable.
        if case let (id, title?)? = row { try run("UPDATE clips SET search=? WHERE id=?", Self.fold(text, title: title, app: app), id) }
        return row?.0 ?? 0
    }

    public func touch(_ id: Int64, now: Date = Date()) throws {
        try run("UPDATE clips SET created=? WHERE id=?", now.timeIntervalSince1970, id)
    }

    /// Pinned clips are kept forever, so pinning also drops any delete timer.
    public func setPinned(_ id: Int64, _ pinned: Bool) throws {
        try run("UPDATE clips SET pinned=?, expires=CASE WHEN ?=1 THEN NULL ELSE expires END WHERE id=?",
                pinned ? 1 : 0, pinned ? 1 : 0, id)
    }

    public func setTitle(_ id: Int64, _ title: String?) throws {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = (t?.isEmpty ?? true) ? nil : t
        guard let clip = try clip(id: id) else { return }
        try run("UPDATE clips SET title=?, search=? WHERE id=?", clean,
                Self.fold(clip.text, title: clean, app: clip.app), id)
    }

    public func setExpiry(_ id: Int64, _ date: Date?) throws {
        try run("UPDATE clips SET expires=? WHERE id=? AND pinned=0", date?.timeIntervalSince1970, id)
    }

    public func delete(_ id: Int64) throws {
        try deleteWhere("id=?", id)
    }

    /// Clears history; pinned clips stay.
    public func clearUnpinned() throws {
        try deleteWhere("pinned=0")
    }

    /// Removes expired clips. Pinned clips never expire. Returns how many.
    @discardableResult
    public func deleteExpired(now: Date = Date()) throws -> Int {
        try deleteWhere("pinned=0 AND expires IS NOT NULL AND expires<=?", now.timeIntervalSince1970)
    }

    /// Keeps at most `maxClips` unpinned clips and at most `maxImageBytes` of unpinned images.
    @discardableResult
    public func prune(maxClips: Int, maxImageBytes: Int) throws -> Int {
        var removed = try deleteWhere(
            "pinned=0 AND id NOT IN (SELECT id FROM clips WHERE pinned=0 ORDER BY created DESC LIMIT ?)", maxClips)
        let images = try query("SELECT id, size FROM clips WHERE pinned=0 AND kind='image' ORDER BY created DESC") {
            (sqlite3_column_int64($0, 0), Int(sqlite3_column_int64($0, 1)))
        }
        var total = 0
        for (id, size) in images {
            total += size
            if total > maxImageBytes { removed += try deleteWhere("id=?", id) }
        }
        return removed
    }

    // MARK: Reads

    public func clips(filter: ClipFilter = .all, search: String = "", limit: Int = 2000) throws -> [Clip] {
        var sql = Self.select + " WHERE 1"
        var args: [Any?] = []
        if filter == .favorites { sql += " AND pinned=1" }
        if let kind = filter.kind { sql += " AND kind=?"; args.append(kind.rawValue) }
        // instr, not LIKE: no wildcard escaping, and it compares by byte length so text after a NUL is searchable.
        var seen = Set<Substring>()
        let words = Self.fold(search).split(whereSeparator: \.isWhitespace).filter { seen.insert($0).inserted }
        for word in words.prefix(64) { // ordered, so the same query always uses the same words
            sql += " AND instr(search, ?) > 0"
            args.append(String(word))
        }
        sql += " ORDER BY created DESC LIMIT ?"
        args.append(limit)
        return try query(sql, args: args, row: Self.row)
    }

    public func clip(id: Int64) throws -> Clip? {
        try query(Self.select + " WHERE id=?", id, row: Self.row).first
    }

    private static let select = "SELECT id, kind, text, image, title, app, bundle, created, pinned, expires, size FROM clips"

    private static func row(_ s: OpaquePointer) -> Clip {
        Clip(id: sqlite3_column_int64(s, 0),
             kind: ClipKind(rawValue: col(s, 1) ?? "") ?? .text,
             text: col(s, 2), image: col(s, 3), title: col(s, 4), app: col(s, 5), bundle: col(s, 6),
             created: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)),
             pinned: sqlite3_column_int(s, 8) != 0,
             expires: sqlite3_column_type(s, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 9)),
             size: Int(sqlite3_column_int64(s, 10)))
    }

    public func count() throws -> Int {
        try query("SELECT COUNT(*) FROM clips") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    public func imageURL(_ clip: Clip) -> URL? {
        clip.image.map { imageDir.appendingPathComponent($0) }
    }

    // MARK: SQLite plumbing

    @discardableResult
    private func deleteWhere(_ condition: String, _ args: Any?...) throws -> Int {
        let images = try query("SELECT image FROM clips WHERE (\(condition)) AND image IS NOT NULL", args: args) { col($0, 0) ?? "" }
        try run("DELETE FROM clips WHERE \(condition)", args: args)
        let removed = Int(sqlite3_changes(db))
        // An image file can be shared only by rows with the same hash, i.e. the same row, so it is safe to drop.
        for name in images { try? FileManager.default.removeItem(at: imageDir.appendingPathComponent(name)) }
        return removed
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func run(_ sql: String, _ args: Any?...) throws { try run(sql, args: args) }

    private func run(_ sql: String, args: [Any?]) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw error() }
    }

    private func query<T>(_ sql: String, _ args: Any?..., row: (OpaquePointer) -> T) throws -> [T] {
        try query(sql, args: args, row: row)
    }

    private func query<T>(_ sql: String, args: [Any?], row: (OpaquePointer) -> T) throws -> [T] {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { throw error() }
            out.append(row(s))
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw error() }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(s, idx)
            case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, idx, v)
            case let v as Double: sqlite3_bind_double(s, idx, v)
            // Explicit byte length: -1 would stop at the first NUL and silently cut the clip.
            case let v as String: v.withCString { _ = sqlite3_bind_text(s, idx, $0, Int32(v.utf8.count), SQLITE_TRANSIENT) }
            default:
                sqlite3_finalize(s)
                throw StoreError(message: "unsupported bind type \(type(of: arg))")
            }
        }
        return s
    }

    private func error() -> StoreError { StoreError(message: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db)) }

    private func fileSize(_ paths: String) -> Int {
        paths.split(separator: "\n").reduce(0) {
            $0 + ((try? FileManager.default.attributesOfItem(atPath: String($1))[.size] as? Int) ?? 0)
        }
    }
}

public struct StoreError: Error, CustomStringConvertible {
    public let message: String
    public var code: Int32 = 0
    public var description: String { message }
}

/// Reads by byte count, not up to the first NUL.
private func col(_ s: OpaquePointer, _ i: Int32) -> String? {
    guard let p = sqlite3_column_text(s, i) else { return nil }
    return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(s, i))), as: UTF8.self)
}
