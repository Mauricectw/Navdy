import Combine
import Foundation
import NavdyWire
import UIKit

/// App-level state: owns the link, does the handshake and keeps the HUD alive.
///
/// Protocol behaviour mirrors the firmware's ConnectionService:
///   - each side sends DeviceInfo once the link is up (protocolVersion "1.0");
///   - the HUD drops a link after 60 s without any incoming message and pings every 4 s,
///     so we ping on a timer and also answer the HUD's pings (timers pause in background,
///     incoming data still wakes us thanks to the external-accessory background mode).
final class HUDController: ObservableObject {
    enum Connection: Equatable {
        case searching
        case connecting(String)
        case connected(String)
    }

    @Published private(set) var connection: Connection = .searching
    @Published private(set) var hudInfo: DeviceInfo?
    @Published private(set) var maneuver: NavigationManeuverEvent?
    @Published private(set) var sessionState: NavigationSessionState?
    @Published private(set) var activeLabel: String?
    @Published private(set) var lastRouteStatus: String?
    @Published private(set) var logLines: [String] = []

    private let link = HUDLink()
    private var pingTimer: Timer?
    private var lastSent = Date.distantPast

    init() {
        link.log = { [weak self] in self?.log($0) }
        link.onStateChange = { [weak self] in self?.linkStateChanged($0) }
        link.onEvent = { [weak self] in self?.received($0) }
        link.start()
    }

    // MARK: - Actions

    func pair() { link.showPairingPicker() }
    func rescan() { link.scanConnectedAccessories() }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    func navigate(to dest: Destination) {
        let c = Coordinate(latitude: dest.latitude, longitude: dest.longitude)
        let request = NavigationRouteRequest(destination: c, label: dest.name, streetAddress: dest.address,
                                             autoNavigate: true, requestId: UUID().uuidString,
                                             destinationDisplay: c)
        activeLabel = dest.name
        lastRouteStatus = "已送出路線請求，等待 HUD 計算…"
        send(.navigationRouteRequest, request)
        log("→ 路線請求：\(dest.name) (\(dest.latitude), \(dest.longitude))")
    }

    func note(_ s: String) { log(s) }

    func stopNavigation() {
        send(.navigationSessionRequest, NavigationSessionRequest(newState: .stopped))
        log("→ 停止導航")
    }

    // MARK: - Link callbacks

    private func linkStateChanged(_ state: HUDLink.State) {
        switch state {
        case .waitingForAccessory:
            connection = .searching
            hudInfo = nil
            maneuver = nil
            pingTimer?.invalidate(); pingTimer = nil
        case .opening(let name):
            connection = .connecting(name)
        case .open(let name):
            connection = .connected(name)
            sendDeviceInfo()
            send(.getNavigationSessionState, EmptyMessage())
            pingTimer?.invalidate()
            pingTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                self?.pingIfIdle()
            }
        }
    }

    private func received(_ bytes: Data) {
        let event: HUDEvent
        do { event = try NavdyEvent.decode(bytes) } catch {
            log("← 無法解析 (\(bytes.count) bytes)：\(error)")
            return
        }
        switch event {
        case .ping:
            pingIfIdle()
        case .deviceInfo(let info):
            hudInfo = info
            log("← HUD：\(info.deviceName) 韌體 \(info.clientVersion) 協定 \(info.protocolVersion)")
        case .maneuver(let m):
            maneuver = m
            if let s = m.navigationState { sessionState = s }
        case .routeResponse(let r):
            if r.status == .success, let first = r.results.first {
                lastRouteStatus = "路線：\(Self.km(first.lengthMeters))，約 \(first.durationSeconds / 60) 分鐘" +
                    (first.via.map { "，經 \($0)" } ?? "")
            } else {
                lastRouteStatus = "路線失敗：\(r.status.map { "\($0)" } ?? "\(r.statusRaw)") \(r.statusDetail ?? "")"
            }
            log("← 路線回應 status=\(r.statusRaw) 結果數=\(r.results.count)")
        case .routeStatus(let s):
            if let p = s.progress { lastRouteStatus = "HUD 計算路線中… \(p)%" }
        case .sessionStatus(let s):
            sessionState = s.sessionState
            if let label = s.label { activeLabel = label }
            if s.sessionState == .stopped || s.sessionState == .arrived { maneuver = nil }
            log("← 導航狀態：\(s.sessionState.map { "\($0)" } ?? "\(s.sessionStateRaw)")")
        case .sessionResponse(let r):
            log("← 導航指令回應 status=\(r.statusRaw) \(r.statusDetail ?? "")")
        case .disconnectRequest:
            log("← HUD 要求斷線")
        case .other(let type):
            log("← 未處理的訊息類型 \(type)")
        }
    }

    // MARK: - Sending

    private func send<M: ProtoEncodable>(_ type: MessageType, _ payload: M) {
        guard case .connected = connection else {
            log("尚未連線，略過 \(type)")
            return
        }
        link.send(NavdyEvent.encode(type, payload))
        lastSent = Date()
    }

    private func pingIfIdle() {
        if Date().timeIntervalSince(lastSent) > 3 { send(.ping, EmptyMessage()) }
    }

    private func sendDeviceInfo() {
        let id = Self.stableDeviceId()
        var di = DeviceInfo()
        di.deviceId = id
        di.clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        di.protocolVersion = "1.0"
        di.deviceName = UIDevice.current.name
        di.systemVersion = UIDevice.current.systemVersion
        di.model = Self.hardwareModel()
        di.deviceUuid = id
        di.platform = DeviceInfo.platformIOS
        di.deviceMake = "Apple"
        send(.deviceInfo, di)
        log("→ DeviceInfo（iOS \(di.systemVersion), \(di.model)）")
    }

    // MARK: - Helpers

    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        logLines.append("\(f.string(from: Date())) \(s)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private static func stableDeviceId() -> String {
        let key = "navdy.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func km(_ meters: UInt32) -> String {
        meters >= 1000 ? String(format: "%.1f 公里", Double(meters) / 1000) : "\(meters) 公尺"
    }
}
