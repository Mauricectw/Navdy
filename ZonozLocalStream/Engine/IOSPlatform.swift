import Foundation
import MediaPlayer
import UIKit

/// EnginePlatform 的 iOS 實作：HTTP 伺服器、探索、背景保活、鎖定畫面。
@MainActor
final class IOSPlatform: EnginePlatform {

    weak var engine: CastEngine?

    private let server = LocalMediaServer()
    private let bonjour = BonjourScanner()
    private let prober = DeviceProber(timeout: 1.5)
    private let keeper = BackgroundKeeper()
    private var commandsInstalled = false
    private var sessionActive = false
    private var artworkTrackId = ""
    private var artwork: MPMediaItemArtwork?

    /// 使用者可在設定頁關掉（關掉後鎖屏 / 切到別的 App 會斷播）
    var keepAliveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "zonoz.keepAlive") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "zonoz.keepAlive")
            applyKeepAlive()
        }
    }

    init() {
        server.infoProvider = {
            return (NetUtils.currentLanIP() ?? "-", MediaRegistry.shared.count)
        }
    }

    // MARK: EnginePlatform

    func currentLanIP() -> String? {
        return NetUtils.currentLanIP()
    }

    func ensureServer(force: Bool) async -> Int? {
        if !force && server.isRunning {
            return server.currentPort
        }
        return await server.start(preferred: LocalMediaServer.defaultPort)
    }

    func restartServerOnNewPort() async -> Int? {
        let old = server.currentPort
        var preferred = old > 0 ? old + 1 : LocalMediaServer.defaultPort
        if preferred > LocalMediaServer.defaultPort + 40 { preferred = LocalMediaServer.defaultPort }
        return await server.start(preferred: preferred)
    }

    func discover(localIP: String?) async -> [SonosDevice] {
        async let viaBonjour = discoverBonjour()
        async let viaSubnet = discoverSubnet(localIP: localIP)
        let (first, second) = await (viaBonjour, viaSubnet)
        var byKey: [String: SonosDevice] = [:]
        for device in second { byKey[device.key] = device }
        for device in first { byKey[device.key] = device }   // Bonjour 的結果優先
        return Array(byKey.values)
    }

    private func discoverBonjour() async -> [SonosDevice] {
        let locations = await bonjour.scan(seconds: 2.5)
        var out: [SonosDevice] = []
        for location in locations {
            if let device = await prober.fetchDescription(location: location, source: .bonjour) {
                out.append(device)
            }
        }
        LogBus.d("Bonjour 找到 \(out.count) 台")
        return out
    }

    private func discoverSubnet(localIP: String?) async -> [SonosDevice] {
        guard let localIP = localIP else { return [] }
        let out = await prober.scanSubnet(localIP: localIP)
        LogBus.d("網段掃描找到 \(out.count) 台")
        return out
    }

    func probeFormat(of track: Track) -> AudioProbe.Format? {
        return AudioProbe.probe(fileURL: MusicLibrary.documentsURL.appendingPathComponent(track.relPath))
    }

    func playbackSessionChanged(active: Bool) {
        sessionActive = active
        applyKeepAlive()
        if !active { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    }

    func uptime() -> Double {
        return ProcessInfo.processInfo.systemUptime
    }

    private func applyKeepAlive() {
        if sessionActive && keepAliveEnabled {
            installRemoteCommands()
            keeper.start()
        } else {
            keeper.stop()
        }
    }

    func appBecameActive() {
        if sessionActive && keepAliveEnabled { keeper.ensureAlive() }
    }

    // MARK: 鎖定畫面 / 控制中心

    func nowPlayingChanged() {
        guard let engine = engine, sessionActive, let track = engine.currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(engine.positionSec),
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? 1.0 : 0.0
        ]
        let duration = engine.durationSec > 0 ? engine.durationSec : track.durationMs / 1000
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(duration) }
        if artworkTrackId == track.id, let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if artworkTrackId != track.id {
            artworkTrackId = track.id
            artwork = nil
            Task { [weak self] in
                guard let image = await CoverLoader.shared.load(track) else { return }
                guard let self = self, self.artworkTrackId == track.id else { return }
                self.artwork = IOSPlatform.makeArtwork(image)
                self.nowPlayingChanged()
            }
        }
    }

    /// 系統會在背景執行緒呼叫這個閉包，所以要在 nonisolated 的地方建立它。
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func installRemoteCommands() {
        if commandsInstalled { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()

        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (CastEngine) -> Void) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                guard let platform = self else { return .commandFailed }
                Task { @MainActor in
                    if let engine = platform.engine { action(engine) }
                }
                return .success
            }
        }
        bind(center.playCommand) { $0.resume() }
        bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        bind(center.nextTrackCommand) { $0.next() }
        bind(center.previousTrackCommand) { $0.previous() }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = Int(positionEvent.positionTime)
            guard let platform = self else { return .commandFailed }
            Task { @MainActor in
                platform.engine?.seek(to: seconds)
            }
            return .success
        }
    }
}
