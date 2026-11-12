import Foundation

/// Sonos 區域組拓撲解析。
///
/// `ZoneGroupTopology#GetZoneGroupState` 的回應裡，`<ZoneGroupState>` 的文字內容是
/// 一整段被轉義過的 XML。判定從設備有兩條獨立依據，任一成立即可：
/// 1. `Invisible="1"` —— Sonos 用來標記不單獨暴露的衛星箱；
/// 2. `UUID != Coordinator` —— 同一組裡只有協調者能接收 Transport 指令。
enum ZoneTopology {

    struct Node: Equatable {
        var uuid: String
        var coordinator: String
        var invisible: Bool
        var channelMap: String
        var swGen: Int = 0
        var softwareVersion: String = ""

        var isSatellite: Bool {
            return invisible || (!coordinator.isEmpty && coordinator != uuid)
        }

        var channel: String { ZoneTopology.channelOf(channelMap: channelMap, uuid: uuid) }
    }

    /// 解析 SOAP 回應本文。解析不出來回空陣列 —— 呼叫方應把「空」當「不知道」，
    /// 退回逐台嘗試 + 1023 兜底，而不是中斷推送。
    static func parse(soapBody: String) -> [Node] {
        guard let escaped = SoapXml.tagText(soapBody, "ZoneGroupState") else { return [] }
        let inner = SoapXml.unescape(escaped)
        return parseMembers(inner)
    }

    static func parseMembers(_ xml: String) -> [Node] {
        var out: [Node] = []
        // 依 <ZoneGroup ...> 切段，段內的成員都屬於這個協調者
        var cursor = xml.startIndex
        var segments: [(coordinator: String, body: String)] = []
        var pendingCoordinator: String? = nil
        var pendingStart = xml.startIndex

        while let r = xml.range(of: "<ZoneGroup", range: cursor..<xml.endIndex) {
            cursor = r.upperBound
            guard r.upperBound < xml.endIndex else { break }
            let next = xml[r.upperBound]
            // 只認 <ZoneGroup␠ / <ZoneGroup>，跳過 <ZoneGroupMember、<ZoneGroups、<ZoneGroupState
            if !(next == " " || next == ">" || next == "\n" || next == "\t" || next == "\r") { continue }
            guard let close = xml.range(of: ">", range: r.upperBound..<xml.endIndex) else { break }
            if let c = pendingCoordinator {
                segments.append((c, String(xml[pendingStart..<r.lowerBound])))
            }
            let tag = String(xml[r.lowerBound..<close.upperBound])
            pendingCoordinator = SoapXml.attribute(tag, "Coordinator") ?? ""
            pendingStart = close.upperBound
            cursor = close.upperBound
        }
        if let c = pendingCoordinator {
            segments.append((c, String(xml[pendingStart..<xml.endIndex])))
        }
        if segments.isEmpty {
            segments.append(("", xml))
        }

        for segment in segments {
            // 家庭劇院的 Satellite 也是從設備，一併納入
            for tagName in ["ZoneGroupMember", "Satellite"] {
                for tag in SoapXml.openTags(segment.body, named: tagName) {
                    guard let uuid = SoapXml.attribute(tag, "UUID"), !uuid.isEmpty else { continue }
                    var coordinator = segment.coordinator
                    if coordinator.isEmpty {
                        coordinator = SoapXml.attribute(tag, "Coordinator") ?? ""
                    }
                    let invisible = SoapXml.attribute(tag, "Invisible") == "1" || tagName == "Satellite"
                    let channelMap = SoapXml.attribute(tag, "ChannelMapSet")
                        ?? SoapXml.attribute(tag, "HTSatChanMapSet") ?? ""
                    out.append(Node(
                        uuid: uuid,
                        coordinator: coordinator,
                        invisible: invisible,
                        channelMap: channelMap,
                        swGen: Int(SoapXml.attribute(tag, "SWGen") ?? "") ?? 0,
                        softwareVersion: SoapXml.attribute(tag, "SoftwareVersion") ?? ""
                    ))
                }
            }
        }
        return out
    }

    /// 從 `RINCON_AAA:RF,RF;RINCON_BBB:LF,LF` 取指定設備自己的聲道。
    static func channelOf(channelMap: String, uuid: String) -> String {
        if channelMap.isEmpty || uuid.isEmpty { return "" }
        for entry in channelMap.split(separator: ";") where entry.hasPrefix("\(uuid):") {
            let afterColon = entry.dropFirst(uuid.count + 1)
            let first = afterColon.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
            return first.trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
}
