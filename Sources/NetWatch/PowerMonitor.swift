import Darwin
import Foundation
import IOKit

struct SelfUsage: Equatable {
    var cpuPercent: Double              // درصد یک هسته (خود برنامه + nettop)، میانگین حدود ۹۰ ثانیه‌ی اخیر
    var powerMilliwatts: Double         // توان تقریبی مصرفی
    var energyMilliwattHours: Double    // انرژی از زمان اجرای برنامه
    var batteryPercentTotal: Double?    // درصد ظرفیت باتری که از شروع مصرف شده
    var batteryPercentPerHour: Double?  // پیش‌بینی مصرف باتری در یک ساعت با همین توان

    /// گرد شده به دقت نمایش، تا تغییرهای نامحسوس باعث رسم دوباره‌ی UI نشوند
    func rounded() -> SelfUsage {
        func r(_ v: Double, _ step: Double) -> Double { (v / step).rounded() * step }
        return SelfUsage(cpuPercent: r(cpuPercent, 0.1),
                         powerMilliwatts: r(powerMilliwatts, 1),
                         energyMilliwattHours: r(energyMilliwattHours, 0.01),
                         batteryPercentTotal: batteryPercentTotal.map { r($0, 0.001) },
                         batteryPercentPerHour: batteryPercentPerHour.map { r($0, 0.01) })
    }
}

/// مصرف CPU و انرژی خود NetWatch را از rusage می‌خواند.
/// انرژی پروسه‌های فرزند (nettop) مستقیم در دسترس نیست؛ از روی زمان CPU و نسبت انرژی به CPU خود برنامه تخمین زده می‌شود.
final class PowerMonitor {
    private struct Snap { let time: Date; let cpu: Double; let energyJ: Double }

    private var history: [Snap] = []
    private var timebase = mach_timebase_info_data_t()
    private let batteryWh: Double?

    init() {
        mach_timebase_info(&timebase)
        batteryWh = Self.readBatteryWh()
    }

    func sample() -> SelfUsage? {
        guard let s = snap() else { return nil }
        history.append(s)
        // پنجره‌ی حدود ۹۰ ثانیه‌ای؛ همیشه حداقل دو نمونه نگه می‌داریم
        while history.count > 2, s.time.timeIntervalSince(history[1].time) >= 90 { history.removeFirst() }
        guard let first = history.first, history.count >= 2 else { return nil }

        let dt = max(s.time.timeIntervalSince(first.time), 1)
        let cpu = max(s.cpu - first.cpu, 0) / dt * 100
        let watts = max(s.energyJ - first.energyJ, 0) / dt
        let mWh = s.energyJ / 3.6
        return SelfUsage(
            cpuPercent: cpu,
            powerMilliwatts: watts * 1000,
            energyMilliwattHours: mWh,
            batteryPercentTotal: batteryWh.map { mWh / ($0 * 1000) * 100 },
            batteryPercentPerHour: batteryWh.map { watts / $0 * 100 })
    }

    private func snap() -> Snap? {
        var ru = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        guard rc == 0 else { return nil }
        let toSeconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let selfCPU = Double(ru.ri_user_time &+ ru.ri_system_time) * toSeconds
        let selfJ = Double(ru.ri_energy_nj) / 1e9

        var ch = rusage()
        getrusage(RUSAGE_CHILDREN, &ch)
        let childCPU = Double(ch.ru_utime.tv_sec + ch.ru_stime.tv_sec)
            + Double(ch.ru_utime.tv_usec + ch.ru_stime.tv_usec) / 1e6
        let joulesPerCPUSecond = selfCPU > 0.5 ? selfJ / selfCPU : 0
        return Snap(time: Date(), cpu: selfCPU + childCPU, energyJ: selfJ + childCPU * joulesPerCPUSecond)
    }

    /// ظرفیت فعلی باتری (وات‌ساعت)؛ روی مک بدون باتری nil است.
    private static func readBatteryWh() -> Double? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        func int(_ key: String) -> Double? {
            (IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.doubleValue
        }
        guard let mAh = int("AppleRawMaxCapacity"), let mV = int("Voltage"), mAh > 100, mV > 1000 else { return nil }
        return mAh * mV / 1_000_000
    }
}
