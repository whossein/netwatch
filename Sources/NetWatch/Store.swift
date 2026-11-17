import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class Store: ObservableObject {
    @Published var range: TimeRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "range"); refresh() }
    }
    @Published var widgetRange: TimeRange {
        didSet { UserDefaults.standard.set(widgetRange.rawValue, forKey: "widgetRange"); refresh() }
    }
    @Published var widgetVisible: Bool {
        didSet { UserDefaults.standard.set(widgetVisible, forKey: "widgetVisible"); if widgetVisible { refresh() } }
    }
    @Published private(set) var usage: [AppUsage] = []
    @Published private(set) var widgetUsage: [AppUsage] = []
    @Published private(set) var idleApps: [AppUsage] = []
    @Published private(set) var live: LiveTop?
    @Published private(set) var since: Date?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var selfUsage: SelfUsage?

    private let db = Database()
    private let collector: Collector
    private var smoothed: [String: LiveTop] = [:]
    private let power = PowerMonitor()
    private var powerTimer: Timer?
    private var lastRefresh = Date.distantPast

    /// وقتی هیچ‌چیز دیده نمی‌شود گزارش‌ها به‌روز نمی‌شوند؛ ویجت هر ۲۰ ثانیه، پنجره‌ی باز با هر نمونه.
    private static let widgetRefreshInterval: TimeInterval = 20

    /// AppDelegate هنگام باز/بسته شدن پنجره تنظیم می‌کند
    var popoverOpen = false {
        didSet {
            guard popoverOpen != oldValue else { return }
            collector.setFast(popoverOpen)
            if popoverOpen { refresh() }
        }
    }

    init() {
        let d = UserDefaults.standard
        range = TimeRange(rawValue: d.object(forKey: "range") as? Int ?? TimeRange.h1.rawValue) ?? .h1
        widgetRange = TimeRange(rawValue: d.object(forKey: "widgetRange") as? Int ?? TimeRange.h24.rawValue) ?? .h24
        widgetVisible = d.object(forKey: "widgetVisible") as? Bool ?? true
        collector = Collector(db: db)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func start() {
        collector.onUpdate = { [weak self] list, interval in
            Task { @MainActor in self?.apply(list, interval) }
        }
        collector.start()
        refresh()

        _ = power.sample()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let u = self.power.sample()?.rounded() else { return }
                if u != self.selfUsage { self.selfUsage = u }
            }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        powerTimer = t
    }

    func stop() {
        collector.stop()
        db.close()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - داده‌ی زنده

    private func apply(_ list: [AppUsage], _ interval: Double) {
        var seen = Set<String>()
        for u in list {
            seen.insert(u.key)
            let rx = Double(u.rx) / interval, tx = Double(u.tx) / interval
            let old = smoothed[u.key]
            smoothed[u.key] = LiveTop(key: u.key, name: u.name, path: u.path,
                                      rx: 0.6 * rx + 0.4 * (old?.rx ?? 0),
                                      tx: 0.6 * tx + 0.4 * (old?.tx ?? 0))
        }
        for k in smoothed.keys where !seen.contains(k) {
            guard var v = smoothed[k] else { continue }
            v.rx *= 0.4
            v.tx *= 0.4
            if v.rx + v.tx < 1 { smoothed[k] = nil } else { smoothed[k] = v }
        }
        let top = smoothed.values.filter { $0.key != AppUsage.otherKey }.max { $0.rx + $0.tx < $1.rx + $1.tx }
        let newLive = (top.map { $0.rx + $0.tx > 1_024 } ?? false) ? top : nil
        if newLive != live { live = newLive }

        if popoverOpen || (widgetVisible && Date().timeIntervalSince(lastRefresh) >= Self.widgetRefreshInterval) {
            refresh()
        }
    }

    // MARK: - گزارش بازه‌ها

    /// بازه‌ای که هنوز به‌اندازه‌ی طولش داده ثبت نشده غیرفعال است (کوچک‌ترین بازه همیشه فعال است).
    func isAvailable(_ r: TimeRange) -> Bool {
        if r == .m10 { return true }
        guard let since else { return false }
        return Date().timeIntervalSince(since) >= r.seconds
    }

    /// متن راهنما برای بازه‌ی غیرفعال
    func availabilityHint(_ r: TimeRange) -> String {
        guard !isAvailable(r), let since else { return "" }
        let ready = since.addingTimeInterval(r.seconds)
        return "از \(ready.formatted(date: .abbreviated, time: .shortened)) فعال می‌شود"
    }

    private func clampRanges() {
        func best(_ r: TimeRange) -> TimeRange {
            isAvailable(r) ? r : (TimeRange.allCases.last { isAvailable($0) && $0.rawValue < r.rawValue } ?? .m10)
        }
        let a = best(range), b = best(widgetRange)
        if a != range { range = a }
        if b != widgetRange { widgetRange = b }
    }

    func refresh() {
        lastRefresh = Date()
        let r1 = range, r2 = widgetRange
        let needMain = popoverOpen, needWidget = widgetVisible
        let db = self.db
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let a = needMain || r1 == r2 ? db.query(seconds: r1.seconds) : nil
            let b = !needWidget ? nil : (r1 == r2 ? a : db.query(seconds: r2.seconds))
            let first = db.firstDate()
            Task { @MainActor in
                guard let self else { return }
                // فقط مقدار تغییرکرده منتشر می‌شود تا SwiftUI بی‌دلیل دوباره رسم نکند
                if let a, a != self.usage { self.usage = a }
                if let b, b != self.widgetUsage { self.widgetUsage = b }
                if first != self.since { self.since = first }
                self.clampRanges()
                if self.popoverOpen { self.updateIdle() }
            }
        }
    }

    /// اپ‌های در حال اجرا که در این بازه هیچ ترافیکی نداشته‌اند
    private func updateIdle() {
        let active = Set(usage.map(\.key))
        let idle = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppUsage? in
                guard let path = app.bundleURL?.path, !active.contains(path) else { return nil }
                return AppUsage(key: path, name: app.localizedName ?? path, path: path, rx: 0, tx: 0)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if idle != idleApps { idleApps = idle }
    }
}
