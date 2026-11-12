import Foundation

/// 讀取本地音訊檔的真實取樣率 / 位元深度，用來在推流前判斷音箱能不能放。
///
/// Sonos 本地音樂封頂 48 kHz；WAV / AIFF 只支援 16 bit。超規格的檔案不會報錯，
/// 而是「拉一段資料後自己跳過」，看起來像 App 的 bug。
enum AudioProbe {

    struct Format: Equatable {
        var codec: String
        var sampleRate: Int
        var bits: Int
    }

    /// 只需要檔頭前 64 位元組；認不出就回 nil（放行）
    static func probe(header b: [UInt8]) -> Format? {
        if b.count < 42 { return nil }
        return parseFlac(b) ?? parseWav(b) ?? parseAiff(b)
    }

    static func probe(fileURL: URL) -> Format? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64)
        return probe(header: [UInt8](data))
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> Int {
        return (Int(b[o]) << 24) | (Int(b[o + 1]) << 16) | (Int(b[o + 2]) << 8) | Int(b[o + 3])
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> Int {
        return Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24)
    }

    private static func le16(_ b: [UInt8], _ o: Int) -> Int {
        return Int(b[o]) | (Int(b[o + 1]) << 8)
    }

    private static func tag(_ b: [UInt8], _ o: Int) -> String {
        return String(decoding: b[o..<(o + 4)], as: UTF8.self)
    }

    /// fLaC + STREAMINFO：取樣率 20 bit、位元深度 5 bit
    private static func parseFlac(_ b: [UInt8]) -> Format? {
        let n = b.count
        if n < 42 || tag(b, 0) != "fLaC" { return nil }
        let p = 8
        if n < p + 18 { return nil }
        let rate = (Int(b[p + 10]) << 12) | (Int(b[p + 11]) << 4) | (Int(b[p + 12]) >> 4)
        let bits = (((Int(b[p + 12]) & 0x01) << 4) | ((Int(b[p + 13]) & 0xF0) >> 4)) + 1
        if rate <= 0 { return nil }
        return Format(codec: "FLAC", sampleRate: rate, bits: bits)
    }

    /// RIFF/WAVE + fmt 區塊
    private static func parseWav(_ b: [UInt8]) -> Format? {
        let n = b.count
        if n < 36 || tag(b, 0) != "RIFF" { return nil }
        var o = 12
        while o + 8 <= n {
            let id = tag(b, o)
            let size = le32(b, o + 4)
            let data = o + 8
            if id == "fmt ", data + 16 <= n {
                let rate = le32(b, data + 4)
                let bits = le16(b, data + 14)
                return rate > 0 ? Format(codec: "WAV", sampleRate: rate, bits: bits) : nil
            }
            if size <= 0 { break }
            o = data + size + (size & 1)
        }
        return nil
    }

    /// FORM/AIFF + COMM 區塊（取樣率是 80-bit extended）
    private static func parseAiff(_ b: [UInt8]) -> Format? {
        let n = b.count
        if n < 40 || tag(b, 0) != "FORM" { return nil }
        var o = 12
        while o + 8 <= n {
            let id = tag(b, o)
            let size = be32(b, o + 4)
            let data = o + 8
            if id == "COMM", data + 18 <= n {
                let bits = (Int(b[data + 6]) << 8) | Int(b[data + 7])
                let exp = ((Int(b[data + 8]) & 0x7F) << 8) | Int(b[data + 9])
                var mantissa: UInt64 = 0
                for i in 0..<8 {
                    mantissa = (mantissa << 8) | UInt64(b[data + 10 + i])
                }
                var rate = 0
                if exp != 0 && mantissa != 0 {
                    let value = Double(mantissa) * pow(2.0, Double(exp - 16383 - 63))
                    if value.isFinite && value > 0 && value < 10_000_000 { rate = Int(value) }
                }
                return rate > 0 ? Format(codec: "AIFF", sampleRate: rate, bits: bits) : nil
            }
            if size <= 0 { break }
            o = data + size + (size & 1)
        }
        return nil
    }

    /// 超出 Sonos 規格：>48 kHz；WAV/AIFF 超過 16 bit
    static func isUnsupported(_ f: Format?) -> Bool {
        guard let f = f else { return false }
        if f.sampleRate > 48000 { return true }
        if f.codec == "WAV" || f.codec == "AIFF" { return f.bits > 16 }
        return f.bits > 24
    }

    /// 例如 "FLAC 96 kHz / 24 bit"
    static func describe(_ f: Format) -> String {
        let khz: String
        if f.sampleRate % 1000 == 0 {
            khz = "\(f.sampleRate / 1000) kHz"
        } else {
            let tenths = (f.sampleRate + 50) / 100
            khz = "\(tenths / 10).\(tenths % 10) kHz"
        }
        return "\(f.codec) \(khz) / \(f.bits) bit"
    }
}
