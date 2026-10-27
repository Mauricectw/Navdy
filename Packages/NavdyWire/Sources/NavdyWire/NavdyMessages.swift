import Foundation

// Hand-written subset of the Navdy protocol (full schema: Proto/navdy.proto, regenerated from the
// HUD firmware's Wire classes). Field numbers below are taken from that schema.

/// NavdyEvent.MessageType. A payload of type T is carried in NavdyEvent field number T + 100.
public enum MessageType: Int32 {
    case navigationManeuverEvent = 8
    case navigationRouteRequest = 9
    case navigationRouteResponse = 10
    case navigationSessionRequest = 11
    case navigationSessionResponse = 12
    case navigationSessionStatusEvent = 13
    case connectionStateChange = 22
    case deviceInfo = 27
    case ping = 40
    case disconnectRequest = 53
    case getNavigationSessionState = 55
    case navigationRouteStatus = 88
    case navigationRouteCancelRequest = 89

    public var payloadField: Int { Int(rawValue) + 100 }
}

/// navdy.NavigationPkg.NavigationSessionState
public enum NavigationSessionState: Int32 {
    case engineNotReady = 1, locationServicesNotReady = 2, stopped = 3, started = 4, paused = 5
    case error = 6, rerouted = 7, engineReady = 8, arrived = 9
}

/// navdy.RequestStatus
public enum RequestStatus: Int32 {
    case success = 1, notReady = 2, noLocationService = 3, serviceError = 4, invalidRequest = 5
    case invalidState = 6, unknownError = 7, versionIsCurrent = 8, notAvailable = 9
    case alreadyInProgress = 10, cancelled = 11
}

/// navdy.NavigationPkg.NavigationTurn
public enum NavigationTurn: Int32 {
    case start = 1, easyLeft, easyRight, end, keepLeft, keepRight, left, outOfRoute, right
    case sharpLeft, sharpRight, straight, uturnLeft, uturnRight
    case roundaboutSE, roundaboutE, roundaboutNE, roundaboutN, roundaboutNW, roundaboutW
    case roundaboutSW, roundaboutS, ferry, stateBoundary, followRoute, exitRight, exitLeft
    case motorway, exitRoundabout, unknown, mergeLeft, mergeRight
}

// MARK: - Messages

public struct Coordinate: ProtoEncodable, ProtoDecodable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude; self.longitude = longitude
    }
    public func encode(to w: inout ProtoWriter) {
        w.double(1, latitude)
        w.double(2, longitude)
    }
    public init(serialized: Data) throws {
        var lat: Double?, lon: Double?
        for f in try ProtoReader.fields(serialized) {
            switch f.number {
            case 1: lat = f.value.double
            case 2: lon = f.value.double
            default: break
            }
        }
        guard let lat, let lon else { throw ProtoError("Coordinate missing lat/lon") }
        latitude = lat; longitude = lon
    }
}

/// navdy.DeviceInfo — sent by both sides right after the link opens.
public struct DeviceInfo: ProtoEncodable, ProtoDecodable {
    public static let platformIOS: Int32 = 1
    public static let platformAndroid: Int32 = 2

    public var deviceId = ""
    public var clientVersion = ""
    public var protocolVersion = "1.0"
    public var deviceName = ""
    public var systemVersion = ""
    public var model = ""
    public var deviceUuid = ""
    public var platform: Int32?
    public var deviceMake: String?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        w.string(1, deviceId)
        w.string(2, clientVersion)
        w.string(3, protocolVersion)
        w.string(4, deviceName)
        w.string(5, systemVersion)
        w.string(6, model)
        w.string(7, deviceUuid)
        w.int32(10, platform)
        w.string(12, deviceMake)
    }

    public init(serialized: Data) throws {
        for f in try ProtoReader.fields(serialized) {
            switch f.number {
            case 1: deviceId = f.value.string ?? ""
            case 2: clientVersion = f.value.string ?? ""
            case 3: protocolVersion = f.value.string ?? ""
            case 4: deviceName = f.value.string ?? ""
            case 5: systemVersion = f.value.string ?? ""
            case 6: model = f.value.string ?? ""
            case 7: deviceUuid = f.value.string ?? ""
            case 10: platform = f.value.int32
            case 12: deviceMake = f.value.string
            default: break
            }
        }
    }
}

