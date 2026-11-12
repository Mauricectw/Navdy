# ZONOZ Local Stream — iOS 移植版

把 Android 開源專案 [ZONOZ LOCAL STREAM](https://github.com/Chris94666/ZONOZ-LOCAL-STREAM)（1.2.1）改寫成 iPhone / iPad 可執行的 SwiftUI App。
做的事情和原版一樣：iPhone 在區域網路上架一個 HTTP 伺服器，用 UPnP / SOAP 叫 Sonos 自己來抓音樂；不用雲端、不用帳號、不經過 Sonos 官方 App。

> **目前狀態：尚未用 Xcode 編譯過，也沒在真機與真音箱上跑過。**
> 這份程式碼是在沒有 Mac 的環境寫的。協定層與播放引擎已對著模擬音箱通過離線測試；
> 其餘部分只對著手寫的 iOS API 替身做過型別檢查（見「驗證了什麼」）。第一次在 GitHub Actions 編譯時可能還要修幾個錯。

## 和 Android 版的差異（iOS 的限制造成的）

| 項目 | Android 原版 | iOS 版 |
| --- | --- | --- |
| 找音箱 | SSDP 組播 | **Bonjour（`_sonos._tcp`）＋ 同網段掃描 1400 埠 ＋ 手動輸入 IP**。iOS 送 SSDP 組播需要 Apple 核發的 multicast entitlement，側載拿不到 |
| 曲庫 | 掃描整台手機的音樂 | **App 自己的「文件」資料夾**（「檔案」App → 我的 iPhone → ZONOZ）。iOS 不允許 App 讀取其他位置，Apple Music 資料庫的歌也拿不出來 |
| 背景播放 | 前景服務 + WakeLock | 播放期間在手機端**循環播放無聲音訊**讓 App 不被暫停（會中斷手機上其他 App 的音樂；可在設定頁關閉） |
| 鎖屏控制 | 通知列 | 鎖定畫面 / 控制中心的播放控制（播放、暫停、上下首、拖進度） |
| HTTP 伺服器 | NanoHTTPD | Network.framework 自寫，同樣支援 `Range` / `206 Partial Content` |
| 語言 | 8 種 | 繁體中文、英文 |
| 未移植 | — | 介面縮放、封面取色、資料夾篩選、鬧鐘式續播計時器（改由輪詢偵測播完） |

播放邏輯照原版：整份清單用 `AddMultipleURIsToQueue`（每批 12 首、插入位置逐批遞增）灌進音箱原生佇列 →
`SetAVTransportURI(x-rincon-queue:…)` → 三道自檢（佇列長度 / 定位 / 讀回 TrackURI）→ 任何一步不過就退回逐首推送。

## 關於 Dolby Atmos

原版沒有任何 Atmos 專用程式碼——它只是把檔案原封不動交給音箱。能不能亮 Atmos 取決於**檔案與音箱**：

- 目前已知可行的是 **MP4 / M4A 容器裡的 E-AC-3 JOC（Dolby Digital Plus Atmos）**。這不在 Sonos 官方的本地音樂支援格式內，屬於「實際可用但官方不保證」。
- 需要支援 Atmos 的音箱（Arc、Arc Ultra、Beam Gen 2、Era 300 等）。
- TrueHD Atmos（藍光原聲、MKV）不行。
- App 會讀檔案的 `dec3` 資訊，是 E-AC-3 JOC 就在曲庫顯示「Dolby Atmos」徽章——這只代表檔案是 Atmos，音箱實際有沒有以 Atmos 播放請看 Sonos App。
- `.ec3` / `.eac3` / `.ac3` 裸位元流也會列進曲庫，但那是我額外加的實驗性對應，原版沒有、也沒人驗證過。

## 沒有 Mac 怎麼裝到 iPhone

需要：GitHub 帳號、Windows 電腦、Apple ID、傳輸線。

1. 在 GitHub 建一個新的 repository（私人即可），把這個資料夾的內容整個推上去（分支名稱 `main`）。
2. 到該 repo 的 **Actions** 分頁，`Build IPA` 會自動開始；跑完後在該次執行頁面底部的 **Artifacts** 下載 `ZONOZ-LocalStream-unsigned-ipa`，解壓得到 `.ipa`。
   - 如果 `ipa` 這個 job 紅了，下載 `xcodebuild-log`，把裡面 `error:` 的那幾行貼回來修。
3. Windows 上安裝 [Sideloadly](https://sideloadly.io)（它會要求先裝 Apple 官方的 iTunes 與 iCloud，非 Microsoft Store 版）。
4. iPhone 接上電腦並信任 → Sideloadly 拖入 `.ipa` → 輸入 Apple ID → Start。
5. iPhone：設定 → 一般 → VPN 與裝置管理 → 信任你的 Apple ID；另外到 設定 → 隱私權與安全性 → 開啟「開發者模式」。

免費 Apple ID 簽的 App **7 天到期**，到期後用 Sideloadly 重簽一次即可（曲庫檔案會保留）。付費開發者帳號則是一年。

有 Mac 的話：`brew install xcodegen && xcodegen generate`，開 `ZonozLocalStream.xcodeproj`，選自己的 Team 直接跑。

## 第一次使用

1. 開 App 時跳出「尋找並連接區域網路上的裝置」→ **允許**（拒絕的話什麼都找不到；可到 設定 → 隱私權與安全性 → 區域網路 重開）。
2. 放音樂進來，三選一：
   - App 曲庫頁右上角「＋」，從「檔案」App 選檔案或整個資料夾（會複製進 App）。
   - 「檔案」App → 我的 iPhone → ZONOZ，直接貼上。
   - Windows 的 iTunes / Apple 裝置 App →「檔案共享」→ ZONOZ，把資料夾拖進去。
3. 「設定」分頁確認音箱有出現並打勾；沒出現就手動輸入音箱 IP。
4. 回曲庫點一首歌。

排錯：設定 → 診斷 → 日誌，可以整份複製。常見的 701 = 音箱連不到 iPhone（不同網段、路由器 AP 隔離、開著 VPN）。

## 驗證了什麼、沒驗證什麼

已實際執行並通過（`Tests/run_linux_tests.sh`，Linux 上的 Swift 5.9，共 95 項檢查）：

- 純邏輯 32 項：SOAP / DIDL 轉義、裝置描述與區域組拓撲解析、HTTP Range、FLAC/WAV 規格檢查、`dec3` Atmos 判斷等。
- 播放引擎對著 `Tests/fake_sonos.py`（模擬 Sonos 的 UPnP 介面）：建佇列與順序、分批與對半拆分、定位、App / 機身切歌同步、暫停續播、音量同步、
  「下一首播放」、切隨機後保留播放秒數、單曲循環、不支援格式攔截、被其他來源接手時不搶播、佇列被拒時退回逐首推送。

只做了間接檢查：

- iOS 專屬的程式（HTTP 伺服器、Bonjour、曲庫掃描、背景保活、鎖屏控制、全部 SwiftUI 畫面）在 Linux 上沒有 iOS SDK 可用，
  我是對著**自己手寫的 API 替身**（Network、AVFoundation、MediaPlayer、SwiftUI… 的簽名）做型別檢查，全部通過。
  這能抓出拼錯、型別不合、漏 `await` 之類的錯，但替身是照記憶寫的，和真正的 SDK 有出入時就抓不到。
- `Net/NetUtils.swift`（讀取 Wi-Fi 位址）用到 Darwin 專屬的結構，只做了語法解析。

完全沒有驗證：

- 用 Xcode / iOS SDK 實際編譯與執行。
- 真實 Sonos 的行為（假音箱是照原專案的實測記錄寫的，不等於真機）。
- Bonjour 能否在你的網路找到音箱、背景保活在 iOS 27 上能撐多久、Atmos 是否點亮。

## 專案結構

```
ZonozLocalStream/
  Core/      純邏輯（SOAP、XML 取值、Range、格式檢查）— 不依賴 iOS
  Net/       SOAP 客戶端、探索、HTTP 伺服器
  Library/   曲庫掃描、封面
  Engine/    CastEngine（播放狀態機）＋ iOS 平台層
  UI/        SwiftUI 介面
Tests/       離線測試與假音箱
project.yml  XcodeGen 專案定義
```

## 授權

MIT。原專案 Copyright (c) 2026 大气放电现象；本移植版沿用同一授權。與 Sonos, Inc. 無關。
