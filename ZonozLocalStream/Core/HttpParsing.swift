import Foundation

/// HTTP 請求頭解析與 Range 計算 —— 純邏輯，方便離線測試。
struct HTTPRequestHead {
    var method: String
    var path: String
    var query: [String: String]
    /// 鍵一律小寫
    var headers: [String: String]

    static func parse(_ raw: String) -> HTTPRequestHead? {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            let queryString = target[target.index(after: q)...]
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        // 絕對 URI 形式（GET http://host/path）也接受
        if path.lowercased().hasPrefix("http://"), let schemeEnd = path.range(of: "://") {
            let rest = path[schemeEnd.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                path = String(rest[slash...])
            } else {
                path = "/"
            }
        }
        path = path.removingPercentEncoding ?? path

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && headers[key] == nil { headers[key] = value }
        }
        return HTTPRequestHead(method: method, path: path, query: query, headers: headers)
    }

    /// `/stream/1a2b3c4d5e6f.mp3` → `1a2b3c4d5e6f`；也接受 `?fileId=`
    func streamFileId() -> String? {
        if let q = query["fileId"], !q.isEmpty { return q }
        guard path.hasPrefix("/stream") else { return nil }
        var rest = String(path.dropFirst("/stream".count))
        while rest.hasPrefix("/") { rest.removeFirst() }
        let segment = rest.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        if segment.isEmpty { return nil }
        if let dot = segment.lastIndex(of: "."), dot != segment.startIndex {
            return String(segment[..<dot])
        }
        return segment
    }
}

struct ByteRange: Equatable {
    var start: Int64
    var end: Int64
    var length: Int64 { end - start + 1 }

    enum RangeError: Error { case unsatisfiable }

    /// 解析 `Range: bytes=...`。回 nil 表示「沒有 Range 或無法理解」→ 呼叫方回 200。
    /// 丟出 unsatisfiable 表示語法正確但越界 → 回 416。
    static func parse(header: String?, total: Int64) throws -> ByteRange? {
        guard let header = header, !header.isEmpty, total > 0 else { return nil }
        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let afterPrefix = header.dropFirst(6)
        let firstSpec = afterPrefix.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
        let spec = firstSpec.trimmingCharacters(in: .whitespaces)
        if spec.isEmpty { return nil }
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        let startPart = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let endPart = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        if startPart.isEmpty {
            // bytes=-500：最後 500 位元組
            guard let suffix = Int64(endPart) else { return nil }
            if suffix <= 0 { throw RangeError.unsatisfiable }
            return ByteRange(start: max(0, total - suffix), end: total - 1)
        }
        guard let start = Int64(startPart) else { return nil }
        if start >= total { throw RangeError.unsatisfiable }
        var end = total - 1
        if !endPart.isEmpty {
            guard let parsed = Int64(endPart) else { return nil }
            end = min(parsed, total - 1)
        }
        if end < start { throw RangeError.unsatisfiable }
        return ByteRange(start: start, end: end)
    }
}
