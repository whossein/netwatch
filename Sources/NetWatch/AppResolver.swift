import AppKit
import Darwin

struct AppIdentity {
    let key: String
    let name: String
    let path: String?
    /// پروسه‌ی حامل VPN (NetworkExtension از نوع packet-tunnel یا app-proxy). ترافیک آن همان ترافیک اپ‌هاست
    /// که رمزنگاری‌شده دوباره از کارت شبکه رد می‌شود؛ شمردنش مصرف را دوبرابر نشان می‌دهد.
    var isTunnel = false
}

/// پروسه‌های کمکی (مثل Google Chrome Helper) را به اپ اصلی نسبت می‌دهد.
final class AppResolver {
    private var cache: [Int32: AppIdentity] = [:]

    func resolve(pid: Int32, fallback: String) -> AppIdentity {
        if let c = cache[pid] { return c }

        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else {
            return AppIdentity(key: fallback, name: fallback, path: nil)
        }
        let path = String(cString: buffer)

        var identity: AppIdentity
        if let r = path.range(of: ".app/") {
            // اولین .app در مسیر = بیرونی‌ترین اپ
            let bundlePath = String(path[..<r.lowerBound]) + ".app"
            identity = AppIdentity(key: bundlePath, name: Self.displayName(bundlePath), path: bundlePath)
        } else {
            let exe = (path as NSString).lastPathComponent
            identity = AppIdentity(key: exe, name: exe, path: nil)
        }

        identity.isTunnel = Self.isTunnelProvider(path)

        if cache.count > 3000 { cache.removeAll() }
        cache[pid] = identity
        return identity
    }

    private static let tunnelPoints: Set<String> = [
        "com.apple.networkextension.packet-tunnel", "com.apple.networkextension.app-proxy",
    ]

    private static func isTunnelProvider(_ path: String) -> Bool {
        guard let r = path.range(of: ".appex/") ?? path.range(of: ".systemextension/"),
              let info = Bundle(path: String(path[..<r.upperBound]))?.infoDictionary else { return false }
        if let ext = info["NSExtension"] as? [String: Any],
           let point = ext["NSExtensionPointIdentifier"] as? String, tunnelPoints.contains(point) { return true }
        if let ne = info["NetworkExtension"] as? [String: Any],
           let classes = ne["NEProviderClasses"] as? [String: Any],
           !tunnelPoints.isDisjoint(with: classes.keys) { return true }
        return false
    }

    private static func displayName(_ bundlePath: String) -> String {
        let bundle = Bundle(path: bundlePath)
        if let n = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !n.isEmpty { return n }
        if let n = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String, !n.isEmpty { return n }
        return ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
