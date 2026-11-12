import Foundation
#if canImport(Combine)
import Combine
#endif

enum DeviceStatus: String {
    case idle, pushing, playing, paused, error
    /// 配對從設備：隨主箱同步
    case following
}

enum RepeatMode: String {
    case all, one
    var next: RepeatMode { self == .all ? .one : .all }
}

enum HintKind: Equatable {
    case pickSong, noDevice, noWifi, serverFailed
    case reach, format, badRequest, offline, satellite, unknown
    case unsupportedFormat, mixedGeneration, connectionLost, localNetworkDenied
}

struct Hint: Equatable {
    var kind: HintKind
    var detail: String = ""
}

/// 播放引擎 —— 對應 Android 版的 SonosCastService + AppState。
///
/// 核心想法與原版相同：把整份播放清單塞進「音箱自己的佇列」
/// （AddMultipleURIsToQueue → x-rincon-queue），切歌由音箱執行，手機只負責觀察；
/// 佇列路徑任何一步自檢不過，就退回逐首推 URL（SetAVTransportURI + Play）。
@MainActor
final class CastEngine: ObservableObject {

    // MARK: 對 UI 公開的狀態

    @Published var devices: [SonosDevice] = []
    @Published var selectedKeys: Set<String> = []
    @Published var deviceStatus: [String: DeviceStatus] = [:]
    @Published var deviceError: [String: String] = [:]
    @Published var scanning = false
    @Published var busy = false
    @Published var queue: [Track] = []
    @Published var queueIndex = -1
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .all
    @Published var positionSec = 0
    @Published var durationSec = 0
    @Published var volume = 30
    @Published var hint: Hint? = nil
    /// 音箱正在播別的來源（Sonos App、AirPlay…），ZONOZ 不搶
    @Published var externalSource = false
    @Published var connectionLost = false
    @Published var localIP: String? = nil
    @Published var serverPort = 0
    @Published var streamUrl: String? = nil
    /// 目前是否走音箱原生佇列（false = 逐首推送）
    @Published var nativeQueueActive = false

    /// 完整曲庫（由 MusicLibrary 寫入），用於重建清單與恢復狀態
    var library: [Track] = []

    // MARK: 內部狀態

    let soap = SonosSoapClient()
    private let prober = DeviceProber(timeout: 2.5)
    private let platform: EnginePlatform
    private let defaults: UserDefaults

    private var queueSource: [Track] = []
    private var sonosQueueSignature = ""
    private var lastQueueTrack = 0
    private var lastTransportState: String? = nil
    private var castAt = 0.0
    private var castDurationMs = 0
    private var castSettledAt = 0.0
    private var earlyStopRetries = 0
    private var lastAdvanceAt = -1000.0
    private var lastVolumeSetAt = -1000.0
    private var lastUrlHealAt = -1000.0
    private var lastAuditRebuildAt = -1000.0
    private var soapFailStreak = 0
    private var pausedAtSec = 0
    private var pendingCast: (resumeAtSec: Int, autoPlay: Bool)? = nil
    private var pendingSeekSec: Int? = nil
    private var pollTask: Task<Void, Never>? = nil
    private var pollKick = false
    private var sessionActive = false
    private var started = false

    private static let queueChunkSize = 12
    private static let queueSettle = 1.5
    private static let earlyStopTolerance = 20.0
    private static let maxEarlyStopRetries = 2
    private static let autoAdvanceDebounce = 10.0
    private static let volumeSyncGuard = 3.0
    private static let auditRebuildCooldown = 60.0

    private enum Keys {
        static let selected = "zonoz.selectedKeys"
        static let knownIPs = "zonoz.knownIPs"
        static let shuffle = "zonoz.shuffle"
        static let repeatMode = "zonoz.repeat"
    }

    init(platform: EnginePlatform, defaults: UserDefaults = .standard) {
        self.platform = platform
        self.defaults = defaults
        shuffle = defaults.bool(forKey: Keys.shuffle)
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .all
        if shuffle { repeatMode = .all }
        selectedKeys = Set(defaults.stringArray(forKey: Keys.selected) ?? [])
    }

    // MARK: - 便利存取

    var currentTrack: Track? {
        guard queueIndex >= 0, queueIndex < queue.count else { return nil }
        return queue[queueIndex]
    }

    var isPlaying: Bool {
        return !connectionLost && !externalSource && deviceStatus.values.contains(.playing)
    }

    var hasSession: Bool {
        return deviceStatus.values.contains { $0 == .playing || $0 == .paused || $0 == .pushing }
    }

    func selectedDevices() -> [SonosDevice] {
        return devices.filter { selectedKeys.contains($0.key) }
    }

    func coordinators() -> [SonosDevice] {
        return devices.filter { !$0.isSatellite }
    }

    private func activeDevices() -> [SonosDevice] {
        return devices.filter { device in
            switch deviceStatus[device.key] {
            case .playing, .paused, .pushing: return true
            default: return false
            }
        }
    }

    private func controlTargets() -> [SonosDevice] {
        let active = activeDevices()
        let base = active.isEmpty ? selectedDevices() : active
        return base.filter { !$0.isSatellite }
    }

    private func setStatus(_ key: String, _ status: DeviceStatus, error: String? = nil) {
        deviceStatus[key] = status
        if let error = error {
            deviceError[key] = error
        } else {
            deviceError.removeValue(forKey: key)
        }
        updateSessionFlag()
    }

    private func updateSessionFlag() {
        let active = hasSession
        if active != sessionActive {
            sessionActive = active
            platform.playbackSessionChanged(active: active)
        }
    }

    private func notifyNowPlaying() {
        platform.nowPlayingChanged()
    }

    // MARK: - 啟動 / 探索

    /// App 啟動時呼叫一次：起 HTTP 伺服器、找音箱、恢復狀態、開始輪詢。
    func start() {
        if started { return }
        started = true
        Task {
            _ = await prepareServer(force: false)
            await scanInternal()
            if !devices.isEmpty { await restorePlaybackState() }
            startPolling()
        }
    }

    /// 回到前景：伺服器可能在背景被系統收掉，檢查一次並立刻同步狀態。
    func appBecameActive() {
        guard started else { return }
        Task {
            _ = await prepareServer(force: false)
            // 第一次啟動時，「區域網路」權限視窗關掉後 App 會重新變成 active：
            // 剛才那次掃描多半因為還沒授權而落空，這裡自動補掃一次。
            if devices.isEmpty && !scanning {
                await scanInternal()
                if !devices.isEmpty { await restorePlaybackState() }
            }
            kickPoll()
        }
    }

    func scan() {
        Task { await scanInternal() }
    }

    @discardableResult
    private func prepareServer(force: Bool) async -> Bool {
        let ip = platform.currentLanIP()
        if ip != localIP { localIP = ip }
        guard ip != nil else {
            hint = Hint(kind: .noWifi)
            LogBus.w("找不到 Wi-Fi 的 IPv4 位址，無法提供串流")
            return false
        }
        guard let port = await platform.ensureServer(force: force) else {
            hint = Hint(kind: .serverFailed)
            LogBus.e("本地 HTTP 伺服器啟動失敗")
            return false
        }
        if port != serverPort { serverPort = port }
        return true
    }

