import AppKit
import SwiftUI

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private var menuCache: [String: NSImage] = [:]

    func icon(for path: String?) -> NSImage {
        guard let path else {
            return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        }
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }

    func menuIcon(for path: String?) -> NSImage {
        guard let path else {
            let i = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
            i.isTemplate = true
            return i
        }
        if let i = menuCache[path] { return i }
        let i = (icon(for: path).copy() as? NSImage) ?? NSImage()
        i.size = NSSize(width: 16, height: 16)
        menuCache[path] = i
        return i
    }
}

struct AppIconView: View {
    let path: String?
    var size: CGFloat = 24
    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: path))
            .resizable()
            .frame(width: size, height: size)
    }
}

struct UsageRow: View {
    let usage: AppUsage
    let maxTotal: Int64

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(path: usage.path)
            VStack(alignment: .leading, spacing: 4) {
                Text(usage.name).lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(Double(usage.total) / Double(max(maxTotal, 1))))
                    }
                }
                .frame(height: 4)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(usage.total)).font(.callout.bold()).monospacedDigit()
                Text("↓ \(formatBytes(usage.rx))  ↑ \(formatBytes(usage.tx))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct RangePicker: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TimeRange.allCases) { r in
                let enabled = store.isAvailable(r)
                let selected = store.range == r
                Button { store.range = r } label: {
                    Text(r.title)
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selected ? Color.accentColor : Color.secondary.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
                .help(store.availabilityHint(r))
            }
        }
    }
}

struct SelfUsageCard: View {
    let usage: SelfUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("مصرف خود NetWatch").font(.caption.bold())
            if let u = usage {
                HStack {
                    Label(String(format: "CPU %.1f%%", u.cpuPercent), systemImage: "cpu")
                    Spacer()
                    Label(String(format: "توان ≈ %.0f mW", u.powerMilliwatts), systemImage: "bolt")
                }
                .font(.caption).monospacedDigit()
                HStack {
                    Text(String(format: "انرژی از شروع: %.2f mWh", u.energyMilliwattHours))
                    if let t = u.batteryPercentTotal { Text(String(format: "(≈ %.3f%% باتری)", t)) }
                    Spacer()
                    if let h = u.batteryPercentPerHour { Text(String(format: "≈ %.2f%% باتری در ساعت", h)) }
                }
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("در حال اندازه‌گیری…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .help("CPU نسبت به یک هسته است و nettop را هم شامل می‌شود. انرژی nettop از روی زمان CPU تخمین زده می‌شود.")
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            RangePicker()

            summary

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.usage.isEmpty {
                        Text("هنوز داده‌ای ثبت نشده؛ چند ثانیه صبر کنید…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                            .frame(maxWidth: .infinity)
                    }
                    let maxTotal = store.usage.first?.total ?? 1
                    ForEach(store.usage) { UsageRow(usage: $0, maxTotal: maxTotal) }

                    if !store.idleApps.isEmpty {
                        DisclosureGroup("بدون ترافیک در این بازه (\(store.idleApps.count))") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(store.idleApps) { app in
                                    HStack(spacing: 8) {
                                        AppIconView(path: app.path, size: 18)
                                        Text(app.name).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .padding(.top, 6)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.trailing, 6)
            }

            SelfUsageCard(usage: store.selfUsage)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400, height: 600)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("NetWatch").font(.headline)
            Spacer()
            if let l = store.live {
                AppIconView(path: l.path, size: 16)
                Text("\(l.name)  ↓\(formatRate(l.rx))  ↑\(formatRate(l.tx))")
                    .font(.caption).monospacedDigit().lineLimit(1)
            } else {
                Text("اکنون ترافیک فعالی نیست").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: some View {
        let rx = store.usage.reduce(Int64(0)) { $0 + $1.rx }
        let tx = store.usage.reduce(Int64(0)) { $0 + $1.tx }
        return HStack {
            Text("\(store.usage.count) اپ با ترافیک")
            Spacer()
            Text("↓ \(formatBytes(rx))   ↑ \(formatBytes(tx))").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("ویجت روی دسکتاپ", isOn: $store.widgetVisible)
            Toggle("اجرا هنگام ورود به سیستم", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
            HStack {
                if let since = store.since {
                    Text("ثبت داده از \(since.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("خروج") { NSApp.terminate(nil) }
            }
        }
    }
}

struct WidgetView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("پرترافیک‌ترین اپ‌ها").font(.caption.bold())
                Spacer()
                Menu {
                    ForEach(TimeRange.allCases) { r in
                        Button(r.title) { store.widgetRange = r }
                            .disabled(!store.isAvailable(r))
                    }
                } label: {
                    Text(store.widgetRange.title).font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            let top = Array(store.widgetUsage.prefix(5))
            ForEach(top) { u in
                HStack(spacing: 8) {
                    AppIconView(path: u.path, size: 20)
                    Text(u.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(formatBytes(u.total)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if top.isEmpty {
                Text("داده‌ای نیست").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Divider()
            if let u = store.selfUsage {
                Text(String(format: "خود برنامه: CPU %.1f%% · %.0f mW", u.cpuPercent, u.powerMilliwatts))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("خود برنامه: در حال اندازه‌گیری…").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260, height: 245, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
