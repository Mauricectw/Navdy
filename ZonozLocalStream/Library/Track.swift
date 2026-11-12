import Foundation

/// 曲庫裡的一首歌。`id` 就是 fileId：由「Documents 內的相對路徑」算出的 12 位十六進位，
/// 只由路徑決定（重開 App、重裝後都不變），HTTP 伺服器只暴露它，不洩漏真實路徑。
struct Track: Identifiable, Hashable, Codable {
    var id: String
    var relPath: String
    var title: String
    var artist: String
    var album: String
    var durationMs: Int
    var sizeBytes: Int64
    var mimeType: String
    var modified: Double
    /// 例如 "ec-3"、"alac"、"mp4a"、"flac"；讀不到為空
    var codec: String = ""
    /// MP4 裡的 E-AC-3 帶 JOC 擴充（Dolby Atmos）
    var isAtmos: Bool = false
    var sampleRate: Int = 0
    var channels: Int = 0

    var fileName: String {
        return relPath.split(separator: "/").last.map(String.init) ?? relPath
    }

    var folder: String {
        let parts = relPath.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }

    var durationLabel: String { Track.formatDuration(seconds: durationMs / 1000) }

    var sizeLabel: String {
        if sizeBytes <= 0 { return "-" }
        let mb = Double(sizeBytes) / 1_048_576.0
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024.0) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(sizeBytes) / 1024.0)
    }

    /// 顯示用的格式徽章
    var formatBadge: String {
        if isAtmos { return "Dolby Atmos" }
        switch codec {
        case "ec-3": return "E-AC-3"
        case "ac-3": return "AC-3"
        case "alac": return "ALAC"
        case "flac", "fLaC": return "FLAC"
        default:
            let ext = MimeTypes.fileExtension(relPath).uppercased()
            return ext
        }
    }

    static func formatDuration(seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        let secText = sec < 10 ? "0\(sec)" : "\(sec)"
        if h > 0 {
            let minText = m < 10 ? "0\(m)" : "\(m)"
            return "\(h):\(minText):\(secText)"
        }
        return "\(m):\(secText)"
    }
}

/// HTTP 伺服器實際要送出的檔案。
struct ServedFile {
    var fileId: String
    var url: URL
    var displayName: String
    var mimeType: String
    var sizeBytes: Int64
}

/// fileId → 檔案 的註冊表。HTTP 伺服器在背景佇列讀、曲庫在主執行緒寫，所以加鎖。
final class MediaRegistry {
    static let shared = MediaRegistry()

    private let lock = NSLock()
    private var items: [String: ServedFile] = [:]

    func replaceAll(_ files: [ServedFile]) {
        lock.lock()
        items.removeAll(keepingCapacity: true)
        for file in files { items[file.fileId] = file }
        lock.unlock()
    }

    func get(_ fileId: String) -> ServedFile? {
        lock.lock()
        defer { lock.unlock() }
        return items[fileId]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    /// 交給 Sonos 的 URL —— 必須是手機在區網中的位址，絕不能是 127.0.0.1
    static func streamUrl(ip: String, port: Int, track: Track) -> String {
        return "http://\(ip):\(port)/stream/\(track.id)\(MimeTypes.urlSuffix(track.mimeType))"
    }

    /// 從音箱回讀的 TrackURI 取出 fileId（`…/stream/<id>.<ext>`）
    static func fileId(fromStreamUri uri: String) -> String? {
        guard let r = uri.range(of: "/stream/") else { return nil }
        let tail = uri[r.upperBound...]
        let segment = tail.split(separator: "/").first.map(String.init) ?? ""
        let id = segment.split(separator: ".").first.map(String.init) ?? ""
        return id.isEmpty ? nil : id
    }
}