    private func scanInternal() async {
        if scanning { return }
        scanning = true
        defer { scanning = false }

        let ip = platform.currentLanIP()
        if ip != localIP { localIP = ip }
        LogBus.i("開始尋找音箱（Bonjour + 同網段掃描）…")

        var found = await platform.discover(localIP: ip)

        // 上次見過的 IP 也直接敲一次（Bonjour 沒回應、網段又不是 /24 時的保險）
        let foundIPs = Set(found.map { $0.ip })
        for known in defaults.stringArray(forKey: Keys.knownIPs) ?? [] where !foundIPs.contains(known) {
            if let device = await prober.probe(ip: known, source: .manual) {
                found.append(device)
            }
        }

        if found.isEmpty {
            if devices.isEmpty { hint = Hint(kind: .noDevice) }
            LogBus.w("未發現音箱（可在設定頁手動輸入 IP）")
            return
        }
        upsertDevices(found)
        if hint?.kind == .noDevice { hint = nil }
        LogBus.i("發現 \(found.count) 台：" + found.map { "\($0.displayName)(\($0.ip))" }.joined(separator: "、"))
        await refreshTopology(found)
        applyDefaultSelection()
    }

    func addManualDevice(ip rawIP: String) {
        let ip = rawIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeviceProber.isValidIPv4(ip) else {
            hint = Hint(kind: .offline, detail: ip)
            return
        }
        Task {
            LogBus.i("手動探測音箱：\(ip)")
            guard let device = await prober.probe(ip: ip, source: .manual) else {
                hint = Hint(kind: .offline, detail: ip)
                LogBus.e("手動新增失敗：\(ip)")
                return
            }
            upsertDevices([device])
            await refreshTopology([device])
            if let live = devices.first(where: { $0.key == device.key }), !live.isSatellite {
                selectedKeys.insert(live.key)
                persistSelection()
            }
            hint = nil
            LogBus.i("已新增：\(device.displayName) · \(device.modelName) · \(device.ip)")
        }
    }

    func removeDevice(_ key: String) {
        devices.removeAll { $0.key == key }
        selectedKeys.remove(key)
        deviceStatus.removeValue(forKey: key)
        deviceError.removeValue(forKey: key)
        persistSelection()
        persistKnownIPs()
        updateSessionFlag()
    }

    func toggleSelection(_ key: String) {
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
        persistSelection()
        kickPoll()
    }

    private func upsertDevices(_ found: [SonosDevice]) {
        var list = devices
        for device in found {
            if let i = list.firstIndex(where: { $0.key == device.key }) {
                // 保留已知的拓撲資訊
                var merged = device
                merged.isSatellite = list[i].isSatellite
                merged.channelRole = list[i].channelRole
                if merged.swGen == 0 { merged.swGen = list[i].swGen }
                list[i] = merged
            } else {
                list.append(device)
            }
        }
        list.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        devices = list
        persistKnownIPs()
    }

    private func applyDefaultSelection() {
        let liveKeys = Set(devices.map { $0.key })
        let valid = selectedKeys.intersection(liveKeys)
        if !valid.isEmpty {
            return
        }
        // 沒有可用的既有選擇：預設選第一台主箱
        if let first = coordinators().first {
            selectedKeys = [first.key]
            persistSelection()
        }
    }

    private func persistSelection() {
        defaults.set(Array(selectedKeys), forKey: Keys.selected)
    }

    private func persistKnownIPs() {
        defaults.set(devices.map { $0.ip }, forKey: Keys.knownIPs)
    }

    private func refreshTopology(_ targets: [SonosDevice]) async {
        guard let probe = targets.first else { return }
        guard let body = await soap.getZoneGroupState(probe) else {
            LogBus.d("GetZoneGroupState 無回應，略過拓撲識別")
            return
        }
        let nodes = ZoneTopology.parse(soapBody: body)
        if nodes.isEmpty {
            LogBus.d("拓撲解析為空，略過（推送時用 1023 兜底）")
            return
        }
        var byUUID: [String: ZoneTopology.Node] = [:]
        for node in nodes { byUUID[node.uuid] = node }
        devices = devices.map { device in
            guard let node = byUUID[device.uuid] else { return device }
            var updated = device
            updated.isSatellite = node.isSatellite
            updated.channelRole = node.channel
            if node.swGen > 0 { updated.swGen = node.swGen }
            if !node.softwareVersion.isEmpty { updated.softwareVersion = node.softwareVersion }
            return updated
        }
        let summary = nodes.map { node -> String in
            let role = node.isSatellite ? "從\(node.channel)" : "主\(node.channel)"
            return "\(node.uuid.suffix(8)):\(role)"
        }.joined(separator: "、")
        LogBus.i("區域組拓撲：\(summary)")
    }

    // MARK: - 播放清單（對應 AppState）

    /// 使用者在某個清單點了一首歌：以該清單為來源建立播放清單並開始播放。
    func play(_ track: Track, in source: [Track]) {
        startQueue(source: source.isEmpty ? [track] : source, current: track)
        castCurrent()
    }

    private func startQueue(source: [Track], current: Track) {
        queueSource = source
        let ordered = orderFor(source: source, current: current)
        queue = ordered
        queueIndex = ordered.firstIndex(where: { $0.id == current.id }) ?? 0
    }

    private func orderFor(source: [Track], current: Track?) -> [Track] {
        guard let current = current else { return source }
        if shuffle {
            var rest = source.filter { $0.id != current.id }
            rest.shuffle()
            return [current] + rest
        }
        return source
    }

    private func reorderQueue() {
        guard let current = currentTrack else { return }
        let source = queueSource.isEmpty ? queue : queueSource
        let ordered = orderFor(source: source, current: current)
        queue = ordered
        queueIndex = max(0, ordered.firstIndex(where: { $0.id == current.id }) ?? 0)
    }

    private func step(_ offset: Int) -> Track? {
        if queue.isEmpty { return nil }
        let size = queue.count
        let target = ((queueIndex + offset) % size + size) % size
        queueIndex = target
        return queue[target]
    }

    /// 清單沒建立時用曲庫兜底，避免「上一首/下一首」點了沒反應
    private func ensureQueueReady() {
        if !queue.isEmpty || library.isEmpty { return }
        startQueue(source: library, current: library[0])
        LogBus.d("播放清單缺失，已按曲庫重建（\(library.count) 首）")
    }

    /// 在播放清單裡點某一首
    func playQueueItem(at index: Int) {
        guard index >= 0, index < queue.count else { return }
        queueIndex = index
        castCurrent()
    }

