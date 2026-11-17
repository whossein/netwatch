import Darwin
import Foundation

/// ترافیک یک پروسه در فاصله‌ی دو نمونه
struct RawRow {
    let pid: Int32
    let name: String
    var rx: Int64
    var tx: Int64
}

/// یک نمونه: ترافیک تفکیک‌شده‌ی پروسه‌ها + ترافیک واقعی کارت شبکه در همان فاصله
struct Sample {
    var rows: [RawRow]
    var ifaceRx: Int64?
    var ifaceTx: Int64?
    var interval: Double
}

/// هر چند ثانیه یک‌بار nettop را (حدود ۰٫۰۲ ثانیه CPU) اجرا می‌کند و تفاوت با نمونه‌ی قبلی را حساب می‌کند.
///
/// خروجی `nettop -L 1` فقط سوکت‌های باز را دارد و شمارنده‌ی هر سوکت با بسته‌شدنش ناپدید می‌شود، پس جمع سطح پروسه
/// بالا و پایین می‌رود. برای همین تفاوت‌ها برای هر اتصال جدا حساب می‌شود؛ اتصالی که تازه دیده شده کل بایت‌هایش جدید است.
/// ترافیک اتصال‌های خیلی کوتاه و آخرین لحظه‌های هر اتصال هنوز دیده نمی‌شود؛ این کسری را Collector از روی شمارنده‌ی
/// کارت شبکه (که دقیق است) جبران می‌کند.
///
/// اجرای طولانی nettop (حالت پیوسته) خودش CPU زیادی مصرف می‌کند، برای همین هر بار یک پروسه‌ی کوتاه‌عمر اجرا می‌شود.
final class Sampler: @unchecked Sendable {
    /// وقتی پنجره باز است
    static let fastInterval: TimeInterval = 2
    /// وقتی فقط نوار منو / ویجت دیده می‌شود
    static let slowInterval: TimeInterval = 5

    var onSample: ((Sample) -> Void)?

    private struct FlowKey: Hashable { let pid: Int32; let flow: String }
    private struct FlowState { var rx: Int64; var tx: Int64; var seen: Date }

