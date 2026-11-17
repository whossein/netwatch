import Foundation

/// نمونه‌ها را به اپ نسبت می‌دهد، کسری را با شمارنده‌ی کارت شبکه جبران می‌کند، در دیتابیس می‌نویسد و به UI خبر می‌دهد.
final class Collector: @unchecked Sendable {
    let db: Database
    var onUpdate: (@Sendable ([AppUsage], Double) -> Void)?

    /// هر اپ حداکثر تا این ضریب از ترافیک دیده‌شده‌اش سهم از کسری می‌گیرد؛ بقیه به «سایر» می‌رود
    /// (تا مثلاً دانلود یک پروسه‌ی ناپیدا به اسم اپی که فقط چند بایت داشته ثبت نشود).
    private static let maxScale: Int64 = 4

    private let sampler = Sampler()
    private let resolver = AppResolver()
    /// ترافیکی که در نمونه‌های قبلی بیش از شمارنده‌ی کارت دیده شده (مثلاً اپ فرستاده ولی VPN چند میلی‌ثانیه بعد
    /// از کارت رد کرده). از کسری نمونه‌ی بعد کم می‌شود تا یک ترافیک دو بار شمرده نشود.
    private var carryRx: Int64 = 0
    private var carryTx: Int64 = 0

    init(db: Database) {
        self.db = db
        sampler.onSample = { [weak self] in self?.handle($0) }
    }

    func start() { sampler.start() }
    func stop() { sampler.stop() }
    func setFast(_ on: Bool) { sampler.setFast(on) }

    private func handle(_ s: Sample) {
        var agg: [String: AppUsage] = [:]
        for r in s.rows {
            let id = resolver.resolve(pid: r.pid, fallback: r.name)
            guard !id.isTunnel else { continue }
            var u = agg[id.key] ?? AppUsage(key: id.key, name: id.name, path: id.path, rx: 0, tx: 0)
            u.rx += r.rx
            u.tx += r.tx
            agg[id.key] = u
        }

        if let irx = s.ifaceRx, let itx = s.ifaceTx {
            var other = AppUsage(key: AppUsage.otherKey, name: AppUsage.otherName, path: nil, rx: 0, tx: 0)
            other.rx = distribute(irx - agg.values.reduce(0) { $0 + $1.rx }, carry: &carryRx, into: &agg, \.rx)
            other.tx = distribute(itx - agg.values.reduce(0) { $0 + $1.tx }, carry: &carryTx, into: &agg, \.tx)
            if other.total > 0 { agg[other.key] = other }
        }

        let list = Array(agg.values)
        if !list.isEmpty { db.add(minute: Int(Date().timeIntervalSince1970 / 60), entries: list) }
        onUpdate?(list, s.interval)
    }

    /// جمع اپ‌ها را با ترافیک واقعی کارت (که دقیق است) هم‌تراز می‌کند:
    /// کسری به نسبت ترافیک همان بازه بین اپ‌ها پخش می‌شود و مقدار برگشتی سهمی است که به هیچ اپی نرسید.
    /// اگر اپ‌ها بیش از کارت ترافیک داشته باشند، به اندازه‌ی یک نمونه به‌عنوان تأخیر نگه داشته می‌شود و بیشتر از آن
    /// به نسبت از اپ‌ها کم می‌شود؛ پس جمع کل هیچ‌وقت از مصرف واقعی بیشتر نمی‌شود.
    private func distribute(_ gap: Int64, carry: inout Int64, into agg: inout [String: AppUsage],
                            _ field: WritableKeyPath<AppUsage, Int64>) -> Int64 {
        let seen = agg.values.reduce(Int64(0)) { $0 + $1[keyPath: field] }
        let remainder = gap - carry
        if remainder < 0 {
            let excess = -remainder
            let allowed = max(256 * 1024, seen)
            if excess > allowed, seen > 0 {
                let factor = max(Double(seen - (excess - allowed)), 0) / Double(seen)
                for k in Array(agg.keys) {
                    agg[k]![keyPath: field] = Int64(Double(agg[k]![keyPath: field]) * factor)
                }
            }
            // بدهی کم‌کم فراموش می‌شود تا یک خطای قدیمی جبران‌های بعدی را برای همیشه نگیرد
            carry = Int64(Double(min(excess, allowed)) * 0.9)
            return 0
        }
        carry = 0
        guard remainder > 0 else { return 0 }
        guard seen > 0 else { return remainder }
        var left = remainder
        for k in Array(agg.keys) {
            let v = agg[k]![keyPath: field]
            guard v > 0 else { continue }
            let share = min(Int64(Double(remainder) * Double(v) / Double(seen)), v * (Self.maxScale - 1))
            agg[k]![keyPath: field] += share
            left -= share
        }
        return max(left, 0)
    }
}