    /// 「下一首播放」：把曲目插到目前這首後面。
    func insertNext(_ track: Track) {
        if queue.isEmpty {
            play(track, in: [track])
            return
        }
        var list = queue
        var currentIdx = min(max(queueIndex, 0), list.count - 1)
        if list[currentIdx].id == track.id { return }
        let existing = list.firstIndex(where: { $0.id == track.id })
        if let existing = existing, existing == currentIdx + 1 { return }
        if let existing = existing {
            list.remove(at: existing)
            // 被移走的在目前曲之前 → 目前曲前移一位，下標必須跟著修正，否則之後按序號定位會跳歌
            if existing < currentIdx { currentIdx -= 1 }
        }
        let insertAt = min(currentIdx + 1, list.count)
        list.insert(track, at: insertAt)
        queue = list
        queueIndex = currentIdx
        if !queueSource.contains(where: { $0.id == track.id }) { queueSource.append(track) }
        syncSpeakerQueue(inserted: track, rebuild: existing != nil)
    }

    func removeFromQueue(at index: Int) {
        guard index >= 0, index < queue.count, index != queueIndex else { return }
        let removed = queue[index]
        var list = queue
        list.remove(at: index)
        queue = list
        if index < queueIndex { queueIndex -= 1 }
        queueSource.removeAll { $0.id == removed.id }
        recastIfQueueActive(reason: "移除曲目")
    }

    /// 曲庫重新掃描後：把清單裡已不存在的曲目拿掉。
    func libraryChanged(_ tracks: [Track]) {
        library = tracks
        if queue.isEmpty { return }
        let alive = Set(tracks.map { $0.id })
        let currentId = currentTrack?.id
        let filtered = queue.filter { alive.contains($0.id) }
        if filtered.count == queue.count { return }
        queue = filtered
        queueSource = queueSource.filter { alive.contains($0.id) }
        if let currentId = currentId, let i = filtered.firstIndex(where: { $0.id == currentId }) {
            queueIndex = i
        } else {
            queueIndex = filtered.isEmpty ? -1 : 0
        }
        sonosQueueSignature = ""
    }

    private func shouldUseQueue() -> Bool {
        return queue.count >= 2
    }

    private func queueSignature() -> String {
        // URL 取決於 IP 與埠：任何一個變了，音箱裡的佇列就全部失效
        return "\(localIP ?? "-"):\(serverPort)|" + queue.map { $0.id }.joined(separator: ",")
    }

    // MARK: - 推送入口

    /// 推送「清單中的目前曲目」。上一次推送還沒結束時記下來，結束後補跑（以最後一次為準）。
    func castCurrent(resumeAtSec: Int = 0, autoPlay: Bool = true) {
        guard currentTrack != nil else {
            hint = Hint(kind: .pickSong)
            return
        }
        guard !selectedDevices().isEmpty else {
            hint = Hint(kind: .noDevice)
            return
        }
        if busy {
            pendingCast = (resumeAtSec, autoPlay)
            LogBus.d("上一次推送尚未結束，排到它之後")
            return
        }
        busy = true
        Task {
            await runCast(resumeAtSec: resumeAtSec, autoPlay: autoPlay)
            busy = false
            notifyNowPlaying()
            kickPoll()
            if let pending = pendingCast {
                pendingCast = nil
                pendingSeekSec = nil
                castCurrent(resumeAtSec: pending.resumeAtSec, autoPlay: pending.autoPlay)
            } else if let seconds = pendingSeekSec {
                pendingSeekSec = nil
                seek(to: seconds)
            }
        }
    }

    private func runCast(resumeAtSec: Int, autoPlay: Bool) async {
        hint = nil
        guard await prepareServer(force: false) else { return }
        await refreshTopology(selectedDevices())
        let targets = selectedDevices()
        let index = queueIndex
        guard let track = currentTrack else { return }
        positionSec = resumeAtSec
        durationSec = track.durationMs / 1000
        notifyNowPlaying()

        if await castNativeQueue(targets: targets, index: index, attempt: 0, resumeAtSec: resumeAtSec, autoPlay: autoPlay) {
            return
        }
        nativeQueueActive = false
        let ok = await performCast(track: track, targets: targets)
        guard ok else { return }
        let masters = targets.filter { !$0.isSatellite }
        if resumeAtSec > 0 {
            for device in masters { _ = await soap.seek(device, seconds: resumeAtSec) }
            positionSec = resumeAtSec
            LogBus.i("逐首推送後恢復到 \(resumeAtSec)s")
        }
        if !autoPlay {
            for device in masters {
                _ = await soap.pause(device)
                setStatus(device.key, .paused)
            }
            lastTransportState = "PAUSED_PLAYBACK"
        }
    }

    /// 超出音箱規格的檔案（>48 kHz、WAV/AIFF >16 bit）直接擋下並提示，
    /// 否則音箱會「拉一段資料後自己跳過」，看起來像 App 壞了。
    private func blockIfUnsupported(_ track: Track) -> Bool {
        guard let format = platform.probeFormat(of: track), AudioProbe.isUnsupported(format) else { return false }
        let description = AudioProbe.describe(format)
        LogBus.w("略過不支援的格式：\(track.title) · \(description)（音箱上限 48 kHz，WAV/AIFF 16 bit）")
        hint = Hint(kind: .unsupportedFormat, detail: description)
        return true
    }

    // MARK: - 原生佇列

