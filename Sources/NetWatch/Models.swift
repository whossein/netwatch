import Foundation

enum TimeRange: Int, CaseIterable, Identifiable {
    case m10, h1, h3, h12, h24, d30

    var id: Int { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .m10: return 600
        case .h1: return 3_600
        case .h3: return 10_800
        case .h12: return 43_200
        case .h24: return 86_400
        case .d30: return 30 * 86_400
        }
    }

    var title: String {
        switch self {
        case .m10: return "۱۰ دقیقه"
        case .h1: return "۱ ساعت"
        case .h3: return "۳ ساعت"
        case .h12: return "۱۲ ساعت"
        case .h24: return "۲۴ ساعت"
        case .d30: return "۱ ماه"
        }
    }
}

struct AppUsage: Identifiable, Hashable {
    var key: String        // مسیر بسته‌ی .app یا نام پروسه
    var name: String
    var path: String?      // مسیر .app برای گرفتن آیکن
    var rx: Int64
    var tx: Int64

    var id: String { key }
    var total: Int64 { rx + tx }

    /// ترافیکی که روی کارت شبکه دیده شد ولی به هیچ اپی نسبت داده نشد
    static let otherKey = "_other"
    static let otherName = "سایر (بدون تفکیک)"
}

struct LiveTop: Equatable {
    var key: String
    var name: String
    var path: String?
    var rx: Double   // بایت بر ثانیه
    var tx: Double
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func formatRate(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
}

/// نسخه‌ی کوتاه برای نوار منو: 1.2M، 850K، 12B
func compactRate(_ v: Double) -> String {
    if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
    if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
    return String(format: "%.0fB", v)
}
