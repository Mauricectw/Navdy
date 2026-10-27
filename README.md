# Navdy HUD — 社群版 iOS App（實驗性）

讓 iPhone（iOS 17 以上，含 iOS 27）重新可以把目的地送到 Navdy HUD 開始導航。
不需要 Mac：專案在 GitHub 的雲端 Mac 上編譯，再從 Windows 用 Sideloadly 安裝到 iPhone。

> 目前狀態：**協定層已用 Google protobuf 產生的標準位元組驗證**；與實機 HUD 的連線尚未測試。
> 第一次使用請照「第一次實機測試」做，並把 App 內的通訊紀錄回報回來。

## 運作方式

```
iPhone App ──藍牙 iAP2 (MFi)──▶ HUD
  └ EA 協定 com.navdy.hud.api.v1：5-byte 訊框 + NavdyEvent protobuf
```

這些都是從 HUD 韌體原始碼（alelec/navdy-display-Hud-java）讀出來的，不是猜的：

| 項目 | 來源 |
|---|---|
| EA 協定字串 `com.navdy.hud.api.v1` / `com.navdy.hud.proxy.v1` | `com/navdy/hud/mfi/iAPProcessor.java` |
| HUD 開啟 api.v1 後走跟 Android 相同的 protobuf 連線 | `com/navdy/hud/device/connection/iAP2Link.java` (`onSessionStart`) |
| 訊框：`Frame{fixed32 size}` 固定 5 bytes | `NavdyEventReader.java` / `NavdyEventWriter.java` |
| 訊息內容 `NavdyEvent.type` + 欄位號 = type + 100 | `Ext_NavdyEvent.java`（140 種全部對上） |
| 連線後互送 DeviceInfo、60 秒沒訊息會斷線 | `ConnectionService.java` |
| `autoNavigate=true` 時 HUD 算完路線自動開始導航 | `HereRouteManager.java` |

導航本身（路線計算、轉彎提示、HUD 上的地圖畫面）是 HUD 用內建 GPS 與離線 HERE 地圖做的，這部分換不成 Google 地圖——
HUD 韌體只內建 HERE 引擎，Google 也沒有能放進 HUD 的離線地圖。原廠和社群版 Android App 也是同樣分工：手機只負責「找目的地」。

App 找目的地的方式（可在右上角齒輪切換）：

| 方式 | 需要 API 金鑰 | 說明 |
|---|---|---|
| **Google 地圖搜尋** | 要（自己申請，見第三節） | Google Places API (New)，台灣店家、地標資料最完整 |
| **貼上 Google 地圖分享連結** | 不用 | 在 Google 地圖 App 找到地點 → 分享 → 複製 → 回 App 按「貼上」 |
| Apple 地圖搜尋 | 不用 | 沒設定金鑰時自動使用 |

## 目錄

| 路徑 | 內容 |
|---|---|
| `NavdyHUD/` | App（SwiftUI）：`HUD/HUDLink.swift` 藍牙連線、`HUD/HUDController.swift` 握手與訊息、`Search/` 目的地搜尋 |
| `Packages/NavdyWire/` | `NavdyWire` 協定層、`NavdyPlaces` Google 連結解析與 Places API 格式（純 Foundation，可在 Linux 跑測試） |
| `Proto/navdy.proto` | 完整協定（204 個型別），由韌體自動還原 |
| `Tools/wire2proto.py` | 從韌體的 Wire 類別重新產生 `navdy.proto` |
| `Tools/gen_vectors.py` | 用官方 protobuf 產生測試向量 |
| `project.yml` | XcodeGen 專案設定（雲端自動產生 .xcodeproj） |
| `.github/workflows/build.yml` | 雲端建置，產出未簽章的 `.ipa` |

## 一、在 GitHub 雲端編譯

1. 註冊／登入 GitHub，建立新的 repository（建議 **Public**：公開 repo 使用標準 runner 不計費；Private 的每月免費分鐘數在 macOS 上以 10 倍計，大約只夠二、三十次建置）。
2. 把這個專案推送到 repo（已推送可略過）。
3. 到 repo 的 **Actions** 分頁，等「Build unsigned IPA」跑完（約 5–10 分鐘）。
4. 點進該次執行，下載 **NavdyHUD-unsigned-ipa**，解壓縮得到 `NavdyHUD-unsigned.ipa`。

建置失敗時，下載 **build-log** 把錯誤訊息貼回來即可。

## 二、從 Windows 安裝到 iPhone

