import Foundation

/// Stream framing used on the com.navdy.hud.api.v1 session (see NavdyEventReader/Writer in the
/// HUD firmware): every NavdyEvent is preceded by a serialized `Frame { required fixed32 size = 1; }`,
/// which is always exactly 5 bytes: 0x0D followed by the size as little-endian UInt32.
public enum Framing {
    public static let headerLength = 5
    public static let maxEventSize = 4 * 1024 * 1024

    public static func frame(_ event: Data) -> Data {
        var w = ProtoWriter()
        w.fixed32(1, UInt32(event.count))
        var out = w.data
        out.append(event)
        return out
    }
}

/// Reassembles events from arbitrary stream chunks.
public struct Deframer {
    private var buffer: [UInt8] = []
    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func reset() { buffer.removeAll() }

    /// Feed received bytes; returns every complete event payload now available.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(contentsOf: chunk)
        var events: [Data] = []
        while buffer.count >= Framing.headerLength {
            let tag = buffer[0]
            guard tag == 0x0D else {
                buffer.removeAll()
                throw ProtoError("bad frame header 0x\(String(tag, radix: 16))")
            }
            let size = Int(buffer[1]) | Int(buffer[2]) << 8 | Int(buffer[3]) << 16 | Int(buffer[4]) << 24
            guard size > 0, size <= Framing.maxEventSize else {
                buffer.removeAll()
                throw ProtoError("bad frame size \(size)")
            }
            guard buffer.count >= Framing.headerLength + size else { break }
            events.append(Data(buffer[Framing.headerLength ..< Framing.headerLength + size]))
            buffer.removeFirst(Framing.headerLength + size)
        }
        return events
    }
}
