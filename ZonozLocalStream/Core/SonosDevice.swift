import Foundation

enum DiscoverySource: String, Codable {
    /// Bonjour（_sonos._tcp）自動發現
    case bonjour
    /// 掃描同網段 1400 埠
    case subnet
    /// 使用者手動輸入 IP
    case manual
}

/// 一台 Sonos 音箱（ZonePlayer）在控制面所需的全部資訊。
///
/// S1 / S2 韌體的 UPnP 服務路徑完全一致，`http://<ip>:1400/MediaRenderer/AVTransport/Control`
/// 在 S2 上依然有效。
struct SonosDevice: Identifiable, Hashable, Codable {
    var uuid: String
    var ip: String
    var friendlyName: String
    var roomName: String
    var modelName: String
    var location: String
    var avTransportControlUrl: String = SonosDevice.defaultAVTransportPath
    var renderingControlUrl: String = SonosDevice.defaultRenderingControlPath
    var isSonos: Bool = true
    var source: DiscoverySource = .bonjour
    /// 立體聲配對 / 家庭劇院裡的「從設備」。對它們發 SetAVTransportURI 會回 Sonos 私有錯誤 1023，
    /// 正確做法是只推主箱，從箱會自動同步。
    var isSatellite: Bool = false
    /// 配對中的聲道角色：LF / RF / 空
    var channelRole: String = ""
    /// 韌體代次：S1 = 1，S2 = 2，0 表示沒讀到
    var swGen: Int = 0
    var softwareVersion: String = ""

    var id: String { key }

    /// 顯示名稱：優先房間名，其次 friendlyName，最後退化為 IP
    var displayName: String {
        if !roomName.isEmpty { return roomName }
        if !friendlyName.isEmpty { return friendlyName }
        return ip
    }

    /// UI 選擇集合用的穩定 key
    var key: String { uuid.isEmpty ? ip : uuid }

    var isLegacyS1: Bool { swGen == 1 }

    var generationLabel: String {
        switch swGen {
        case 1: return "S1"
        case 2: return "S2"
        default: return ""
        }
    }

    static let port = 1400
    static let defaultAVTransportPath = "/MediaRenderer/AVTransport/Control"
    static let defaultRenderingControlPath = "/MediaRenderer/RenderingControl/Control"
    static let deviceDescriptionPath = "/xml/device_description.xml"

    static func descriptionLocation(ip: String) -> String {
        return "http://\(ip):\(port)\(deviceDescriptionPath)"
    }
}

/// 解析 `http://<ip>:1400/xml/device_description.xml`。
enum DeviceDescription {

    static func parse(location: String, xml: String, source: DiscoverySource) -> SonosDevice? {
        guard let ip = host(of: location), !ip.isEmpty else { return nil }

        let friendlyName = text(xml, "friendlyName")
        let roomName = text(xml, "roomName")
        let modelName = text(xml, "modelName")
        let manufacturer = text(xml, "manufacturer")
        let udn = text(xml, "UDN")
        let swGen = Int(text(xml, "swGen")) ?? 0
        let softwareVersion = text(xml, "softwareVersion")

        var avTransport = ""
        var rendering = ""
        // 逐個 <service>…</service> 區塊找 controlURL
        var searchStart = xml.startIndex
        while let open = xml.range(of: "<service>", range: searchStart..<xml.endIndex),
              let close = xml.range(of: "</service>", range: open.upperBound..<xml.endIndex) {
            let block = String(xml[open.upperBound..<close.lowerBound])
            let type = text(block, "serviceType")
            let control = text(block, "controlURL")
            if type.contains(":service:AVTransport:"), avTransport.isEmpty {
                avTransport = control
            } else if type.contains(":service:RenderingControl:"), rendering.isEmpty {
                rendering = control
            }
            searchStart = close.upperBound
        }

        let lowerManufacturer = manufacturer.lowercased()
        let isSonos = lowerManufacturer.contains("sonos")
            || location.contains(":\(SonosDevice.port)/")
            || modelName.lowercased().contains("sonos")
            || udn.contains("RINCON")

        var uuid = udn
        if uuid.hasPrefix("uuid:") { uuid = String(uuid.dropFirst(5)) }
        if uuid.isEmpty { uuid = "RINCON_\(ip)" }

        return SonosDevice(
            uuid: uuid,
            ip: ip,
            friendlyName: friendlyName,
            roomName: roomName,
            modelName: modelName.isEmpty ? "Sonos" : modelName,
            location: location,
            avTransportControlUrl: toPath(avTransport, fallback: SonosDevice.defaultAVTransportPath),
            renderingControlUrl: toPath(rendering, fallback: SonosDevice.defaultRenderingControlPath),
            isSonos: isSonos,
            source: source,
            swGen: swGen,
            softwareVersion: softwareVersion
        )
    }

    private static func text(_ xml: String, _ tag: String) -> String {
        guard let raw = SoapXml.tagText(xml, tag) else { return "" }
        return SoapXml.unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 從 `http://192.168.1.5:1400/xml/...` 取出主機部分。
    static func host(of location: String) -> String? {
        guard let schemeEnd = location.range(of: "://") else { return nil }
        let rest = location[schemeEnd.upperBound...]
        let hostPort = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let host = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return String(host)
    }

    static func toPath(_ raw: String, fallback: String) -> String {
        if raw.isEmpty { return fallback }
        if raw.lowercased().hasPrefix("http") {
            guard let schemeEnd = raw.range(of: "://") else { return fallback }
            let rest = raw[schemeEnd.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return fallback }
            return String(rest[slash...])
        }
        if raw.hasPrefix("/") { return raw }
        return "/" + raw
    }
}
