import Foundation

/// 判斷 MP4 容器裡的 E-AC-3 是否帶 Dolby Atmos（JOC）擴充。
///
/// 依據 ETSI TS 103 420：`dec3`（EC3SpecificBox）在各子串流描述之後若還有位元組，
/// 其中的 flag_ec3_extension_type_a = 1 即代表 E-AC-3 JOC（Atmos）。
/// 這只是用來在曲庫顯示徽章，不影響推流行為。
enum Dolby {

    struct Ec3Info: Equatable {
        var isJOC: Bool
        var complexityIndex: Int
    }

    /// `payload` 是 dec3 box 去掉 8 位元組 box 頭之後的內容。
    static func parseDec3(payload: [UInt8]) -> Ec3Info? {
        var reader = BitReader(bytes: payload)
        guard reader.read(13) != nil, let numIndSubMinus1 = reader.read(3) else { return nil }
        for _ in 0...numIndSubMinus1 {
            // fscod 2, bsid 5, reserved 1, asvc 1, bsmod 3, acmod 3, lfeon 1, reserved 3
            guard reader.read(19) != nil, let numDepSub = reader.read(4) else { return nil }
            if numDepSub > 0 {
                guard reader.read(9) != nil else { return nil }
            } else {
                guard reader.read(1) != nil else { return nil }
            }
        }
        if reader.bitsRemaining >= 16 {
            guard reader.read(7) != nil, let flag = reader.read(1), let complexity = reader.read(8) else {
                return Ec3Info(isJOC: false, complexityIndex: 0)
            }
            return Ec3Info(isJOC: flag == 1, complexityIndex: complexity)
        }
        return Ec3Info(isJOC: false, complexityIndex: 0)
    }

    /// 在一段 `moov` 資料裡找第一個 dec3 box，回傳其內容。
    static func findDec3(inMoov data: [UInt8]) -> [UInt8]? {
        let pattern: [UInt8] = [0x64, 0x65, 0x63, 0x33] // "dec3"
        let n = data.count
        if n < 12 { return nil }
        var i = 4
        while i + 4 <= n {
            if data[i] == pattern[0] && data[i + 1] == pattern[1] && data[i + 2] == pattern[2] && data[i + 3] == pattern[3] {
                let size = (Int(data[i - 4]) << 24) | (Int(data[i - 3]) << 16) | (Int(data[i - 2]) << 8) | Int(data[i - 1])
                if size >= 10 && size <= 64 && (i - 4) + size <= n {
                    return Array(data[(i + 4)..<((i - 4) + size)])
                }
            }
            i += 1
        }
        return nil
    }

    struct BitReader {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var bitsRemaining: Int { bytes.count * 8 - position }

        mutating func read(_ count: Int) -> Int? {
            if count <= 0 || count > 32 || bitsRemaining < count { return nil }
            var value = 0
            for _ in 0..<count {
                let byte = bytes[position / 8]
                let bit = (Int(byte) >> (7 - (position % 8))) & 1
                value = (value << 1) | bit
                position += 1
            }
            return value
        }
    }
}

/// MP4 頂層 box 走訪：找出 `moov` 的位置，供讀檔層把它載入記憶體。
enum Mp4Boxes {
    struct Box: Equatable {
        var type: String
        var offset: UInt64
        var size: UInt64
        var headerSize: UInt64
    }

    /// 解析一個 box 頭（至少 16 位元組的緩衝）。size==0（延伸到檔尾）以 fileSize 補上。
    static func parseHeader(_ b: [UInt8], at offset: UInt64, fileSize: UInt64) -> Box? {
        if b.count < 8 { return nil }
        var size = (UInt64(b[0]) << 24) | (UInt64(b[1]) << 16) | (UInt64(b[2]) << 8) | UInt64(b[3])
        let type = String(decoding: b[4..<8], as: UTF8.self)
        var headerSize: UInt64 = 8
        if size == 1 {
            if b.count < 16 { return nil }
            size = 0
            for i in 8..<16 { size = (size << 8) | UInt64(b[i]) }
            headerSize = 16
        } else if size == 0 {
            size = fileSize > offset ? fileSize - offset : 0
        }
        if size < headerSize { return nil }
        return Box(type: type, offset: offset, size: size, headerSize: headerSize)
    }
}
