import Foundation

// Minimal protobuf (proto2) wire-format codec. Only what the Navdy messages need.
// Encoders must write fields in ascending field-number order so output is byte-identical
// to Google's/Square Wire's serializers (checked by the unit tests).

public enum WireType: UInt8 {
    case varint = 0, fixed64 = 1, lengthDelimited = 2, startGroup = 3, endGroup = 4, fixed32 = 5
}

public struct ProtoError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

public struct ProtoWriter {
    public private(set) var data = Data()
    public init() {}

    mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        data.append(UInt8(truncatingIfNeeded: v))
    }

    mutating func key(_ field: Int, _ type: WireType) {
        rawVarint(UInt64(field) << 3 | UInt64(type.rawValue))
    }

    public mutating func uint64(_ field: Int, _ v: UInt64) { key(field, .varint); rawVarint(v) }
    public mutating func uint32(_ field: Int, _ v: UInt32) { uint64(field, UInt64(v)) }
    /// int32/enum: negative values are sign-extended to 10 bytes, as protobuf specifies.
    public mutating func int32(_ field: Int, _ v: Int32) { uint64(field, UInt64(bitPattern: Int64(v))) }
    public mutating func int64(_ field: Int, _ v: Int64) { uint64(field, UInt64(bitPattern: v)) }
    public mutating func bool(_ field: Int, _ v: Bool) { uint64(field, v ? 1 : 0) }

    public mutating func double(_ field: Int, _ v: Double) {
        key(field, .fixed64)
        appendLittleEndian(v.bitPattern)
    }
    public mutating func float(_ field: Int, _ v: Float) {
        key(field, .fixed32)
        appendLittleEndian(v.bitPattern)
    }
    public mutating func fixed32(_ field: Int, _ v: UInt32) {
        key(field, .fixed32)
        appendLittleEndian(v)
    }
    public mutating func bytes(_ field: Int, _ v: Data) {
        key(field, .lengthDelimited)
        rawVarint(UInt64(v.count))
        data.append(v)
    }
    public mutating func string(_ field: Int, _ v: String) { bytes(field, Data(v.utf8)) }
    public mutating func message<M: ProtoEncodable>(_ field: Int, _ m: M) { bytes(field, m.serialized()) }

    // Optional helpers: proto2 only writes fields that are set.
    public mutating func string(_ field: Int, _ v: String?) { if let v { string(field, v) } }
    public mutating func bool(_ field: Int, _ v: Bool?) { if let v { bool(field, v) } }
    public mutating func int32(_ field: Int, _ v: Int32?) { if let v { int32(field, v) } }
    public mutating func message<M: ProtoEncodable>(_ field: Int, _ m: M?) { if let m { message(field, m) } }

    private mutating func appendLittleEndian<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}

public enum FieldValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(Data)

    public var uint64: UInt64? { if case .varint(let v) = self { return v }; return nil }
    public var int32: Int32? { uint64.map { Int32(truncatingIfNeeded: Int64(bitPattern: $0)) } }
    public var int64: Int64? { uint64.map { Int64(bitPattern: $0) } }
    public var uint32: UInt32? { uint64.map { UInt32(truncatingIfNeeded: $0) } }
    public var bool: Bool? { uint64.map { $0 != 0 } }
    public var data: Data? { if case .bytes(let d) = self { return d }; return nil }
    public var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    public var double: Double? { if case .fixed64(let v) = self { return Double(bitPattern: v) }; return nil }
    public var float: Float? { if case .fixed32(let v) = self { return Float(bitPattern: v) }; return nil }
}

public struct ProtoField {
    public let number: Int
    public let value: FieldValue
}

public enum ProtoReader {
    /// Splits a serialized message into its fields (unknown fields included, groups rejected).
    public static func fields(_ data: Data) throws -> [ProtoField] {
        let b = [UInt8](data)   // copy: Data slices may not start at index 0
        var i = 0
        var out: [ProtoField] = []

        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < b.count else { throw ProtoError("truncated varint") }
                let byte = b[i]; i += 1
                if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 70 { throw ProtoError("varint too long") }
            }
        }
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, i + n <= b.count else { throw ProtoError("truncated field") }
            defer { i += n }
            return b[i..<(i + n)]
        }
        func littleEndian(_ s: ArraySlice<UInt8>) -> UInt64 {
            s.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        while i < b.count {
            let key = try varint()
            let number = Int(key >> 3)
            guard number > 0, let type = WireType(rawValue: UInt8(key & 7)) else {
                throw ProtoError("bad key \(key)")
            }
            switch type {
            case .varint: out.append(ProtoField(number: number, value: .varint(try varint())))
            case .fixed64: out.append(ProtoField(number: number, value: .fixed64(littleEndian(try take(8)))))
            case .fixed32:
                out.append(ProtoField(number: number, value: .fixed32(UInt32(littleEndian(try take(4))))))
            case .lengthDelimited:
                let len = try varint()
                guard len <= UInt64(b.count) else { throw ProtoError("length too large") }
                out.append(ProtoField(number: number, value: .bytes(Data(try take(Int(len))))))
            case .startGroup, .endGroup:
                throw ProtoError("groups not supported")
            }
        }
        return out
    }
}

public protocol ProtoEncodable {
    func encode(to w: inout ProtoWriter)
}

public extension ProtoEncodable {
    func serialized() -> Data {
        var w = ProtoWriter()
        encode(to: &w)
        return w.data
    }
}

public protocol ProtoDecodable {
    init(serialized: Data) throws
}
