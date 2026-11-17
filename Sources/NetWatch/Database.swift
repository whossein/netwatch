import Foundation
import SQLite3

/// مصرف هر اپ در دو جدول: بسته‌های یک‌دقیقه‌ای (۲ روز اخیر) و یک‌ساعته (۳۲ روز).
/// دقیقه‌ی جاری در حافظه جمع می‌شود و فقط وقتی تمام شد روی دیسک نوشته می‌شود (حداکثر یک نوشتن در دقیقه).
final class Database: @unchecked Sendable {
    private static let minuteRetention = 2 * 24 * 60
    private static let hourRetention = 32 * 24

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "netwatch.db", qos: .utility)
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // فقط روی queue
    private var pending: [Int: [String: AppUsage]] = [:]
    private var insertMinute: OpaquePointer?
    private var insertHour: OpaquePointer?
    private var selectRange: OpaquePointer?
    private var first: Date?
    private var lastPrune = Date.distantPast

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sqlite3_open(dir.appendingPathComponent("usage.sqlite").path, &db)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")   // در WAL امن است و fsync هر تراکنش را حذف می‌کند
        exec("""
        CREATE TABLE IF NOT EXISTS usage(
            minute INTEGER NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL, path TEXT,
            rx INTEGER NOT NULL, tx INTEGER NOT NULL,
            PRIMARY KEY(minute, key)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS usage_hour(
            hour INTEGER NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL, path TEXT,
            rx INTEGER NOT NULL, tx INTEGER NOT NULL,
            PRIMARY KEY(hour, key)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v INTEGER NOT NULL);
        """)
        migrate()

        insertMinute = prepare("""
        INSERT INTO usage(minute,key,name,path,rx,tx) VALUES(?,?,?,?,?,?)
        ON CONFLICT(minute,key) DO UPDATE SET
          rx = rx + excluded.rx, tx = tx + excluded.tx, name = excluded.name, path = excluded.path
        """)
        insertHour = prepare("""
        INSERT INTO usage_hour(hour,key,name,path,rx,tx) VALUES(?,?,?,?,?,?)
        ON CONFLICT(hour,key) DO UPDATE SET
          rx = rx + excluded.rx, tx = tx + excluded.tx, name = excluded.name, path = excluded.path
        """)
        // بازه = چند دقیقه‌ی ابتدایی (تا اولین ساعت کامل) از جدول دقیقه + بقیه از جدول ساعت
        selectRange = prepare("""
        SELECT key, MAX(name), MAX(path), SUM(rx), SUM(tx) FROM (
          SELECT key, name, path, rx, tx FROM usage WHERE minute >= ?1 AND minute < ?2
          UNION ALL
          SELECT key, name, path, rx, tx FROM usage_hour WHERE hour >= ?3
        ) GROUP BY key
        """)

        if let m = metaValue("first") { first = Date(timeIntervalSince1970: TimeInterval(m) * 60) }
    }

    // MARK: - نوشتن

    func add(minute: Int, entries: [AppUsage]) {
        queue.async { [self] in
            if first == nil {
                first = Date(timeIntervalSince1970: TimeInterval(minute) * 60)
                exec("INSERT OR IGNORE INTO meta(k,v) VALUES('first',\(minute))")
            }
            var bucket = pending[minute] ?? [:]
            for e in entries {
                if var old = bucket[e.key] {
                    old.rx += e.rx; old.tx += e.tx
                    bucket[e.key] = old
                } else {
                    bucket[e.key] = e
                }
            }
            pending[minute] = bucket
            flush(before: minute)
        }
    }

    /// همه‌ی داده‌ی حافظه را می‌نویسد (هنگام خروج).
    func close() {
        queue.sync { flush(before: .max) }
    }

    private func flush(before minute: Int) {
        let done = pending.keys.filter { $0 < minute }.sorted()
        guard !done.isEmpty else { return }
        exec("BEGIN")
        for m in done {
            for e in pending[m]!.values {
                write(insertMinute, slot: m, e)
                write(insertHour, slot: m / 60, e)
            }
            pending[m] = nil
        }
        exec("COMMIT")

        if Date().timeIntervalSince(lastPrune) > 3_600 {
            lastPrune = Date()
            let now = Int(Date().timeIntervalSince1970 / 60)
            exec("DELETE FROM usage WHERE minute < \(now - Self.minuteRetention)")
            exec("DELETE FROM usage_hour WHERE hour < \(now / 60 - Self.hourRetention)")
        }
    }

    private func write(_ st: OpaquePointer?, slot: Int, _ e: AppUsage) {
        sqlite3_bind_int64(st, 1, Int64(slot))
        sqlite3_bind_text(st, 2, e.key, -1, transient)
        sqlite3_bind_text(st, 3, e.name, -1, transient)
        if let p = e.path { sqlite3_bind_text(st, 4, p, -1, transient) } else { sqlite3_bind_null(st, 4) }
        sqlite3_bind_int64(st, 5, e.rx)
        sqlite3_bind_int64(st, 6, e.tx)
        sqlite3_step(st)
        sqlite3_reset(st)
    }

    // MARK: - خواندن

    /// مجموع مصرف هر اپ در `seconds` ثانیه‌ی اخیر (دقت یک دقیقه؛ برای بازه‌های بیش از ۲ روز، یک ساعت).
    func query(seconds: TimeInterval) -> [AppUsage] {
        let now = Date().timeIntervalSince1970
        let since = Int(((now - seconds) / 60).rounded())
        let nowMinute = Int(now / 60)
        return queue.sync {
            // ابتدای بازه تا اولین ساعت کامل از جدول دقیقه خوانده می‌شود، مگر قدیمی‌تر از نگه‌داری آن باشد
            let firstHour = since < nowMinute - Self.minuteRetention + 60 ? since / 60 : (since + 59) / 60
            var out: [String: AppUsage] = [:]
            let st = selectRange
            sqlite3_bind_int64(st, 1, Int64(since))
            sqlite3_bind_int64(st, 2, Int64(firstHour * 60))
            sqlite3_bind_int64(st, 3, Int64(firstHour))
            while sqlite3_step(st) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(st, 0))
                out[key] = AppUsage(key: key,
                                    name: String(cString: sqlite3_column_text(st, 1)),
                                    path: sqlite3_column_text(st, 2).map { String(cString: $0) },
                                    rx: sqlite3_column_int64(st, 3), tx: sqlite3_column_int64(st, 4))
            }
            sqlite3_reset(st)

            for (m, bucket) in pending where m >= since {
                for e in bucket.values {
                    if var o = out[e.key] {
                        o.rx += e.rx; o.tx += e.tx
                        out[e.key] = o
                    } else {
                        out[e.key] = e
                    }
                }
            }
            return out.values.filter { $0.total > 0 }.sorted { $0.total > $1.total }
        }
    }

    func firstDate() -> Date? { queue.sync { first } }

    // MARK: - کمکی

    /// نسخه‌ی قبلی فقط جدول دقیقه داشت؛ جدول ساعت و تاریخ شروع از روی آن ساخته می‌شوند.
    private func migrate() {
        guard userVersion() < 1 else { return }
        exec("BEGIN")
        exec("""
        INSERT OR IGNORE INTO usage_hour(hour,key,name,path,rx,tx)
        SELECT minute / 60, key, MAX(name), MAX(path), SUM(rx), SUM(tx) FROM usage GROUP BY minute / 60, key
        """)
        exec("INSERT OR IGNORE INTO meta(k,v) SELECT 'first', MIN(minute) FROM usage WHERE minute IS NOT NULL HAVING MIN(minute) IS NOT NULL")
        exec("PRAGMA user_version = 1")
        exec("COMMIT")
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        return st
    }

    private func userVersion() -> Int {
        let st = prepare("PRAGMA user_version")
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    private func metaValue(_ k: String) -> Int? {
        let st = prepare("SELECT v FROM meta WHERE k = ?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, k, -1, transient)
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : nil
    }
}
