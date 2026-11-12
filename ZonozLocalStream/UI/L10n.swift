import Foundation

/// 極簡雙語：系統語言是中文就用繁體中文，否則英文。
private let prefersChinese: Bool = {
    let first = Locale.preferredLanguages.first?.lowercased() ?? "zh-hant"
    return first.hasPrefix("zh")
}()

func L(_ zh: String, _ en: String) -> String {
    return prefersChinese ? zh : en
}

extension Hint {
    var message: String {
        switch kind {
        case .pickSong:
            return L("先在曲庫點一首歌。", "Pick a song from the library first.")
        case .noDevice:
            return L("還沒找到 / 選取音箱。請確認 iPhone 與 Sonos 在同一個 Wi-Fi，並已允許「區域網路」權限；也可以到設定頁手動輸入音箱 IP。",
                     "No speaker found or selected. Make sure the iPhone and Sonos share the same Wi-Fi and Local Network access is allowed, or add the speaker IP manually in Settings.")
        case .noWifi:
            return L("iPhone 沒有連上 Wi-Fi，無法把音樂提供給音箱。", "The iPhone is not on Wi-Fi, so the speaker cannot fetch audio.")
        case .serverFailed:
            return L("本地串流伺服器啟動失敗，請重開 App 再試。", "The local streaming server failed to start. Relaunch the app and try again.")
        case .reach:
            return L("音箱連不到 iPhone 的串流。請確認兩者在同一網段、路由器沒有開「AP 隔離」，並關掉 VPN。",
                     "The speaker cannot reach the stream on the iPhone. Check they are on the same subnet, AP isolation is off, and any VPN is disabled.")
        case .format:
            return L("音箱不接受這個檔案格式。", "The speaker rejected this file format.")
        case .badRequest:
            return L("音箱拒絕了這次請求（中繼資料有問題），請把設定頁的日誌回報給開發者。", "The speaker rejected the request (metadata problem). Please report the log from Settings.")
        case .offline:
            return L("連不上音箱\(detail.isEmpty ? "" : "（\(detail)）")，請確認它在線上且 IP 正確。",
                     "Cannot reach the speaker\(detail.isEmpty ? "" : " (\(detail))"). Check it is online and the IP is correct.")
        case .satellite:
            return L("選到的是配對 / 環繞的從屬音箱，請改選主音箱。", "The selected speaker is a bonded satellite. Select the main speaker instead.")
        case .unknown:
            return L("播放失敗，詳情請看設定頁的日誌。", "Playback failed. See the log in Settings for details.")
        case .unsupportedFormat:
            return L("這個檔案超出 Sonos 規格（\(detail)）：上限 48 kHz，WAV / AIFF 只支援 16 bit。",
                     "This file exceeds Sonos limits (\(detail)): max 48 kHz; WAV/AIFF 16-bit only.")
        case .mixedGeneration:
            return L("同時選了 S1 與 S2 音箱，S1 只能逐首推送。", "Both S1 and S2 speakers are selected; S1 falls back to single-track casting.")
        case .connectionLost:
            return L("與音箱失去聯繫，恢復後會自動重新同步。", "Lost contact with the speaker. It will resync when the connection returns.")
        case .localNetworkDenied:
            return L("請到「設定 → 隱私權與安全性 → 區域網路」允許 ZONOZ。", "Allow ZONOZ under Settings → Privacy & Security → Local Network.")
        }
    }
}

extension DeviceStatus {
    var label: String {
        switch self {
        case .idle: return L("閒置", "Idle")
        case .pushing: return L("推送中", "Casting")
        case .playing: return L("播放中", "Playing")
        case .paused: return L("已暫停", "Paused")
        case .error: return L("錯誤", "Error")
        case .following: return L("隨主箱同步", "Following")
        }
    }
}

extension LibrarySort {
    var label: String {
        switch self {
        case .title: return L("歌名", "Title")
        case .artist: return L("演出者", "Artist")
        case .album: return L("專輯", "Album")
        case .recent: return L("最近加入", "Recently added")
        case .folder: return L("資料夾", "Folder")
        }
    }
}
