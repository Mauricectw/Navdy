import Foundation
import Network

/// 用 Bonjour 找 Sonos：S2 音箱會廣播 `_sonos._tcp`，TXT 記錄裡的 `location`
/// 就是裝置描述的網址。走系統的 mDNS，不需要 multicast entitlement
/// （但 Info.plist 必須宣告 NSBonjourServices 與 NSLocalNetworkUsageDescription）。
final class BonjourScanner: @unchecked Sendable {

    private final class State: @unchecked Sendable {
        var locations = Set<String>()
        var unresolved: [NWEndpoint] = []
        var finished = false
    }

    private let queue = DispatchQueue(label: "zonoz.bonjour")

    /// 回傳找到的裝置描述網址。
    func scan(seconds: Double = 2.5) async -> [String] {
        let state = State()
        let queue = self.queue

        let fromTXT: [String] = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil), using: parameters)

            browser.browseResultsChangedHandler = { results, _ in
                var pending: [NWEndpoint] = []
                for result in results {
                    var location: String? = nil
                    if case .bonjour(let txt) = result.metadata {
                        location = txt["location"]
                    }
                    if let location = location, location.hasPrefix("http") {
                        state.locations.insert(location)
                    } else {
                        pending.append(result.endpoint)
                    }
                }
                state.unresolved = pending
            }
            browser.stateUpdateHandler = { newState in
                switch newState {
                case .failed(let error):
                    LogBus.w("Bonjour 瀏覽失敗：\(error.localizedDescription)")
                case .waiting(let error):
                    // 多半是「區域網路」權限被拒
                    LogBus.w("Bonjour 等待中：\(error.localizedDescription)")
                default:
                    break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + seconds) {
                if state.finished { return }
                state.finished = true
                browser.cancel()
                continuation.resume(returning: Array(state.locations))
            }
        }

        // TXT 沒帶 location 的，連一下把服務名解析成 IP
        var locations = Set(fromTXT)
        let unresolved: [NWEndpoint] = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: state.unresolved) }
        }
        for endpoint in unresolved.prefix(16) {
            if let ip = await resolveIPv4(endpoint) {
                locations.insert(SonosDevice.descriptionLocation(ip: ip))
            }
        }
        return Array(locations)
    }

    private func resolveIPv4(_ endpoint: NWEndpoint) async -> String? {
        let queue = self.queue
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let done = State()
            let tcp = NWProtocolTCP.Options()
            let parameters = NWParameters(tls: nil, tcp: tcp)
            if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)

            let finish: @Sendable (String?) -> Void = { value in
                if done.finished { return }
                done.finished = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    var ip: String? = nil
                    if let remote = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, _) = remote,
                       case .ipv4(let address) = host {
                        ip = "\(address)".split(separator: "%").first.map(String.init)
                    }
                    finish(ip)
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2.0) { finish(nil) }
        }
    }
}