public struct NavigationRouteRequest: ProtoEncodable {
    public var destination: Coordinate
    public var label: String?
    public var streetAddress: String?
    /// When true the HUD starts navigating on the first route it calculates (HereRouteManager).
    public var autoNavigate: Bool?
    public var requestId: String?
    public var destinationDisplay: Coordinate?

    public init(destination: Coordinate, label: String? = nil, streetAddress: String? = nil,
                autoNavigate: Bool? = true, requestId: String? = nil, destinationDisplay: Coordinate? = nil) {
        self.destination = destination; self.label = label; self.streetAddress = streetAddress
        self.autoNavigate = autoNavigate; self.requestId = requestId; self.destinationDisplay = destinationDisplay
    }

    public func encode(to w: inout ProtoWriter) {
        w.message(1, destination)
        w.string(2, label)
        w.string(4, streetAddress)
        w.bool(6, autoNavigate)
        w.string(11, requestId)
        w.message(12, destinationDisplay)
    }
}

public struct NavigationSessionRequest: ProtoEncodable {
    public var newState: NavigationSessionState
    public var label: String?
    public var routeId: String?
    public init(newState: NavigationSessionState, label: String? = nil, routeId: String? = nil) {
        self.newState = newState; self.label = label; self.routeId = routeId
    }
    public func encode(to w: inout ProtoWriter) {
        w.int32(1, newState.rawValue)
        w.string(2, label)
        w.string(3, routeId)
    }
}

public struct NavigationRouteCancelRequest: ProtoEncodable {
    public var handle: String?
    public init(handle: String? = nil) { self.handle = handle }
    public func encode(to w: inout ProtoWriter) { w.string(1, handle) }
}

public struct EmptyMessage: ProtoEncodable {
    public init() {}
    public func encode(to w: inout ProtoWriter) {}
}

public struct NavigationRouteResult: ProtoDecodable {
    public var routeId = ""
    public var label: String?
    public var lengthMeters: UInt32 = 0
    public var durationSeconds: UInt32 = 0
    public var durationTrafficSeconds: UInt32?
    public var via: String?
    public var address: String?

    public init(serialized: Data) throws {
        for f in try ProtoReader.fields(serialized) {
            switch f.number {
            case 1: routeId = f.value.string ?? ""
            case 2: label = f.value.string
            case 4: lengthMeters = f.value.uint32 ?? 0
            case 5: durationSeconds = f.value.uint32 ?? 0
            case 6: durationTrafficSeconds = f.value.uint32
            case 8: via = f.value.string
            case 9: address = f.value.string
            default: break
            }
        }
    }
}

public struct NavigationRouteResponse: ProtoDecodable {
    public var statusRaw: Int32 = 0
    public var status: RequestStatus? { RequestStatus(rawValue: statusRaw) }
    public var statusDetail: String?
    public var destination: Coordinate?
    public var label: String?
    public var results: [NavigationRouteResult] = []
    public var requestId: String?

    public init(serialized: Data) throws {
        for f in try ProtoReader.fields(serialized) {
            switch f.number {
            case 1: statusRaw = f.value.int32 ?? 0
            case 2: statusDetail = f.value.string
            case 3: destination = try f.value.data.map(Coordinate.init(serialized:))
            case 4: label = f.value.string
            case 5: if let d = f.value.data { results.append(try NavigationRouteResult(serialized: d)) }
            case 7: requestId = f.value.string
            default: break
            }
        }
    }
}

public struct NavigationManeuverEvent: ProtoDecodable {
    public var currentRoad = ""
    public var pendingTurnRaw: Int32 = 0
    public var pendingTurn: NavigationTurn? { NavigationTurn(rawValue: pendingTurnRaw) }
    public var distanceToPendingTurn = ""
    public var pendingStreet = ""
    public var eta = ""
    public var speed = ""
    public var navigationStateRaw: Int32?
    public var navigationState: NavigationSessionState? { navigationStateRaw.flatMap(NavigationSessionState.init(rawValue:)) }
    public var etaUtcTime: Int64?