1. 在 Windows 安裝 **Apple 官網版**的 iTunes 與 iCloud（不是 Microsoft Store 版），以及 Sideloadly。
2. iPhone 用 USB 接電腦，信任這台電腦。
3. Sideloadly：拖入 `.ipa`，填入你的 Apple ID，按 Start。
4. iPhone：設定 → 隱私權與安全性 → **開發者模式** 打開（會重新開機）；
   設定 → 一般 → VPN 與裝置管理 → 信任你的 Apple ID。
5. 免費 Apple ID 簽的 App **7 天後失效**，需再用 Sideloadly 重簽（資料保留）；付費開發者帳號為一年。

## 三、Google 地圖搜尋的 API 金鑰（選用）

只想用「貼上分享連結」或 Apple 地圖，可以跳過這節。

1. 到 [Google Cloud Console](https://console.cloud.google.com/) 建立一個專案。
2. 綁定**計費帳戶**（Google 規定要信用卡；個人使用量遠低於免費額度，正常不會扣款）。
3. 「API 和服務」→「程式庫」→ 搜尋並啟用 **Places API (New)**（不是舊版「Places API」）。
4. 「API 和服務」→「憑證」→「建立憑證」→「API 金鑰」，再編輯這把金鑰：
   - **API 限制**：只允許 Places API (New)。
   - **應用程式限制**：選「iOS 應用程式」，Bundle ID 填 App 設定頁顯示的值（先裝好 App 再填；Sideloadly 可能改過 Bundle ID）。
5. 防盜刷（建議）：在 Places API (New) 的「配額與系統限制」把請求上限調低（例如每分鐘 60 次），並在「帳單」設預算快訊（例如 US$1）。
6. App 右上角齒輪 → 貼上金鑰 → 儲存 → **測試金鑰** 出現 ✅ 即可。金鑰存在 iPhone 鑰匙圈。

費用（Google Maps Platform 價目表，每月免費額度）：

| 項目 | 每月免費 | App 何時用到 |
|---|---|---|
| Autocomplete 請求 | 10,000 次 | 打字搜尋（有 0.3 秒防抖）；選了結果的那次搜尋整段免費 |
| Place Details Essentials | 10,000 次 | 選定地點時取座標與地址，一次 |

App 只向 Google 要座標與地址兩個欄位（Essentials 等級），刻意不要店名欄位（那會變成較貴的 Pro 等級），店名直接用搜尋建議的文字。

## 四、第一次實機測試

1. 車上發動、HUD 開機。若之前配對過其他手機而連不上，先把 iPhone 藍牙裡舊的 Navdy 項目「忘記此裝置」，必要時也清除 HUD 端的配對紀錄。
2. iPhone 打開藍牙，開 App → **配對 HUD（第一次使用）**，在 iOS 跳出的清單選 Navdy。
3. 狀態變成綠色勾勾並顯示 HUD 韌體版本 = 握手成功。
4. 停車狀態下搜尋目的地（或貼上 Google 地圖分享連結），點選結果 → HUD 應開始計算路線並導航。
5. 不論成功與否，展開「通訊紀錄」→ **複製全部紀錄**，貼回來分析。

常見狀況：

- 一直「尋找 HUD 中」：紀錄裡會列出 iPhone 看到的配件與協定字串；沒有 `com.navdy.hud.api.v1` 表示 iAP2 配對沒成功。
- 「無法開啟 EASession」：Info.plist 協定宣告有問題（Sideloadly 不會改它，通常是建置設定）。
- 路線失敗 `NOT_READY`／引擎未就緒：HUD 地圖還在載入或沒有離線地圖，等一下再試。
- Google 搜尋出錯：畫面會直接說明原因（金鑰無效、未啟用 Places API (New)、未綁計費、Bundle ID 限制不符）。
- 貼上連結後位置不準：連結若只有地名沒有座標，會再搜尋一次地名；紀錄裡有「短網址展開」的結果，可以貼回來檢查。

## 尚未實作／已知限制

- **`com.navdy.hud.proxy.v1` 網路代理**：HUD 透過手機上網（即時路況、線上搜尋）的功能還沒做。
- 原廠 App 的通知、音樂、行事曆、聯絡人同步都沒做；HUD 韌體自己透過 iAP2 處理的部分可能可用，未驗證。
- 只能側載安裝，無法上架 App Store（需要原廠向 Apple 登記的 MFi 授權，Navdy 已不存在）。

請勿在行駛中操作手機，目的地請在停車時設定。

## 授權

協定定義衍生自 alelec/navdy 社群專案的反編譯原始碼，僅供 Navdy 車主自用與互通性用途。