    /// 回傳 true 表示「已處理」（成功，或已明確提示使用者）；false 表示呼叫方應退回逐首推送。
    private func castNativeQueue(
        targets: [SonosDevice],
        index: Int,
        attempt: Int,
        resumeAtSec: Int,
        autoPlay: Bool
    ) async -> Bool {
        let list = queue
        if index >= 0 && index < list.count && blockIfUnsupported(list[index]) { return true }
        if list.count < 2 {
            LogBus.d("播放清單只有 \(list.count) 首，不建佇列，走逐首推送")
            return false
        }
        guard let ip = localIP, serverPort > 0 else {
            LogBus.w("本機 IP 或 HTTP 伺服器未就緒，無法建佇列")
            return false
        }
        let port = serverPort
        let speakers = targets.filter { !$0.isSatellite && !$0.isLegacyS1 }
        if speakers.isEmpty {
            LogBus.w("選中的設備裡沒有可用主箱（從箱 / S1 被排除），走逐首推送")
            return false
        }

        let signature = queueSignature()
        let needRebuild = !nativeQueueActive || signature != sonosQueueSignature
        let safeIndex = min(max(index, 0), list.count - 1)
        let targetTrack = list[safeIndex]
        let targetFileId = targetTrack.id
        LogBus.d("推佇列：第 \(safeIndex + 1)/\(list.count) 首「\(targetTrack.title)」（\(targetFileId)）")

        for speaker in speakers {
            setStatus(speaker.key, .pushing)

            if needRebuild {
                _ = await soap.removeAllTracksFromQueue(speaker)
                let entries: [(url: String, metadata: String)] = list.map { track in
                    let url = MediaRegistry.streamUrl(ip: ip, port: port, track: track)
                    return (url, SoapXml.didlLite(title: track.title, url: url, mimeType: track.mimeType, id: track.id))
                }
                if !(await enqueueAll(speaker, entries)) {
                    setStatus(speaker.key, .idle)
                    return false
                }
                // 必須先切傳輸再讀 NrTracks：它報的是「目前 transport」的曲目數
                let transport = await soap.setQueueTransport(speaker)
                if !transport.isSuccess {
                    LogBus.w("切換佇列傳輸失敗：\(transport.failureText)，退回逐首推送")
                    setStatus(speaker.key, .idle)
                    return false
                }
                if let size = await soap.getQueueSize(speaker), size != list.count {
                    LogBus.w("音箱佇列長度不符（音箱 \(size) / 清單 \(list.count)），為避免播錯歌，退回逐首推送")
                    setStatus(speaker.key, .idle)
                    return false
                }
            }

            _ = await soap.setPlayMode(speaker, mode: nativePlayMode())
            _ = await soap.seekToTrack(speaker, trackNumber: safeIndex + 1)

            // 定位自檢要輪詢：音箱切傳輸有幾百毫秒延遲，讀一次很容易讀到舊值
            var positioned = await pollTrackNumber(speaker, expect: safeIndex + 1, rounds: 4, delayMs: 300)
            if let p = positioned, p != safeIndex + 1 {
                LogBus.w("佇列定位不符（期望第 \(safeIndex + 1) 首，實際第 \(p) 首），重新定位")
                _ = await soap.seekToTrack(speaker, trackNumber: safeIndex + 1)
                positioned = await pollTrackNumber(speaker, expect: safeIndex + 1, rounds: 3, delayMs: 300)
                if let retry = positioned, retry != safeIndex + 1 {
                    LogBus.w("佇列定位仍不符（第 \(retry) 首），退回逐首推送")
                    setStatus(speaker.key, .idle)
                    return false
                }
            }

            if resumeAtSec > 0 {
                _ = await soap.seek(speaker, seconds: resumeAtSec)
                LogBus.d("重建後恢復到 \(resumeAtSec)s")
            }

            if autoPlay {
                let play = await soap.play(speaker)
                if !play.isSuccess {
                    LogBus.w("佇列播放失敗：\(play.failureText)，退回逐首推送")
                    setStatus(speaker.key, .idle)
                    return false
                }
            } else {
                LogBus.d("保持暫停：只重建佇列並定位，不送 Play")
            }

            // 端到端校驗：讀回 TrackURI，確認音箱放的確實是我們要的那一首
            var actualUri: String? = nil
            var matched = false
            for round in 0..<4 {
                actualUri = await soap.getPlaybackTrackUri(speaker)
                if let uri = actualUri, uri.contains(targetFileId) {
                    matched = true
                    break
                }
                if round < 3 { await sleepMs(400) }
            }
            if !matched, let uri = actualUri, !uri.isEmpty {
                let playing = uri.split(separator: "/").last.map(String.init) ?? uri
                LogBus.w("聲畫不一致：期望 \(targetFileId)，音箱在放 \(playing)（第 \(attempt + 1) 次）")
                if attempt == 0 {
                    nativeQueueActive = false
                    sonosQueueSignature = ""
                    return await castNativeQueue(
                        targets: targets, index: safeIndex, attempt: 1,
                        resumeAtSec: resumeAtSec, autoPlay: autoPlay
                    )
                }
                setStatus(speaker.key, .idle)
                return false
            }
            if matched { LogBus.d("聲畫一致：\(targetFileId) ✓") }
            setStatus(speaker.key, autoPlay ? .playing : .paused)
        }

        sonosQueueSignature = signature
        nativeQueueActive = true
        externalSource = false
        lastQueueTrack = safeIndex + 1
        let now = platform.uptime()
        castSettledAt = now
        castAt = now
        castDurationMs = targetTrack.durationMs
        lastTransportState = autoPlay ? "PLAYING" : "PAUSED_PLAYBACK"
        earlyStopRetries = 0
        hint = nil
        streamUrl = MediaRegistry.streamUrl(ip: ip, port: port, track: targetTrack)
        mirrorSatelliteStatus(autoPlay ? .playing : .paused)
        LogBus.i("已把 \(list.count) 首灌進音箱佇列（\(needRebuild ? "重建" : "沿用")），從第 \(safeIndex + 1) 首開始")
        return true
    }

    private func pollTrackNumber(_ speaker: SonosDevice, expect: Int, rounds: Int, delayMs: Int) async -> Int? {
        var value: Int? = nil
        for round in 0..<rounds {
            value = await soap.getQueueTrackNumber(speaker)
            if value == nil || value == expect { break }
            if round < rounds - 1 { await sleepMs(delayMs) }
        }
        return value
    }

    /// 每批 12 首（實測一次超過 16 首會 402 / 500），插入位置逐批遞增。
    private func enqueueAll(_ speaker: SonosDevice, _ entries: [(url: String, metadata: String)]) async -> Bool {
        var index = 0
        while index < entries.count {
            let end = min(index + CastEngine.queueChunkSize, entries.count)
            if !(await enqueueChunk(speaker, Array(entries[index..<end]), firstTrackNumber: index + 1)) {
                return false
            }
            index = end
        }
        return true
    }

    /// 某一批失敗就對半拆分重試，拆到單首仍失敗才放棄整條佇列路徑。
    private func enqueueChunk(
        _ speaker: SonosDevice,
        _ entries: [(url: String, metadata: String)],
        firstTrackNumber: Int
    ) async -> Bool {
        if entries.isEmpty { return true }
        let result = await soap.addMultipleURIsToQueue(speaker, entries: entries, firstTrackNumber: firstTrackNumber)
        if result.isSuccess { return true }
        if entries.count == 1 {
            LogBus.w("單首入隊失敗：\(result.failureText)")
            return false
        }
        LogBus.w("一次入隊 \(entries.count) 首失敗（\(result.failureText)），對半拆分重試")
        let mid = entries.count / 2
        let firstHalf = await enqueueChunk(speaker, Array(entries[0..<mid]), firstTrackNumber: firstTrackNumber)
        if !firstHalf { return false }
        return await enqueueChunk(speaker, Array(entries[mid...]), firstTrackNumber: firstTrackNumber + mid)
    }

    /// 隨機是在 App 端把清單洗牌後整份入隊，所以音箱端一律 REPEAT_ALL / REPEAT_ONE。
    private func nativePlayMode() -> String {
        if shuffle { return "REPEAT_ALL" }
        return repeatMode == .one ? "REPEAT_ONE" : "REPEAT_ALL"
    }

    // MARK: - 逐首推送（兜底路徑）

    private struct PushResult {
        var ok: Bool
        var skipped: Bool
        var errorCode: Int?
        var message: String?
    }

