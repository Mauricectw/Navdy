import Foundation

/// SOAP / DIDL-Lite 報文構造與極簡 XML 取值。
///
/// 所有值都必須做 XML 轉義。CurrentURIMetaData 本身是一段 XML 字串，
/// 它以 SOAP 參數的「文字內容」出現，所以整段 DIDL 要被轉義成 `&lt;DIDL-Lite ...`。
/// 少轉一層是 402 Invalid Args 的常見原因。
enum SoapXml {

    static let serviceAVTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    static let serviceRenderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"
    static let serviceZoneGroupTopology = "urn:schemas-upnp-org:service:ZoneGroupTopology:1"

    static func envelope(serviceType: String, action: String, args: [(String, String)]) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        s += "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
        s += "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
        s += "<s:Body>"
        s += "<u:\(action) xmlns:u=\"\(serviceType)\">"
        for (key, value) in args {
            s += "<\(key)>\(escape(value))</\(key)>"
        }
        s += "</u:\(action)>"
        s += "</s:Body>"
        s += "</s:Envelope>"
        return s
    }

    /// 最小可用的 DIDL-Lite。
    ///
    /// Sonos 對 protocolInfo 很敏感：`http-get:*:<mime>:*` 必須與 HTTP 回應的
    /// Content-Type 完全一致，否則直接 714。刻意不寫 duration —— 填錯比不填更容易出問題。
    static func didlLite(title: String, url: String, mimeType: String, id: String = "1") -> String {
        var s = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
        s += "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
        s += "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
        s += "<item id=\"\(escape(id))\" parentID=\"0\" restricted=\"1\">"
        s += "<dc:title>\(escape(title))</dc:title>"
        s += "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        s += "<res protocolInfo=\"http-get:*:\(mimeType):*\">\(escape(url))</res>"
        s += "</item>"
        s += "</DIDL-Lite>"
        return s
    }

    /// 讓傳輸層指向「音箱自己的佇列」時用的容器 DIDL（不能傳空，否則 200 但不切換）。
    static func queueContainerDidl(queueUri: String) -> String {
        var s = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
        s += "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
        s += "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
        s += "<item id=\"-1\" parentID=\"-1\" restricted=\"1\">"
        s += "<upnp:class>object.container.playlistContainer</upnp:class>"
        s += "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnet:1/service/DeviceProperties\">"
        s += escape(queueUri)
        s += "</desc></item></DIDL-Lite>"
        return s
    }

    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count + 16)
        for ch in value {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// 解一層 XML 轉義（&amp; 必須最後處理）。
    static func unescape(_ value: String) -> String {
        if !value.contains("&") { return value }
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 秒數 → Seek 需要的 HH:MM:SS
    static func timeString(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        return pad2(s / 3600) + ":" + pad2((s % 3600) / 60) + ":" + pad2(s % 60)
    }

    private static func pad2(_ n: Int) -> String {
        return n < 10 ? "0\(n)" : "\(n)"
    }

    /// "0:01:23" / "1:23" 都可能出現，統一按冒號分段累加。NOT_IMPLEMENTED 之類回 0。
    static func parseTime(_ raw: String?) -> Int {
        guard let raw = raw else { return 0 }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        var total = 0
        for part in trimmed.split(separator: ":", omittingEmptySubsequences: false) {
            // 可能帶小數秒（0:03:25.000）
            let whole = part.split(separator: ".").first.map(String.init) ?? ""
            total = total * 60 + (Int(whole.trimmingCharacters(in: .whitespaces)) ?? 0)
        }
        return total
    }

    /// 取第一個 `<tag>文字</tag>` 的文字（不含巢狀標籤）。找不到回 nil。
    static func tagText(_ xml: String, _ tag: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = xml.range(of: open) else { return nil }
        guard let end = xml.range(of: close, range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    /// 從一個開始標籤的原始文字（例如 `<ZoneGroupMember UUID="x" ...`）裡取屬性值。
    static func attribute(_ tagSource: String, _ name: String) -> String? {
        // 前面必須是空白，避免 "UUID" 命中 "XUUID"
        for quote in ["\"", "'"] {
            var searchStart = tagSource.startIndex
            let needle = "\(name)=\(quote)"
            while let r = tagSource.range(of: needle, range: searchStart..<tagSource.endIndex) {
                let precededByGap: Bool
                if r.lowerBound == tagSource.startIndex {
                    precededByGap = true
                } else {
                    let prev = tagSource[tagSource.index(before: r.lowerBound)]
                    precededByGap = prev == " " || prev == "\n" || prev == "\t" || prev == "\r"
                }
                if precededByGap {
                    guard let endQuote = tagSource.range(of: quote, range: r.upperBound..<tagSource.endIndex) else {
                        return nil
                    }
                    return unescape(String(tagSource[r.upperBound..<endQuote.lowerBound]))
                }
                searchStart = r.upperBound
            }
        }
        return nil
    }

    /// 依序取出所有 `<name ...>` 開始標籤的原始文字（含自閉合），用於掃描屬性。
    static func openTags(_ xml: String, named name: String) -> [String] {
        var out: [String] = []
        var searchStart = xml.startIndex
        let needle = "<\(name)"
        while let r = xml.range(of: needle, range: searchStart..<xml.endIndex) {
            searchStart = r.upperBound
            // 緊接的字元必須是空白、> 或 /，否則是別的標籤（ZoneGroup vs ZoneGroupMember）
            guard r.upperBound < xml.endIndex else { break }
            let next = xml[r.upperBound]
            if !(next == " " || next == ">" || next == "/" || next == "\n" || next == "\t" || next == "\r") {
                continue
            }
            guard let close = xml.range(of: ">", range: r.upperBound..<xml.endIndex) else { break }
            out.append(String(xml[r.lowerBound..<close.upperBound]))
            searchStart = close.upperBound
        }
        return out
    }
}
