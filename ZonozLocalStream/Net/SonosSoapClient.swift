import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SoapResult {
    case success(String)
    case fault(httpStatus: Int, errorCode: Int?, description: String, raw: String)
    case transportError(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var body: String? {
        if case .success(let body) = self { return body }
        return nil
    }

    var faultCode: Int? {
        if case .fault(_, let code, _, _) = self { return code }
        return nil
    }

    var failureText: String {
        switch self {
        case .success: return "OK"
        case .fault(_, let code, let description, _):
            return "UPnP \(code.map(String.init) ?? "-") \(description)"
        case .transportError(let message): return message
        }
    }
}

/// 音箱目前的狀態快照 —— 重新進 App 時主動問音箱，而不是依賴本地可能已遺失的狀態。
struct TransportSnapshot {
    var state: String
    var uri: String
    var title: String
    var positionSec: Int
    var durationSec: Int
    var trackNumber: Int

    var isPlaying: Bool { state == "PLAYING" || state == "TRANSITIONING" }
    var isPaused: Bool { state == "PAUSED_PLAYBACK" }
}

/// GetPositionInfo 一次能拿到的全部欄位（省掉重複請求）。
struct PositionInfo {
    var trackNumber: Int?
    var trackUri: String
    var positionSec: Int
    var durationSec: Int
}

/// Sonos 的 UPnP 控制客戶端：拼 SOAP 信封、POST 到 1400 埠、把 UPnP Fault 翻成錯誤碼。
final class SonosSoapClient: @unchecked Sendable {

    private let session: URLSession
    /// 高頻輪詢請求不逐條寫日誌
    private static let quietActions: Set<String> = [
        "GetPositionInfo", "GetTransportInfo", "GetVolume", "GetMediaInfo"
    ]
    private static let zoneGroupTopologyPath = "/ZoneGroupTopology/Control"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        #if !canImport(FoundationNetworking)
        // 只走 Wi-Fi：開著行動網路 / VPN 時也不要把區網請求送錯介面
        config.allowsCellularAccess = false
        config.waitsForConnectivity = false
        #endif
        session = URLSession(configuration: config)
    }

    // MARK: - AVTransport

    func setAVTransportURI(_ device: SonosDevice, uri: String, metadata: String) async -> SoapResult {
        LogBus.log(.tx, "SetAVTransportURI → \(device.displayName)(\(device.ip)) CurrentURI=\(uri)")
        return await avTransport(device, "SetAVTransportURI", [
            ("InstanceID", "0"), ("CurrentURI", uri), ("CurrentURIMetaData", metadata)
        ])
    }

    func play(_ device: SonosDevice) async -> SoapResult {
        return await avTransport(device, "Play", [("InstanceID", "0"), ("Speed", "1")])
    }

    func pause(_ device: SonosDevice) async -> SoapResult {
        return await avTransport(device, "Pause", [("InstanceID", "0")])
    }

    func stop(_ device: SonosDevice) async -> SoapResult {
        return await avTransport(device, "Stop", [("InstanceID", "0")])
    }

    func seek(_ device: SonosDevice, seconds: Int) async -> SoapResult {
        return await avTransport(device, "Seek", [
            ("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", SoapXml.timeString(seconds))
        ])
    }

    // MARK: - 原生佇列

    func removeAllTracksFromQueue(_ device: SonosDevice) async -> SoapResult {
        return await avTransport(device, "RemoveAllTracksFromQueue", [("InstanceID", "0")])
    }

    /// 一次把多首塞進音箱佇列。`firstTrackNumber` 是這一批第一首應排在佇列第幾位（1 起）——
    /// 分批入隊時必須逐批遞增，否則每批都會擠到隊首，順序被打亂。
    func addMultipleURIsToQueue(
        _ device: SonosDevice,
        entries: [(url: String, metadata: String)],
        firstTrackNumber: Int = 1,
        enqueueAsNext: Bool = false
    ) async -> SoapResult {
        if entries.isEmpty { return .success("") }
        return await avTransport(device, "AddMultipleURIsToQueue", [
            ("InstanceID", "0"),
            ("UpdateID", "0"),
            ("NumberOfURIs", String(entries.count)),
            ("EnqueuedURIs", entries.map { $0.url }.joined(separator: " ")),
            ("EnqueuedURIsMetaData", entries.map { $0.metadata }.joined(separator: " ")),
            ("ContainerURI", ""),
            ("ContainerMetaData", ""),
            ("DesiredFirstTrackNumberEnqueued", String(max(1, firstTrackNumber))),
            ("EnqueueAsNext", enqueueAsNext ? "1" : "0")
        ])
    }

    /// 讓傳輸層指向「音箱自己的佇列」
    func setQueueTransport(_ device: SonosDevice) async -> SoapResult {
        let queueUri = "x-rincon-queue:\(device.uuid)#0"
        return await setAVTransportURI(device, uri: queueUri, metadata: SoapXml.queueContainerDidl(queueUri: queueUri))
    }

    /// NORMAL / REPEAT_ALL / REPEAT_ONE / SHUFFLE / SHUFFLE_NOREPEAT
    func setPlayMode(_ device: SonosDevice, mode: String) async -> SoapResult {
        return await avTransport(device, "SetPlayMode", [("InstanceID", "0"), ("NewPlayMode", mode)])
    }

    /// 跳到佇列裡第 `trackNumber` 首（1 起）
    func seekToTrack(_ device: SonosDevice, trackNumber: Int) async -> SoapResult {
        return await avTransport(device, "Seek", [
            ("InstanceID", "0"), ("Unit", "TRACK_NR"), ("Target", String(max(1, trackNumber)))
        ])
    }

    func nextTrack(_ device: SonosDevice) async -> SoapResult {
        return await avTransport(device, "Next", [("InstanceID", "0")])
    }

    func previousTrack(_ device: SonosDevice) async -> SoapResult {
        return await avTransport(device, "Previous", [("InstanceID", "0")])
    }

    func getPositionInfo(_ device: SonosDevice) async -> PositionInfo? {
        let result = await avTransport(device, "GetPositionInfo", [("InstanceID", "0")])
        guard let body = result.body else { return nil }
        return SonosSoapClient.parsePositionInfo(body)
    }

    static func parsePositionInfo(_ body: String) -> PositionInfo {
        let trackNumber = SoapXml.tagText(body, "Track").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let uri = SoapXml.unescape(SoapXml.tagText(body, "TrackURI") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PositionInfo(
            trackNumber: trackNumber,
            trackUri: uri,
            positionSec: SoapXml.parseTime(SoapXml.tagText(body, "RelTime")),
            durationSec: SoapXml.parseTime(SoapXml.tagText(body, "TrackDuration"))
        )
    }

    /// 佇列裡目前播到第幾首（1 起）。機身「下一首」不會通知我們，只能靠它變化來發現。
    func getQueueTrackNumber(_ device: SonosDevice) async -> Int? {
        return await getPositionInfo(device)?.trackNumber
    }

    /// 目前這一首的 TrackURI —— 用來做端到端校驗：確認音箱放的確實是我們想推的那一首。
    func getPlaybackTrackUri(_ device: SonosDevice) async -> String? {
        return await getPositionInfo(device)?.trackUri
    }

    /// GetMediaInfo 的 NrTracks。注意：它報的是「目前 transport」的曲目數，
    /// 所以必須在切到 x-rincon-queue 之後才讀。
    func getQueueSize(_ device: SonosDevice) async -> Int? {
        let result = await avTransport(device, "GetMediaInfo", [("InstanceID", "0")])
        guard let body = result.body else { return nil }
        return SoapXml.tagText(body, "NrTracks").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 目前 transport 的 CurrentURI（x-rincon-queue:… 代表在佇列模式）
    func getMediaUri(_ device: SonosDevice) async -> String? {
        let result = await avTransport(device, "GetMediaInfo", [("InstanceID", "0")])
        guard let body = result.body else { return nil }
        return SoapXml.unescape(SoapXml.tagText(body, "CurrentURI") ?? "")
    }

    /// PLAYING / PAUSED_PLAYBACK / STOPPED / TRANSITIONING
    func getTransportState(_ device: SonosDevice) async -> String? {
        let result = await avTransport(device, "GetTransportInfo", [("InstanceID", "0")])
        guard let body = result.body else { return nil }
        return SoapXml.tagText(body, "CurrentTransportState")
    }

    func getTransportSnapshot(_ device: SonosDevice) async -> TransportSnapshot? {
        let infoResult = await avTransport(device, "GetPositionInfo", [("InstanceID", "0")])
        guard let body = infoResult.body else { return nil }
        let info = SonosSoapClient.parsePositionInfo(body)
        let state = await getTransportState(device) ?? "STOPPED"
        // TrackMetaData 是兩層轉義的 DIDL：解一層拿到 DIDL，標題裡仍帶 &apos; 要再解一次
        let didl = SoapXml.unescape(SoapXml.tagText(body, "TrackMetaData") ?? "")
        let title = SoapXml.unescape(SoapXml.tagText(didl, "dc:title") ?? "")
        return TransportSnapshot(
            state: state,
            uri: info.trackUri,
            title: title,
            positionSec: info.positionSec,
            durationSec: info.durationSec,
            trackNumber: info.trackNumber ?? 0
        )
    }

    // MARK: - RenderingControl

    func setVolume(_ device: SonosDevice, volume: Int) async -> SoapResult {
        return await call(
            device, serviceType: SoapXml.serviceRenderingControl, controlPath: device.renderingControlUrl,
            action: "SetVolume",
            args: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(min(100, max(0, volume))))]
        )
    }

    func getVolume(_ device: SonosDevice) async -> Int? {
        let result = await call(
            device, serviceType: SoapXml.serviceRenderingControl, controlPath: device.renderingControlUrl,
            action: "GetVolume", args: [("InstanceID", "0"), ("Channel", "Master")]
        )
        guard let body = result.body else { return nil }
        return SoapXml.tagText(body, "CurrentVolume").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - ZoneGroupTopology

    /// 任一台在線音箱都能回答，回傳的是全域拓撲。
    func getZoneGroupState(_ device: SonosDevice) async -> String? {
        let result = await call(
            device, serviceType: SoapXml.serviceZoneGroupTopology,
            controlPath: SonosSoapClient.zoneGroupTopologyPath,
            action: "GetZoneGroupState", args: []
        )
        return result.body
    }

    // MARK: - 底層

    private func avTransport(_ device: SonosDevice, _ action: String, _ args: [(String, String)]) async -> SoapResult {
        return await call(
            device, serviceType: SoapXml.serviceAVTransport, controlPath: device.avTransportControlUrl,
            action: action, args: args
        )
    }

    private func call(
        _ device: SonosDevice,
        serviceType: String,
        controlPath: String,
        action: String,
        args: [(String, String)]
    ) async -> SoapResult {
        let urlString = "http://\(device.ip):\(SonosDevice.port)\(controlPath)"
        guard let url = URL(string: urlString) else {
            return .transportError("bad URL \(urlString)")
        }
        let quiet = SonosSoapClient.quietActions.contains(action)
        if !quiet { LogBus.log(.tx, "POST \(urlString) · \(action)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(SoapXml.envelope(serviceType: serviceType, action: action, args: args).utf8)

        let outcome = await HTTP.perform(session, request)
        switch outcome {
        case .failure(let message):
            LogBus.e("\(action) 網路異常：\(message)")
            return .transportError(message)
        case .response(let status, let data):
            let body = String(decoding: data, as: UTF8.self)
            let errorCode = SoapXml.tagText(body, "errorCode").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let errorDescription = (SoapXml.tagText(body, "errorDescription") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (200..<300).contains(status) && errorCode == nil {
                if !quiet { LogBus.log(.rx, "\(action) ← HTTP \(status) OK") }
                return .success(body)
            }
            let description = errorDescription.isEmpty
                ? (errorCode != nil ? UpnpErrors.describe(errorCode) : "HTTP \(status)")
                : errorDescription
            LogBus.log(.rx, "\(action) ← HTTP \(status) · UPnP \(errorCode.map(String.init) ?? "-") \(description)")
            return .fault(httpStatus: status, errorCode: errorCode, description: description, raw: body)
        }
    }
}

/// URLSession 的薄封裝：用 completion handler 版本，iOS 與 Linux（測試）都能編。
enum HTTP {
    enum Outcome {
        case response(status: Int, data: Data)
        case failure(String)
    }

    static func perform(_ session: URLSession, _ request: URLRequest) async -> Outcome {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(returning: .failure(error.localizedDescription))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.resume(returning: .response(status: status, data: data ?? Data()))
            }
            task.resume()
        }
    }
}
