import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 以單播 HTTP 探測音箱：抓 `http://<ip>:1400/xml/device_description.xml`。
///
/// iOS 上送 SSDP 組播（239.255.255.250）需要 Apple 核發的 multicast entitlement，
/// 側載 / 免費帳號拿不到，所以 iOS 版改用 Bonjour + 同網段單播掃描 + 手動 IP。
final class DeviceProber: @unchecked Sendable {

    private let session: URLSession

    init(timeout: TimeInterval = 1.5) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1.0
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 2
        #if !canImport(FoundationNetworking)
        config.allowsCellularAccess = false
        config.waitsForConnectivity = false
        #endif
        session = URLSession(configuration: config)
    }

    func fetchDescription(location: String, source: DiscoverySource) async -> SonosDevice? {
        guard let url = URL(string: location) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch await HTTP.perform(session, request) {
        case .failure:
            return nil
        case .response(let status, let data):
            guard (200..<300).contains(status) else { return nil }
            let xml = String(decoding: data, as: UTF8.self)
            guard xml.contains("<device>") || xml.contains("<UDN>") else { return nil }
            guard let device = DeviceDescription.parse(location: location, xml: xml, source: source),
                  device.isSonos else { return nil }
            return device
        }
    }

    func probe(ip: String, source: DiscoverySource) async -> SonosDevice? {
        return await fetchDescription(location: SonosDevice.descriptionLocation(ip: ip), source: source)
    }

    /// 掃描 `localIP` 所在的 /24 網段。
    func scanSubnet(localIP: String, concurrency: Int = 48) async -> [SonosDevice] {
        let hosts = DeviceProber.subnetHosts(localIP: localIP)
        if hosts.isEmpty { return [] }
        var found: [SonosDevice] = []
        var index = 0
        await withTaskGroup(of: SonosDevice?.self) { group in
            var running = 0
            while index < hosts.count || running > 0 {
                while running < concurrency && index < hosts.count {
                    let ip = hosts[index]
                    index += 1
                    running += 1
                    group.addTask { [self] in
                        return await self.probe(ip: ip, source: .subnet)
                    }
                }
                if let result = await group.next() {
                    running -= 1
                    if let device = result { found.append(device) }
                } else {
                    break
                }
            }
        }
        return found
    }

    /// 192.168.1.37 → 192.168.1.1 … 192.168.1.254（不含自己）
    static func subnetHosts(localIP: String) -> [String] {
        let parts = localIP.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return [] }
        let prefix = parts[0..<3].joined(separator: ".")
        let own = Int(parts[3]) ?? -1
        return (1...254).filter { $0 != own }.map { "\(prefix).\($0)" }
    }

    /// 簡單檢查使用者輸入的 IPv4
    static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let n = Int(part), n >= 0, n <= 255, String(n) == part else { return false }
        }
        return true
    }
}
