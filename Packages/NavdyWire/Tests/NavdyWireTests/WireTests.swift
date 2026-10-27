import XCTest
@testable import NavdyWire

extension Data {
    init(hexString: String) {
        var d = Data()
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            d.append(UInt8(hexString[i..<j], radix: 16)!)
            i = j
        }
        self = d
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Every expected byte string comes from Google's protobuf runtime (Tools/gen_vectors.py),
/// so these tests prove the hand-written codec matches the firmware's schema on the wire.
final class EncodeTests: XCTestCase {
    func testDeviceInfo() {
        var di = DeviceInfo()
        di.deviceId = "AA-BB"; di.clientVersion = "0.1"; di.protocolVersion = "1.0"
        di.deviceName = "iPhone"; di.systemVersion = "27.0"; di.model = "iPhone"; di.deviceUuid = "U-1"
        di.platform = DeviceInfo.platformIOS; di.deviceMake = "Apple"
        XCTAssertEqual(NavdyEvent.encode(.deviceInfo, di).hex, Vectors.deviceInfoEvent.hex)
    }

    func testPing() {
        XCTAssertEqual(NavdyEvent.encode(.ping, EmptyMessage()).hex, Vectors.pingEvent.hex)
        XCTAssertEqual(Framing.frame(NavdyEvent.encode(.ping, EmptyMessage())).hex, Vectors.pingFramed.hex)
    }

    func testRouteRequest() {
        let c = Coordinate(latitude: 25.033964, longitude: 121.564468)
        let rr = NavigationRouteRequest(destination: c, label: "台北101", streetAddress: "信義路五段7號",
                                        autoNavigate: true, requestId: "r1", destinationDisplay: c)
        XCTAssertEqual(NavdyEvent.encode(.navigationRouteRequest, rr).hex, Vectors.routeRequestEvent.hex)
    }

    func testStopSession() {
        let req = NavigationSessionRequest(newState: .stopped)
        XCTAssertEqual(NavdyEvent.encode(.navigationSessionRequest, req).hex, Vectors.stopSessionEvent.hex)
    }

    func testNegativeInt32IsTenBytes() {
        var w = ProtoWriter()
        w.int32(1, -1)
        XCTAssertEqual(w.data.count, 11)
    }
}

final class DecodeTests: XCTestCase {
    func testDeviceInfoRoundTrip() throws {
        guard case .deviceInfo(let di) = try NavdyEvent.decode(Vectors.deviceInfoEvent) else { return XCTFail() }
        XCTAssertEqual(di.deviceName, "iPhone")
        XCTAssertEqual(di.systemVersion, "27.0")
        XCTAssertEqual(di.platform, DeviceInfo.platformIOS)
        XCTAssertEqual(di.deviceMake, "Apple")
    }

    func testRouteResponse() throws {
        guard case .routeResponse(let r) = try NavdyEvent.decode(Vectors.routeResponseEvent) else { return XCTFail() }
        XCTAssertEqual(r.status, .success)
        XCTAssertEqual(r.label, "台北101")
        XCTAssertEqual(r.requestId, "r1")
        XCTAssertEqual(r.destination, Coordinate(latitude: 25.0, longitude: 121.5))
        XCTAssertEqual(r.results.count, 1)
        XCTAssertEqual(r.results[0].routeId, "R7")
        XCTAssertEqual(r.results[0].lengthMeters, 12345)
        XCTAssertEqual(r.results[0].durationSeconds, 900)
        XCTAssertEqual(r.results[0].via, "國道1號")
    }

    func testManeuver() throws {
        guard case .maneuver(let m) = try NavdyEvent.decode(Vectors.maneuverEvent) else { return XCTFail() }
        XCTAssertEqual(m.currentRoad, "中山路")
        XCTAssertEqual(m.pendingTurn, .left)
        XCTAssertEqual(m.distanceToPendingTurn, "300 m")
        XCTAssertEqual(m.pendingStreet, "民生路")
        XCTAssertEqual(m.eta, "14:05")
        XCTAssertEqual(m.navigationState, .started)
        XCTAssertEqual(m.etaUtcTime, 1_793_040_000_000)
    }

    func testSessionStatus() throws {
        guard case .sessionStatus(let s) = try NavdyEvent.decode(Vectors.sessionStatusEvent) else { return XCTFail() }
        XCTAssertEqual(s.sessionState, .arrived)
        XCTAssertEqual(s.routeId, "R7")
    }

    func testPingDecode() throws {
        guard case .ping = try NavdyEvent.decode(Vectors.pingEvent) else { return XCTFail() }
    }

    func testUnknownTypeIsTolerated() throws {
        var w = ProtoWriter()
        w.int32(2, 999)
        guard case .other(let t) = try NavdyEvent.decode(w.data) else { return XCTFail() }
        XCTAssertEqual(t, 999)
    }
}

final class FramingTests: XCTestCase {
    func testByteByByteReassembly() throws {
        var stream = Framing.frame(Vectors.maneuverEvent)
        stream.append(Vectors.pingFramed)
        stream.append(Framing.frame(Vectors.routeResponseEvent))
        var d = Deframer()
        var got: [Data] = []
        for byte in stream { got += try d.append(Data([byte])) }
        XCTAssertEqual(got, [Vectors.maneuverEvent, Vectors.pingEvent, Vectors.routeResponseEvent])
        XCTAssertEqual(d.bufferedByteCount, 0)
    }

    func testBadHeaderThrows() {
        var d = Deframer()
        XCTAssertThrowsError(try d.append(Data([0x0A, 1, 0, 0, 0, 0])))
    }
}
