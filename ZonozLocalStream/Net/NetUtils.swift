import Foundation

struct LanInterface {
    var name: String
    var ip: String
}

enum NetUtils {

    /// 列出所有啟用中、非 loopback 的 IPv4 介面。
    static func ipv4Interfaces() -> [LanInterface] {
        var result: [LanInterface] = []
        var head: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr else { continue }
            guard address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            let ip = String(cString: host)
            if ip.isEmpty || ip.hasPrefix("169.254.") { continue }
            result.append(LanInterface(name: String(cString: entry.ifa_name), ip: ip))
        }
        return result
    }

    /// 手機在區網中的 IPv4。
    ///
    /// 順序很重要：iPhone 的 Wi-Fi 固定是 en0。開 VPN 時預設路由會變成 utun，
    /// 把那個位址交給 Sonos 必然 701，所以一律優先 en0，其次其他 en*、個人熱點的 bridge*。
    static func currentLanIP() -> String? {
        let all = ipv4Interfaces()
        if let wifi = all.first(where: { $0.name == "en0" }) { return wifi.ip }
        if let other = all.first(where: { $0.name.hasPrefix("en") }) { return other.ip }
        if let bridge = all.first(where: { $0.name.hasPrefix("bridge") }) { return bridge.ip }
        return nil
    }

    /// 有沒有 VPN 類的隧道介面帶著 IPv4（僅用於在設定頁給提示）
    static func isVPNLikelyActive() -> Bool {
        return ipv4Interfaces().contains { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") || $0.name.hasPrefix("ppp") }
    }
}
