import Foundation
import AVFoundation

/// 背景保活。
///
/// iOS 沒有 Android 的前景服務：App 一進背景幾秒內就會被暫停，本地 HTTP 伺服器跟著停擺，
/// 音箱抓不到下一段資料就會斷。做法是在播放期間於手機端循環播放一段「無聲」音訊，
/// 讓系統把 App 視為正在播放的音樂 App（需要 Info.plist 的 UIBackgroundModes = audio）。
/// 副作用：會中斷手機上其他 App 的音樂，鎖定畫面也會出現 ZONOZ 的播放控制（這正是我們要的）。
final class BackgroundKeeper {

    private var player: AVAudioPlayer?
    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.isRunning = false
            self.player = nil
            self.start()
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        if isRunning { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let newPlayer = try AVAudioPlayer(data: BackgroundKeeper.silentWav(seconds: 4))
            newPlayer.numberOfLoops = -1
            newPlayer.volume = 0
            newPlayer.prepareToPlay()
            guard newPlayer.play() else {
                LogBus.w("背景保活啟動失敗（無聲播放器沒有開始）")
                return
            }
            player = newPlayer
            isRunning = true
            LogBus.d("背景保活已開啟")
        } catch {
            LogBus.w("背景保活啟動失敗：\(error.localizedDescription)")
        }
    }

    func stop() {
        if !isRunning { return }
        player?.stop()
        player = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        LogBus.d("背景保活已關閉")
    }

    /// 來電 / Siri / 其他 App 搶走音訊後，把無聲播放接回來。
    private func handleInterruption(_ note: Notification) {
        guard isRunning,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            if player?.play() != true {
                LogBus.w("中斷結束後無法恢復背景保活；回到 App 會自動重建")
            }
        }
    }

    /// 回到前景時確認無聲播放還活著。
    func ensureAlive() {
        guard isRunning else { return }
        if player?.isPlaying != true {
            try? AVAudioSession.sharedInstance().setActive(true)
            if player?.play() != true {
                isRunning = false
                player = nil
                start()
            }
        }
    }

    /// 產生一段 8 kHz、16-bit、單聲道的全零 WAV。
    static func silentWav(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize = UInt32(seconds) * sampleRate * 2
        var data = Data()
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)              // PCM
        append16(1)              // mono
        append32(sampleRate)
        append32(sampleRate * 2) // byte rate
        append16(2)              // block align
        append16(16)             // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