    public init(serialized: Data) throws {
        for f in try ProtoReader.fields(serialized) {
            switch f.number {
            case 1: currentRoad = f.value.string ?? ""
            case 2: pendingTurnRaw = f.value.int32 ?? 0
            case 3: distanceToPendingTurn = f.value.string ?? ""
            case 4: pendingStreet = f.value.string ?? ""
            case 5: eta = f.value.string ?? ""
            case 6: speed = f.value.string ?? ""
            case 7: navigationStateRaw = f.value.int32
            case 8: etaUtcTime = f.value.int64
            default: break
            }
        }
    }
}

public struct NavigationSessionStatusEvent: ProtoDecodable {
    public var sessionStateRaw: Int32 = 0
    public var sessionState: NavigationSessionState? { NavigationSessionState(rawValue: sessionStateRaw) }
    public var label: String?
    public var routeId: String?
    public var route: NavigationRouteResult?

    public init(serialized: Data) throws {
        for f in try ProtoReader.fields(serialized) {
            switch f.number {
            case 1: sessionStateRaw = f.value.int32 ?? 0
            case 2: label = f.value.string
            case 3: routeId = f.value.string
            case 4: route = try f.value.data.map(NavigationRouteResult.init(serialized:))
            default: break
            }
        }
    }
}

public struct NavigationSessionResponse: ProtoDecodable {
    public var statusRaw: Int32 = 0
    public var status: RequestStatus? { RequestStatus(rawValue: statusRaw) }
    public var statusDetail: String?
    public var pendingSessionStateRaw: Int32?
    public var routeId: String?

    public init(serialized: Data) throws {
        for f in try ProtoReader.fields(serialized) {
            switch f.number {
            case 1: statusRaw = f.value.int32 ?? 0
            case 2: statusDetail = f.value.string
            case 3: pendingSessionStateRaw = f.value.int32
            case 4: routeId = f.value.string
            default: break
            }
        }
    }
}

public struct NavigationRouteStatus: ProtoDecodable {
    public var handle: String?
    public var progress: Int32?
    public var requestId: String?
    public init(serialized: Data) throws {
        for f in try ProtoReader.fields(serialized) {
            switch f.number {
            case 1: handle = f.value.string
            case 2: progress = f.value.int32
            case 3: requestId = f.value.string
            default: break
            }
        }
    }
}

// MARK: - Envelope

/// A decoded event from the HUD.
public enum HUDEvent {
    case deviceInfo(DeviceInfo)
    case ping
    case maneuver(NavigationManeuverEvent)
    case routeResponse(NavigationRouteResponse)
    case routeStatus(NavigationRouteStatus)
    case sessionStatus(NavigationSessionStatusEvent)
    case sessionResponse(NavigationSessionResponse)
    case disconnectRequest
    case other(type: Int32)
}

public enum NavdyEvent {
    /// Serializes NavdyEvent{ type = 2; <payload> = type + 100 }.
    public static func encode<M: ProtoEncodable>(_ type: MessageType, _ payload: M) -> Data {
        var w = ProtoWriter()
        w.int32(2, type.rawValue)
        w.message(type.payloadField, payload)
        return w.data
    }

    public static func decode(_ data: Data) throws -> HUDEvent {
        let fields = try ProtoReader.fields(data)
        guard let typeRaw = fields.first(where: { $0.number == 2 })?.value.int32 else {
            throw ProtoError("NavdyEvent without type")
        }
        guard let type = MessageType(rawValue: typeRaw) else { return .other(type: typeRaw) }
        let payload = fields.first(where: { $0.number == type.payloadField })?.value.data ?? Data()
        switch type {
        case .deviceInfo: return .deviceInfo(try DeviceInfo(serialized: payload))
        case .ping: return .ping
        case .navigationManeuverEvent: return .maneuver(try NavigationManeuverEvent(serialized: payload))
        case .navigationRouteResponse: return .routeResponse(try NavigationRouteResponse(serialized: payload))
        case .navigationRouteStatus: return .routeStatus(try NavigationRouteStatus(serialized: payload))
        case .navigationSessionStatusEvent: return .sessionStatus(try NavigationSessionStatusEvent(serialized: payload))
        case .navigationSessionResponse: return .sessionResponse(try NavigationSessionResponse(serialized: payload))
        case .disconnectRequest: return .disconnectRequest
        default: return .other(type: typeRaw)
        }
    }
}