    private func performCast(track: Track, targets: [SonosDevice]) async -> Bool {
        if blockIfUnsupported(track) { return false }
        guard let ip = localIP, serverPort > 0 else { return false }
        var url = MediaRegistry.streamUrl(ip: ip, port: serverPort, track: track)
        streamUrl = url
        LogBus.i("────────────────────────")
        LogBus.i("推送「\(track.title)」→ " + targets.map { $0.displayName }.joined(separator: "、"))
        if !MimeTypes.isSonosSupported(track.mimeType) {
            LogBus.w("\(track.mimeType) 不在原版列出的支援格式內，可能回 714")
        }
        if targets.contains(where: { $0.isLegacyS1 }) && targets.contains(where: { $0.swGen >= 2 }) {
            hint = Hint(kind: .mixedGeneration)
        }

        var results: [PushResult] = []
        for device in targets { results.append(await pushOne(device, url: url, track: track)) }

        // 701：音箱拿不到串流 —— 換埠重建 HTTP 伺服器後對所有音箱重試一次
        if results.contains(where: { $0.errorCode == 701 }) {
            LogBus.w("偵測到 701 —— 重建 HTTP 伺服器（換埠）後重試一次")
            if let newPort = await platform.restartServerOnNewPort(), let newIP = platform.currentLanIP() {
                serverPort = newPort
                localIP = newIP
                url = MediaRegistry.streamUrl(ip: newIP, port: newPort, track: track)
                streamUrl = url
                results = []
                for device in targets { results.append(await pushOne(device, url: url, track: track)) }
            } else {
                LogBus.e("重建 HTTP 伺服器失敗，放棄重試")
            }
        }

        let played = results.filter { $0.ok }.count
        let following = results.filter { $0.skipped }.count
        let failures = results.filter { !$0.ok && !$0.skipped }
        if failures.isEmpty && played > 0 {
            hint = nil
            externalSource = false
            LogBus.i("完成：\(played) 台主箱播放" + (following > 0 ? "，\(following) 台從箱隨主箱同步" : ""))
            lastTransportState = "PLAYING"
            let now = platform.uptime()
            castAt = now
            castSettledAt = now
            earlyStopRetries = 0
            castDurationMs = track.durationMs
            return true
        }
        let first = failures.first
        let kind: HintKind
        switch UpnpErrors.kind(first?.errorCode) {
        case .reach: kind = .reach
        case .format: kind = .format
        case .badRequest: kind = .badRequest
        case .offline: kind = .offline
        case .satellite: kind = .satellite
        case .unknown: kind = .unknown
        }
        hint = Hint(kind: failures.isEmpty ? .satellite : kind, detail: "\(url) · \(track.mimeType)")
        LogBus.e("完成：\(played) 成功 / \(following) 從箱 / \(failures.count) 失敗；首個失敗 \(first?.errorCode.map(String.init) ?? "-") \(first?.message ?? "")")
        return false
    }

    private func pushOne(_ device: SonosDevice, url: String, track: Track) async -> PushResult {
        if device.isSatellite {
            setStatus(device.key, .following)
            LogBus.i("\(device.displayName)(\(device.ip)) 是配對從設備，隨主箱同步，略過獨立推送")
            return PushResult(ok: false, skipped: true, errorCode: nil, message: "satellite")
        }
        setStatus(device.key, .pushing)
        let metadata = SoapXml.didlLite(title: track.title, url: url, mimeType: track.mimeType)

        let setResult = await soap.setAVTransportURI(device, uri: url, metadata: metadata)
        switch setResult {
        case .success:
            break
        case .fault(_, let code, let description, _):
            if code == UpnpErrors.satelliteCode {
                setStatus(device.key, .following)
                LogBus.i("\(device.displayName) 回 1023 → 判定為配對從設備，隨主箱同步")
                return PushResult(ok: false, skipped: true, errorCode: nil, message: "satellite")
            }
            setStatus(device.key, .error, error: UpnpErrors.describe(code))
            LogBus.e("\(device.displayName) SetAVTransportURI 失敗：\(code.map(String.init) ?? "-") \(description)")
            return PushResult(ok: false, skipped: false, errorCode: code, message: description)
        case .transportError(let message):
            setStatus(device.key, .error, error: message)
            return PushResult(ok: false, skipped: false, errorCode: nil, message: message)
        }

        let playResult = await soap.play(device)
        switch playResult {
        case .success:
            setStatus(device.key, .playing)
            LogBus.i("\(device.displayName) 已開始播放")
            return PushResult(ok: true, skipped: false, errorCode: nil, message: nil)
        case .fault(_, let code, let description, _):
            setStatus(device.key, .error, error: UpnpErrors.describe(code))
            LogBus.e("\(device.displayName) Play 失敗：\(code.map(String.init) ?? "-") \(description)")
            return PushResult(ok: false, skipped: false, errorCode: code, message: description)
        case .transportError(let message):
            setStatus(device.key, .error, error: message)
            return PushResult(ok: false, skipped: false, errorCode: nil, message: message)
        }
    }

    // MARK: - 傳輸控制

