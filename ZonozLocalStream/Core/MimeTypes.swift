import Foundation

/// MIME 正規化。
///
/// Sonos 對 Content-Type 相當挑剔：錯的類型會直接回 714 Illegal MIME-Type，
/// 所以 HTTP 伺服器與 DIDL-Lite 的 protocolInfo 必須使用同一個值。
enum MimeTypes {

    static let defaultAudio = "audio/mpeg"

    private static let extToMime: [String: String] = [
        "mp3": "audio/mpeg",
        "mp2": "audio/mpeg",
        "m4a": "audio/mp4",
        "m4b": "audio/mp4",
        "mp4": "audio/mp4",
        "aac": "audio/aac",
        "flac": "audio/flac",
        "wav": "audio/wav",
        "wave": "audio/wav",
        "aif": "audio/aiff",
        "aiff": "audio/aiff",
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "opus": "audio/ogg",
        "wma": "audio/x-ms-wma",
        // 以下為 iOS 版新增的實驗性對應（原版 Android 沒有）：裸 Dolby 位元流
        "ec3": "audio/eac3",
        "eac3": "audio/eac3",
        "ac3": "audio/ac3"
    ]

    /// 原版列出的 Sonos 可解碼容器/編碼
    private static let sonosSupported: Set<String> = [
        "audio/mpeg", "audio/mp4", "audio/flac", "audio/wav", "audio/aiff",
        "audio/ogg", "audio/x-ms-wma", "audio/aac"
    ]

    /// 曲庫掃描時認得的副檔名
    static var audioExtensions: Set<String> { Set(extToMime.keys) }

    static func fileExtension(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: ".") else { return "" }
        return String(fileName[fileName.index(after: dot)...]).lowercased()
    }

    static func fromExtension(_ fileName: String) -> String? {
        return extToMime[fileExtension(fileName)]
    }

    static func resolve(fileName: String) -> String {
        return fromExtension(fileName) ?? defaultAudio
    }

    /// 為 URL 產生副檔名（含前導點）。URL 的副檔名與 MIME 一致能幫助音箱判斷格式。
    static func urlSuffix(_ mime: String) -> String {
        switch mime {
        case "audio/mpeg": return ".mp3"
        case "audio/mp4": return ".m4a"
        case "audio/aac": return ".aac"
        case "audio/flac": return ".flac"
        case "audio/wav": return ".wav"
        case "audio/aiff": return ".aiff"
        case "audio/ogg": return ".ogg"
        case "audio/x-ms-wma": return ".wma"
        case "audio/eac3": return ".ec3"
        case "audio/ac3": return ".ac3"
        default: return ""
        }
    }

    static func isSonosSupported(_ mime: String) -> Bool {
        return sonosSupported.contains(mime)
    }
}
