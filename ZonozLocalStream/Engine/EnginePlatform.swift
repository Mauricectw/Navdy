import Foundation

/// CastEngine 需要、但屬於作業系統層的能力。抽成協定讓引擎本身不依賴 iOS 框架，
/// 可以在沒有 Mac 的環境下對著假音箱做整合測試。
@MainActor
protocol EnginePlatform: AnyObject {
    /// 手機在 Wi-Fi 上的 IPv4；沒有 Wi-Fi 時回 nil
    func currentLanIP() -> String?
    /// 確保本地 HTTP 伺服器在跑，回傳監聽埠；失敗回 nil
    func ensureServer(force: Bool) async -> Int?
    /// 換一個埠重建伺服器（701 時用）
    func restartServerOnNewPort() async -> Int?
    /// 自動發現音箱
    func discover(localIP: String?) async -> [SonosDevice]
    /// 讀檔頭判斷取樣率 / 位元深度
    func probeFormat(of track: Track) -> AudioProbe.Format?
    /// 有 / 沒有進行中的播放工作階段（用來開關背景保活）
    func playbackSessionChanged(active: Bool)
    /// 曲目 / 狀態 / 進度有變，更新鎖定畫面
    func nowPlayingChanged()
    /// 單調時鐘（秒）
    func uptime() -> Double
}