    private let queue = DispatchQueue(label: "netwatch.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var process: Process?
    private var stopped = false
    private var fast = false

    private var flows: [FlowKey: FlowState] = [:]
    private var knownPids: [Int32: Date] = [:]
    private var hasBaseline = false
    private var previousTime = Date()
    private var previousIface: InterfaceCounters.Totals?

    private var interval: TimeInterval { fast ? Self.fastInterval : Self.slowInterval }

    func start() {
        queue.async { [self] in
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            reschedule(after: 0)
            t.resume()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
        }
        process?.terminate()
    }

    /// وقتی پنجره باز می‌شود نمونه‌گیری سریع‌تر می‌شود تا نرخ زنده به‌روز باشد.
    func setFast(_ on: Bool) {
        queue.async { [self] in
            guard fast != on, !stopped else { return }
            fast = on
            reschedule(after: on ? 0.05 : interval)
        }
    }

    /// leeway به سیستم اجازه می‌دهد بیدارشدن‌ها را با کارهای دیگر یکی کند (مصرف باتری کمتر).
    private func reschedule(after delay: TimeInterval) {
        let i = interval
        timer?.schedule(deadline: .now() + delay, repeating: i, leeway: .milliseconds(Int(i * 250)))
    }

    private func tick() {
        guard !stopped, let text = runOnce() else { return }
        let iface = InterfaceCounters.read()
        handle(Self.parse(text), iface: iface, at: Date())
    }

    // MARK: - محاسبه‌ی تفاوت‌ها

    private func handle(_ snapshot: [(pid: Int32, name: String, flows: [(String, Int64, Int64)])],
                        iface: InterfaceCounters.Totals?, at time: Date) {
        let elapsed = max(time.timeIntervalSince(previousTime), 0.5)
        let baseline = hasBaseline
        var perPid: [Int32: RawRow] = [:]

        for p in snapshot {
            let pidIsNew = knownPids[p.pid] == nil
            knownPids[p.pid] = time
            var drx: Int64 = 0, dtx: Int64 = 0

            // چند سوکت شنونده (مثل *.5353) نام یکسان دارند و ترتیبشان در هر نمونه فرق می‌کند؛ جمعشان یک واحد حساب می‌شود
            var merged: [String: (rx: Int64, tx: Int64)] = [:]
            for (name, rx, tx) in p.flows {
                let o = merged[name] ?? (0, 0)
                merged[name] = (o.rx + rx, o.tx + tx)
            }

            for (flowName, (rx, tx)) in merged {
                let key = FlowKey(pid: p.pid, flow: flowName)
                // سوکت متصل (آدرس مقصد مشخص) یکتاست؛ سوکت شنونده (*) نه
                let connected = !flowName.contains("*")
                if let old = flows[key] {
                    if rx >= old.rx && tx >= old.tx {
                        drx += rx - old.rx; dtx += tx - old.tx
                    } else if connected {
                        // همان آدرس/پورت دوباره برای اتصال تازه استفاده شده
                        drx += rx; dtx += tx
                    }
                } else if baseline && (connected || pidIsNew) {
                    drx += rx; dtx += tx
                }
                flows[key] = FlowState(rx: rx, tx: tx, seen: time)
            }
            if drx + dtx > 0 {
                perPid[p.pid, default: RawRow(pid: p.pid, name: p.name, rx: 0, tx: 0)].rx += drx
                perPid[p.pid, default: RawRow(pid: p.pid, name: p.name, rx: 0, tx: 0)].tx += dtx
            }
        }

        // nettop گاهی یک سوکت را در یک نمونه نمی‌آورد؛ مبنای قبلی را کمی نگه می‌داریم
        flows = flows.filter { time.timeIntervalSince($0.value.seen) < 120 }
        knownPids = knownPids.filter { time.timeIntervalSince($0.value) < 120 }

        var ifaceRx: Int64?, ifaceTx: Int64?
        if let iface, let prev = previousIface, iface.rx >= prev.rx, iface.tx >= prev.tx {
            ifaceRx = Int64(iface.rx - prev.rx)
            ifaceTx = Int64(iface.tx - prev.tx)
        }
        previousIface = iface
        previousTime = time
        hasBaseline = true

        if baseline {
            onSample?(Sample(rows: Array(perPid.values), ifaceRx: ifaceRx, ifaceTx: ifaceTx, interval: elapsed))
        }
    }

    // MARK: - اجرای nettop

    private func runOnce() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-x", "-t", "external", "-L", "1", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        process = p
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        process = nil
        guard !stopped, !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// خط پروسه: "Google Chrome H.61301,530785,125280,"
    /// خط اتصال (زیر پروسه): "tcp4 192.168.1.5:52746<->10.0.184.22:443,0,2185,"
    static func parse(_ text: String) -> [(pid: Int32, name: String, flows: [(String, Int64, Int64)])] {
        var out: [(pid: Int32, name: String, flows: [(String, Int64, Int64)])] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var s = line
            if s.hasSuffix(",") { s = s.dropLast() }
            guard let c2 = s.lastIndex(of: ",") else { continue }
            let rest = s[..<c2]
            guard let c1 = rest.lastIndex(of: ","),
                  let rx = Int64(rest[rest.index(after: c1)...]),
                  let tx = Int64(s[s.index(after: c2)...]) else { continue }  // سطر عنوان رد می‌شود
            let label = rest[..<c1]

            if label.hasPrefix("tcp") || label.hasPrefix("udp"), label.contains(" ") {
                guard !out.isEmpty else { continue }
                out[out.count - 1].flows.append((String(label), rx, tx))
            } else if let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]) {
                out.append((pid, String(label[..<dot]), []))
            }
        }
        return out
    }
}

/// شمارنده‌ی ۶۴ بیتی بایت‌های کارت‌های شبکه‌ی فیزیکی (Wi‑Fi، اترنت، USB). دقیق و تقریباً بدون هزینه.
enum InterfaceCounters {
    struct Totals { var rx: UInt64; var tx: UInt64 }

    static func read() -> Totals? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var total = Totals(rx: 0, tx: 0)
        buf.withUnsafeBytes { raw in
            let hdrSize = MemoryLayout<if_msghdr2>.size
            var off = 0
            while off + 4 <= len {
                let msgLen = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                guard msgLen > 0, off + msgLen <= len else { break }
                defer { off += msgLen }
                let type = raw.loadUnaligned(fromByteOffset: off + 3, as: UInt8.self)
                guard Int32(type) == RTM_IFINFO2, msgLen >= hdrSize + 8 else { continue }
                let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                guard m.ifm_flags & IFF_LOOPBACK == 0, m.ifm_flags & IFF_UP != 0 else { continue }

                // پس از هدر یک sockaddr_dl می‌آید که نام کارت (مثل en0) در آن است
                let sdl = off + hdrSize
                let nameLen = Int(raw.loadUnaligned(fromByteOffset: sdl + 5, as: UInt8.self))
                guard nameLen > 0, sdl + 8 + nameLen <= off + msgLen else { continue }
                let name = String(decoding: raw[(sdl + 8)..<(sdl + 8 + nameLen)], as: UTF8.self)
                guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }

                total.rx &+= m.ifm_data.ifi_ibytes
                total.tx &+= m.ifm_data.ifi_obytes
            }
        }
        return total
    }
}