    func next() { playRelative(1) }
    func previous() { playRelative(-1) }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if hasSession || externalSource {
            resume()
        } else {
            ensureQueueReady()
            castCurrent()
        }
    }

    private func playRelative(_ offset: Int) {
        lastAdvanceAt = platform.uptime()

        // 音箱已有我們的佇列：直接叫音箱切歌，由它自己完成
        if nativeQueueActive && !externalSource {
            let targets = controlTargets()
            if !targets.isEmpty {
                _ = step(offset)
                positionSec = 0
                durationSec = (currentTrack?.durationMs ?? 0) / 1000
                castSettledAt = platform.uptime()
                notifyNowPlaying()
                Task {
                    for device in targets {
                        let result = offset > 0 ? await soap.nextTrack(device) : await soap.previousTrack(device)
                        if !result.isSuccess { LogBus.w("音箱切歌失敗：\(result.failureText)") }
                    }
                    kickPoll()
                }
                return
            }
        }

        ensureQueueReady()
        let repeatOne = repeatMode == .one && !shuffle
        if repeatOne {
            if currentTrack != nil {
                LogBus.i("單曲循環：停在目前這首")
                castCurrent()
            } else {
                stop()
            }
            return
        }
        guard let nextTrack = step(offset) else {
            LogBus.i("播放清單為空，停止")
            stop()
            return
        }
        LogBus.i("\(offset > 0 ? "下一首" : "上一首") →「\(nextTrack.title)」")
        castCurrent()
    }

    func pause() {
        if externalSource { return }   // 音箱在放別人的內容，不代為暫停
        Task {
            let targets = controlTargets()
            if targets.isEmpty { return }
            for device in targets {
                let result = await soap.pause(device)
                switch result {
                case .success:
                    setStatus(device.key, .paused)
                    LogBus.i("\(device.displayName) 已暫停")
                case .fault(_, let code, _, _):
                    setStatus(device.key, .error, error: UpnpErrors.describe(code))
                case .transportError(let message):
                    setStatus(device.key, .error, error: message)
                }
            }
            mirrorSatelliteStatus(.paused)
            lastTransportState = "PAUSED_PLAYBACK"
            pausedAtSec = positionSec
            notifyNowPlaying()
        }
    }

    func resume() {
        if externalSource {
            LogBus.i("音箱在放其他來源，按播放 → 交還給 ZONOZ（從暫停處繼續）")
            externalSource = false
            ensureQueueReady()
            castCurrent(resumeAtSec: pausedAtSec > 0 ? pausedAtSec : positionSec)
            return
        }
        Task {
            _ = await prepareServer(force: false)
            let targets = controlTargets()
            if targets.isEmpty { return }
            for device in targets {
                let result = await soap.play(device)
                switch result {
                case .success:
                    setStatus(device.key, .playing)
                    LogBus.i("\(device.displayName) 已繼續")
                case .fault(_, let code, _, _):
                    setStatus(device.key, .error, error: UpnpErrors.describe(code))
                case .transportError(let message):
                    setStatus(device.key, .error, error: message)
                }
            }
            mirrorSatelliteStatus(.playing)
            lastTransportState = "PLAYING"
            notifyNowPlaying()
            kickPoll()
        }
    }

    func stop() {
        Task {
            let targets = controlTargets()
            let foreign = externalSource
            for device in targets {
                // 音箱已被其他來源接手時只放掉本地狀態，不去停別人的播放
                if !foreign { _ = await soap.stop(device) }
                setStatus(device.key, .idle)
            }
            externalSource = false
            nativeQueueActive = false
            mirrorSatelliteStatus(.idle)
            positionSec = 0
            lastTransportState = nil
            LogBus.i("已向 \(targets.count) 台音箱送出 Stop")
            notifyNowPlaying()
        }
    }

    func setVolume(_ value: Int) {
        let clamped = min(100, max(0, value))
        volume = clamped
        lastVolumeSetAt = platform.uptime()
        Task {
            for device in controlTargets() {
                let result = await soap.setVolume(device, volume: clamped)
                if !result.isSuccess { LogBus.e("音量設定失敗 \(device.displayName)：\(result.failureText)") }
            }
        }
    }

    func seek(to seconds: Int) {
        let target = max(0, seconds)
        positionSec = target
        castSettledAt = platform.uptime()
        if busy {
            // 佇列正在重建：現在送出的 Seek 會被重建流程自己的定位蓋掉，等它結束再補
            pendingSeekSec = target
            return
        }
        Task {
            let targets = controlTargets()
            if targets.isEmpty {
                LogBus.w("沒有正在播放的設備，Seek 無效")
                return
            }
            for device in targets {
                let result = await soap.seek(device, seconds: target)
                if !result.isSuccess { LogBus.e("Seek 失敗 \(device.displayName)：\(result.failureText)") }
            }
            notifyNowPlaying()
        }
    }

    func toggleShuffle() {
        shuffle.toggle()
        if shuffle { repeatMode = .all }
        defaults.set(shuffle, forKey: Keys.shuffle)
        defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode)
        reorderQueue()
        LogBus.i("播放模式 → \(shuffle ? "隨機" : "循序")")
        recastIfQueueActive(reason: "隨機開關")
    }

    func cycleRepeat() {
        let wasShuffle = shuffle
        repeatMode = repeatMode.next
        shuffle = false
        defaults.set(shuffle, forKey: Keys.shuffle)
        defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode)
        LogBus.i("播放模式 → \(repeatMode == .one ? "單曲循環" : "列表循環")")
        if wasShuffle {
            reorderQueue()
            recastIfQueueActive(reason: "循環切換")
        } else {
            applyPlayModeOnly(reason: "循環切換")
        }
    }

    /// 只切播放模式，不重建佇列（重建會讓目前這首從頭播）。
    private func applyPlayModeOnly(reason: String) {
        guard shouldUseQueue(), nativeQueueActive, !externalSource else { return }
        let speakers = controlTargets()
        if speakers.isEmpty { return }
        Task {
            let mode = nativePlayMode()
            var allOK = true
            for speaker in speakers {
                let result = await soap.setPlayMode(speaker, mode: mode)
                if !result.isSuccess { allOK = false }
            }
            if allOK {
                LogBus.i("\(reason) → 只切播放模式：\(mode)（不重建佇列）")
            } else {
                LogBus.w("\(reason)：SetPlayMode 失敗，退回重建佇列")
                recastIfQueueActive(reason: reason)
            }
        }
    }

    /// 清單順序 / 內容變了：按新順序重建音箱佇列，並保留播放位置與暫停狀態。
    /// 每個提前返回都寫日誌 —— 否則現場只剩「什麼都沒發生」，分不清沒觸發還是觸發後失敗。
    private func recastIfQueueActive(reason: String) {
        if externalSource {
            LogBus.d("\(reason)：音箱在放其他來源，略過重建")
            return
        }
        if !hasSession {
            LogBus.d("\(reason)：目前沒有播放中的工作階段，下次播放時再建佇列")
            sonosQueueSignature = ""
            return
        }
        if currentTrack == nil {
            LogBus.d("\(reason)：沒有目前曲目，略過重建")
            return
        }
        if selectedDevices().isEmpty {
            LogBus.d("\(reason)：沒有選中音箱，略過重建")
            return
        }
        let atSec = max(0, positionSec)
        let wasPlaying = deviceStatus.values.contains(.playing)
        LogBus.d("\(reason) → 按新順序重建佇列（第 \(queueIndex + 1) 首，\(atSec)s）")
        castCurrent(resumeAtSec: atSec, autoPlay: wasPlaying)
    }

    /// 「下一首播放」後讓音箱佇列跟上：能原生插隊就插隊，否則重建。
    private func syncSpeakerQueue(inserted: Track, rebuild: Bool) {
        if !hasSession || externalSource { return }
        if rebuild || !nativeQueueActive || busy {
            recastIfQueueActive(reason: "下一首播放")
            return
        }
        guard let ip = localIP, serverPort > 0 else { return }
        let speakers = controlTargets().filter { !$0.isLegacyS1 }
        if speakers.isEmpty { return }
        let insertAt = max(1, queueIndex + 2)
        let url = MediaRegistry.streamUrl(ip: ip, port: serverPort, track: inserted)
        let didl = SoapXml.didlLite(title: inserted.title, url: url, mimeType: inserted.mimeType, id: inserted.id)
        Task {
            var ok = true
            for speaker in speakers {
                let result = await soap.addMultipleURIsToQueue(
                    speaker, entries: [(url, didl)], firstTrackNumber: insertAt, enqueueAsNext: true
                )
                if !result.isSuccess {
                    ok = false
                    LogBus.w("原生插隊失敗（\(result.failureText)）")
                }
            }
            if ok {
                sonosQueueSignature = queueSignature()
                LogBus.i("已把「\(inserted.title)」插進音箱佇列第 \(insertAt) 位（原生插隊）")
            } else {
                LogBus.w("原生插隊不成功，改為重建整個佇列")
                recastIfQueueActive(reason: "下一首播放")
            }
        }
    }

    // MARK: - 恢復狀態

    /// App 被系統收掉但音箱還在播：重新進 App 時主動問音箱，把介面接回來。
    private func restorePlaybackState() async {
        guard currentTrack == nil else { return }
        let selected = selectedDevices().filter { !$0.isSatellite }
        guard let device = selected.first ?? coordinators().first else { return }
        guard let snapshot = await soap.getTransportSnapshot(device) else { return }
        guard !snapshot.uri.isEmpty else {
            LogBus.d("音箱目前沒有載入媒體，無需恢復")
            return
        }
        guard let fileId = MediaRegistry.fileId(fromStreamUri: snapshot.uri) else {
            LogBus.i("音箱目前播的是外部音源，不接管介面")
            return
        }
        guard snapshot.isPlaying || snapshot.isPaused else {
            LogBus.d("音箱狀態 \(snapshot.state)，不恢復播放介面")
            return
        }
        guard let track = library.first(where: { $0.id == fileId }) else {
            LogBus.d("音箱在放的曲目（\(fileId)）不在目前曲庫裡，不恢復")
            return
        }
        startQueue(source: library, current: track)
        positionSec = snapshot.positionSec
        durationSec = snapshot.durationSec > 0 ? snapshot.durationSec : track.durationMs / 1000
        setStatus(device.key, snapshot.isPlaying ? .playing : .paused)
        lastTransportState = snapshot.state
        let mediaUri = await soap.getMediaUri(device) ?? ""
        nativeQueueActive = mediaUri.hasPrefix("x-rincon-queue:")
        sonosQueueSignature = ""   // 音箱裡的順序未必等於曲庫順序，下次點歌時重建
        lastQueueTrack = snapshot.trackNumber
        castAt = platform.uptime() - Double(snapshot.positionSec)
        castDurationMs = track.durationMs
        LogBus.i("已從音箱恢復播放狀態：\(track.title) · \(snapshot.state) · \(Track.formatDuration(seconds: snapshot.positionSec))")
        notifyNowPlaying()
    }

    /// 曲庫掃描完成後若還沒有目前曲目，再試一次恢復。
    func libraryReady() {
        guard started, currentTrack == nil, !devices.isEmpty else { return }
        Task { await restorePlaybackState() }
    }

    // MARK: - 輪詢同步

    private func startPolling() {
        if pollTask != nil { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func pollLoop() async {
        var tick = 0
        var forceSample = true
        while !Task.isCancelled {
            let interval = await pollOnce(tick: tick, forceSample: forceSample)
            tick += 1
            forceSample = false
            // 以 0.5 秒為單位睡，kickPoll() 才能把長間隔（閒置 15 秒）提前打斷
            var waited = 0.0
            while waited < interval && !Task.isCancelled {
                if pollKick {
                    pollKick = false
                    forceSample = true
                    break
                }
                let slice = min(0.5, interval - waited)
                await sleepMs(Int(slice * 1000))
                waited += slice
            }
        }
    }

    private func kickPoll() {
        pollKick = true
    }

    /// 要盯的那一台：優先正在播 / 暫停中的主箱，其次是選中的主箱。
    /// 沒選中的音箱不看 —— 別的房間在放什麼不關我們的事。
    private func pollTarget() -> SonosDevice? {
        var fallback: SonosDevice? = nil
        for device in devices where !device.isSatellite {
            let status = deviceStatus[device.key]
            if status == .playing || status == .paused { return device }
            if fallback == nil && selectedKeys.contains(device.key) { fallback = device }
        }
        return fallback
    }

    /// 音箱按鍵不會推送任何事件，只能輪詢。回傳下一次間隔（秒）。
    private func pollOnce(tick: Int, forceSample: Bool) async -> Double {
        let active = pollTarget()

        if let active = active, !busy {
            let sampled = forceSample || tick % 2 == 0
            if sampled {
                // 手機換了 IP（重連 Wi-Fi）就更新，後面的 heal 會按新位址重推
                let ip = platform.currentLanIP()
                if ip != nil && ip != localIP { localIP = ip }

                let info = await soap.getPositionInfo(active)
                if !busy {
                    if let info = info {
                        refreshOwnership(active, info: info)
                        if !externalSource && hasSession && platform.uptime() - castSettledAt >= CastEngine.queueSettle {
                            if info.positionSec > 0 || info.durationSec > 0 {
                                positionSec = info.positionSec
                                if info.durationSec > 0 { durationSec = info.durationSec }
                            }
                        }
                        syncQueueTrack(active, info: info)
                    }
                    await syncTransportState(active)
                    if let status = deviceStatus[active.key], status == .playing || status == .paused {
                        mirrorSatelliteStatus(status)
                    }
                    if tick % 10 == 0 { await auditQueue(active) }
                    if forceSample || tick % 8 == 0 { await syncVolume(active) }
                    notifyNowPlaying()
                }
            } else if !externalSource && !connectionLost && deviceStatus[active.key] == .playing {
                // 兩次取樣之間本地插值；只在 PLAYING 時做，否則暫停時進度會抖動
                let nextValue = positionSec + 1
                if durationSec <= 0 || nextValue < durationSec { positionSec = nextValue }
            }
        }

        if connectionLost { return 30 }
        if active == nil { return 15 }
        if deviceStatus.values.contains(.playing) || busy { return 1 }
        return 5
    }

    /// 音箱被別的來源接手（Sonos App、AirPlay、電視）時交還控制權，不搶。
    private func refreshOwnership(_ device: SonosDevice, info: PositionInfo) {
        let uri = info.trackUri
        if uri.isEmpty { return }   // 切流中讀不到，下一輪再說
        let ours = uri.contains("/stream/")
        if !ours && !externalSource && hasSession {
            LogBus.i("音箱已被其他來源佔用（Sonos App 等），ZONOZ 交還控制權")
            externalSource = true
            nativeQueueActive = false
            lastQueueTrack = 0
            pausedAtSec = positionSec
        } else if ours && externalSource {
            LogBus.i("音箱已回到 ZONOZ 的串流")
            externalSource = false
        }
        if ours && hasSession { healStaleStreamHost(uri) }
    }

    /// 手機 IP 變了：音箱佇列裡的 URL 還指著舊位址 → 按新位址重推（15 秒內最多一次）。
    private func healStaleStreamHost(_ uri: String) {
        guard let ip = localIP, let host = DeviceDescription.host(of: uri), !host.isEmpty, host != ip else { return }
        let now = platform.uptime()
        if now - lastUrlHealAt < 15 { return }
        lastUrlHealAt = now
        LogBus.w("串流位址已過期：音箱裡是 \(host)，本機現在是 \(ip) → 按新位址重推")
        sonosQueueSignature = ""
        castCurrent(resumeAtSec: positionSec, autoPlay: deviceStatus.values.contains(.playing))
    }

    private func mirrorSatelliteStatus(_ status: DeviceStatus) {
        let mirrored: DeviceStatus = status == .idle ? .idle : .following
        for satellite in devices where satellite.isSatellite {
            let hasMaster = devices.contains { !$0.isSatellite && deviceStatus[$0.key] == status }
            if hasMaster || status == .idle {
                if deviceStatus[satellite.key] != mirrored { deviceStatus[satellite.key] = mirrored }
            }
        }
    }

    private func syncTransportState(_ device: SonosDevice) async {
        guard let state = await soap.getTransportState(device) else {
            soapFailStreak += 1
            if soapFailStreak >= 3 { markDisconnected() }
            return
        }
        if soapFailStreak > 0 || connectionLost {
            soapFailStreak = 0
            await markReconnected()
        }
        if busy { return }
        if externalSource {
            if deviceStatus[device.key] == .playing { setStatus(device.key, .paused) }
            return
        }
        let current = deviceStatus[device.key]
        switch state {
        case "PAUSED_PLAYBACK":
            if current == .playing || current == .pushing {
                LogBus.i("音箱已暫停（機身按鍵 / Sonos App），同步介面狀態")
                setStatus(device.key, .paused)
                pausedAtSec = positionSec
            }
            lastTransportState = state
        case "PLAYING":
            // 只接手「正在放我們串流」的音箱；閒置音箱在放別的東西不關我們的事
            if current == .paused || current == .pushing {
                LogBus.i("音箱已開始播放，同步介面狀態")
                setStatus(device.key, .playing)
            }
            lastTransportState = state
        case "STOPPED":
            if lastTransportState == "PLAYING" && (current == .playing || current == .paused) {
                if nativeQueueActive {
                    LogBus.i("音箱佇列播放結束")
                    setStatus(device.key, .idle)
                    mirrorSatelliteStatus(.idle)
                } else {
                    handleEarlyStop(device)
                }
            }
            lastTransportState = state
        default:
            lastTransportState = state
        }
    }

    /// 逐首推送模式下 PLAYING → STOPPED 有兩種含義，必須區分：
    /// 已播時長 < 總時長 − 20s 判為異常停止 → 先 Play 續上（最多 2 次），不要切歌；
    /// 否則才是真的播完 → 按播放模式續下一首。
    private func handleEarlyStop(_ device: SonosDevice) {
        if externalSource { return }
        let now = platform.uptime()
        let sinceAdvance = now - lastAdvanceAt
        if sinceAdvance < CastEngine.autoAdvanceDebounce {
            LogBus.d("剛切過歌（\(Int(sinceAdvance))s），忽略這次 STOPPED")
            return
        }
        let played = castAt > 0 ? now - castAt : Double.greatestFiniteMagnitude
        let expected = castDurationMs > 0 ? Double(castDurationMs) / 1000.0 : Double(durationSec)
        let tooEarly = expected > 0 && played < expected - CastEngine.earlyStopTolerance
        if tooEarly && earlyStopRetries < CastEngine.maxEarlyStopRetries {
            earlyStopRetries += 1
            LogBus.w("音箱提前停止（已播 \(Int(played))s / 共 \(Int(expected))s），嘗試續播而不是跳歌（第 \(earlyStopRetries) 次）")
            Task {
                _ = await soap.play(device)
                lastTransportState = "PLAYING"
            }
        } else {
            LogBus.i("播放結束 → 續下一首")
            playRelative(1)
        }
    }

    /// 機身切歌靠 <Track> 序號變化發現；再用 TrackURI 裡的 fileId 按「內容」校正，
    /// 避免清單與音箱佇列錯位時永久偏一位。
    private func syncQueueTrack(_ device: SonosDevice, info: PositionInfo) {
        if externalSource || queue.isEmpty { return }
        if platform.uptime() - castSettledAt < CastEngine.queueSettle { return }
        guard let trackNo = info.trackNumber, trackNo > 0 else { return }
        guard let playingId = MediaRegistry.fileId(fromStreamUri: info.trackUri) else { return }

        let indexByNumber = min(max(trackNo - 1, 0), queue.count - 1)
        let indexByContent = queue.firstIndex(where: { $0.id == playingId })
        let index = indexByContent ?? indexByNumber
        if trackNo == lastQueueTrack && index == queueIndex { return }

        if indexByContent == nil {
            // 音箱放的是我們的串流，但不在目前清單裡（例如清單剛換過）→ 不亂改介面
            LogBus.w("音箱放的不是清單裡的曲目（\(playingId)），略過同步")
            lastQueueTrack = trackNo
            return
        }
        if index != indexByNumber && nativeQueueActive && !sonosQueueSignature.isEmpty {
            LogBus.w("清單與音箱佇列錯位（音箱第 \(trackNo) 首 = 清單第 \(index + 1) 首），已按內容校正")
        }
        lastQueueTrack = trackNo
        if index != queueIndex {
            LogBus.i("音箱切到了佇列第 \(trackNo) 首 →「\(queue[index].title)」")
            queueIndex = index
            positionSec = info.positionSec
            durationSec = info.durationSec > 0 ? info.durationSec : queue[index].durationMs / 1000
            castAt = platform.uptime() - Double(info.positionSec)
            castDurationMs = queue[index].durationMs
            earlyStopRetries = 0
        }
    }

    private func syncVolume(_ device: SonosDevice) async {
        if platform.uptime() - lastVolumeSetAt < CastEngine.volumeSyncGuard { return }
        guard let value = await soap.getVolume(device) else { return }
        if platform.uptime() - lastVolumeSetAt < CastEngine.volumeSyncGuard { return }
        if value != volume { volume = value }
    }

    /// 佇列長度自檢：音箱裡的首數和清單對不上就重建（60 秒內最多一次）。
    private func auditQueue(_ device: SonosDevice) async {
        if externalSource || !nativeQueueActive || !shouldUseQueue() || busy { return }
        if sonosQueueSignature.isEmpty || deviceStatus[device.key] != .playing { return }
        let expected = queue.count
        guard let actual = await soap.getQueueSize(device), actual != expected else { return }
        if busy || queue.count != expected { return }
        let now = platform.uptime()
        if now - lastAuditRebuildAt < CastEngine.auditRebuildCooldown { return }
        lastAuditRebuildAt = now
        LogBus.w("佇列自檢失敗：音箱 \(actual) 首 / 清單 \(expected) 首 → 重建佇列")
        sonosQueueSignature = ""
        recastIfQueueActive(reason: "佇列自檢")
    }

    private func markDisconnected() {
        if connectionLost { return }
        LogBus.w("與音箱失去聯繫（Wi-Fi 斷開或音箱離線），介面轉為暫停")
        connectionLost = true
        if hasSession { hint = Hint(kind: .connectionLost) }
        notifyNowPlaying()
    }

    private func markReconnected() async {
        if !connectionLost { return }
        LogBus.i("與音箱恢復聯繫")
        connectionLost = false
        if hint?.kind == .connectionLost { hint = nil }
        _ = await prepareServer(force: true)
    }

    private func sleepMs(_ ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
}
