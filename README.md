# ZONOZ Local Stream — Windows 版

把 Android 開源專案 [ZONOZ LOCAL STREAM](https://github.com/Chris94666/ZONOZ-LOCAL-STREAM)（1.2.1）改寫成 Windows 桌面程式（C# / .NET 10 / WPF）。
做的事情和原版一樣：電腦在區域網路上架一個 HTTP 伺服器，用 UPnP / SOAP 叫 Sonos 自己來抓音樂；不用雲端、不用帳號、不經過 Sonos 官方 App。

## 下載與執行

到 Releases 下載 `ZonozLocalStream.exe`（約 60 MB，已內含 .NET 執行環境，免安裝），放到任何資料夾直接執行。需要 Windows 10 / 11 x64。

第一次執行會遇到兩個 Windows 的提示：

1. **SmartScreen「Windows 已保護您的電腦」**：程式沒有數位簽章。按「其他資訊」→「仍要執行」。
2. **Windows 防火牆詢問是否允許存取**：一定要允許，而且要勾「私人網路」。音箱是回頭向這台電腦抓音樂的，被擋住就會播不出來（日誌裡會看到 701）。

## 使用

1. 啟動後會自動找音箱（SSDP）；左側打勾的就是要播放的音箱。找不到就在左下輸入音箱 IP。
2. 預設曲庫是「音樂」資料夾。按「加入資料夾…」或直接把資料夾拖進視窗可以加別的位置（含子資料夾）。
3. 在曲庫點兩下一首歌開始播放；右鍵有「下一首播放」「收藏」「在檔案總管中顯示」。
4. 快捷鍵：空白鍵播放 / 暫停、Enter 播放選取的歌、Ctrl+F 搜尋；視窗在前景時鍵盤的媒體鍵也有效。

### 播放清單

- 左側欄分成「資料庫」（歌曲、收藏、最近播放）和「播放清單」。按「＋」或 Ctrl+N 新增清單，F2 改名，Del 刪除。
- 加歌：把歌曲（可多選）拖到左側的清單名稱上；拖到清單區的空白處會直接用這些歌建立新清單；或右鍵 →「加入播放清單」。
- 在清單裡直接拖曳可以調整順序，Del 把歌移出清單（不會刪檔案）。
- 右鍵清單可以複製、匯出成 M3U8；「＋」選單可以匯入 M3U / M3U8。
- 清單存的是檔案路徑：外接硬碟沒插時清單不會被清掉，檔案回來就自動恢復。

### 其他

- **搜尋建議**：在搜尋框打字時會即時跳出最相關的歌（搜尋整個曲庫），按 ↓ 選擇、Enter 或點一下直接播放。
- **睡眠定時**：播放列的時鐘按鈕，可選 15 / 30 / 60 / 90 分鐘後或「播完這首後」停止。
- **全域媒體鍵**：有歌在播時，鍵盤的播放 / 上一首 / 下一首鍵在視窗不在前景時也有效；停止後會還給其他程式（可在設定關閉）。
- 會記住視窗大小與位置、上次停留的清單。

設定與播放清單存在 `%AppData%\ZonozLocalStream`（`settings.json`、`playlists.json`）。關閉程式時會停止音箱上的播放（程式一關，音箱就抓不到後面的音樂了）。

## 和 Android / iOS 版的差異

| 項目 | Windows 版 |
| --- | --- |
| 找音箱 | SSDP（每張網卡各發一次）；落空時改掃同網段 1400 埠；可手動輸入 IP |
| 曲庫 | 你指定的資料夾，標籤與封面用 Audio Tools Library 讀取，結果有快取 |
| 本機位址 | 依路由表取「通往音箱」的那張網卡的位址，多網卡 / VPN / 虛擬網卡的電腦也不會給錯 |
| 背景 | 一般桌面程式，縮小視窗照常運作；播放期間會阻止電腦睡眠（可在設定關閉） |
| 未做 | 系統匣圖示、Windows 的媒體浮動控制 |

播放邏輯照原版：整份清單用 `AddMultipleURIsToQueue`（每批 12 首、插入位置逐批遞增）灌進音箱原生佇列 →
`SetAVTransportURI(x-rincon-queue:…)` → 三道自檢（佇列長度 / 定位 / 讀回 TrackURI）→ 任何一步不過就退回逐首推送。

## 關於 Dolby Atmos

程式只是把檔案原封不動交給音箱，能不能亮 Atmos 取決於檔案和音箱：
目前已知可行的是 **MP4 / M4A 容器裡的 E-AC-3 JOC**，搭配支援 Atmos 的音箱；TrueHD（MKV）不行。
曲庫的「格式」欄會把 E-AC-3 JOC 的檔案標成「Dolby Atmos」——這只代表檔案是 Atmos，音箱實際有沒有以 Atmos 播放請看 Sonos App。

## 驗證了什麼

每次推送，GitHub Actions 會在 Windows 上跑完下面全部才算通過：

- 純邏輯 34 項：SOAP / DIDL 轉義、裝置描述與拓撲解析、Range、FLAC/WAV 規格檢查、`dec3` Atmos 判斷等。
- HTTP 伺服器、曲庫、播放清單與搜尋建議 36 項：200 / 206 / 416、`bytes=N-` 拖進度、HEAD、16 條併發、埠被佔用時自動換埠；
  播放清單的新增 / 改名 / 多選搬移 / 移除 / M3U8 匯出匯入；搜尋建議的排序。
- 播放引擎對著 `Tests/fake_sonos.py`（模擬 Sonos 的 UPnP 介面，而且會像音箱一樣用 Range 回頭抓串流）共 76 項：
  建佇列與順序、分批與對半拆分、App / 機身切歌同步、暫停續播、音量、下一首播放、切隨機後保留秒數、不支援格式攔截、
  被其他來源接手時不搶播、佇列被拒時退回逐首推送。
- **冒煙測試**：把發佈出來的 exe 真的開起來，掃描 `Tests/media` 的測試音檔、建立播放清單並調整順序、觸發搜尋建議、連上假音箱播放，
  檢查沒有 XAML 繫結錯誤，並把每個分頁畫成 PNG（淺色與深色主題）。

沒有驗證的：**真實 Sonos 音箱**。假音箱是照原專案的實測記錄寫的，不等於真機；SSDP 在你的網路能否找到音箱、Atmos 是否點亮，都要實機確認。

## 自己編譯

需要 .NET 10 SDK 與 Python 3（測試用）。

```
Tests/run_tests.sh                       # 離線測試（Git Bash / Linux / macOS）
dotnet publish Zonoz.App -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
```

```
Zonoz.Core/    協定、HTTP 伺服器、探索、曲庫掃描、播放引擎（不依賴 Windows，可在任何平台測試）
Zonoz.App/     WPF 介面
Zonoz.Tests/   測試程式
Tests/         假音箱、測試音檔
```

## 授權

MIT。原專案 Copyright (c) 2026 大气放电现象；本移植版沿用同一授權。標籤讀取使用 [Audio Tools Library](https://github.com/Zeugma440/atldotnet)（MIT）。與 Sonos, Inc. 無關。
