import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var engine: CastEngine
    @EnvironmentObject private var library: MusicLibrary
    @State private var manualIP = ""
    @State private var keepAlive = true

    var body: some View {
        NavigationStack {
            Form {
                speakerSection
                streamSection
                backgroundSection
                librarySection
                Section(L("診斷", "Diagnostics")) {
                    NavigationLink(L("日誌", "Log")) { LogView() }
                }
                aboutSection
            }
            .navigationTitle(L("設定", "Settings"))
            .onAppear { keepAlive = model.platform.keepAliveEnabled }
        }
    }

    private var speakerSection: some View {
        Section {
            if engine.devices.isEmpty && !engine.scanning {
                Text(L("還沒找到音箱。請確認 iPhone 與 Sonos 在同一個 Wi-Fi，且已允許本 App 使用「區域網路」。",
                       "No speakers yet. Make sure the iPhone and Sonos share the same Wi-Fi and Local Network access is allowed."))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(engine.devices) { device in
                Button(action: { engine.toggleSelection(device.key) }) {
                    DeviceRow(
                        device: device,
                        selected: engine.selectedKeys.contains(device.key),
                        subtitle: deviceSubtitle(device),
                        status: (engine.deviceStatus[device.key] ?? .idle).label
                    )
                }
                .disabled(device.isSatellite)
                .swipeActions {
                    Button(role: .destructive) {
                        engine.removeDevice(device.key)
                    } label: {
                        Label(L("移除", "Remove"), systemImage: "trash")
                    }
                }
            }
            Button(action: { engine.scan() }) {
                HStack {
                    Label(L("重新尋找音箱", "Scan for speakers"), systemImage: "dot.radiowaves.left.and.right")
                    Spacer()
                    if engine.scanning { ProgressView() }
                }
            }
            .disabled(engine.scanning)
            HStack {
                TextField(L("手動輸入音箱 IP，例如 192.168.1.20", "Speaker IP, e.g. 192.168.1.20"), text: $manualIP)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button(L("加入", "Add")) {
                    engine.addManualDevice(ip: manualIP)
                    manualIP = ""
                }
                .disabled(!DeviceProber.isValidIPv4(manualIP.trimmingCharacters(in: .whitespaces)))
            }
        } header: {
            Text(L("音箱", "Speakers"))
        } footer: {
            Text(L("立體聲配對 / 環繞的從屬音箱會自動跟著主音箱，不能單獨選取。選了多台獨立音箱時，每台會各自播放（不是 Sonos 的群組同步）。",
                   "Bonded satellites follow their main speaker and cannot be selected. Multiple independent speakers each play on their own (not a synced Sonos group)."))
        }
    }

    private func deviceSubtitle(_ device: SonosDevice) -> String {
        var parts = [device.modelName, device.ip]
        if device.isSatellite {
            parts.append(L("從屬音箱", "satellite") + (device.channelRole.isEmpty ? "" : " \(device.channelRole)"))
        }
        if let error = engine.deviceError[device.key] { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private var streamSection: some View {
        Section {
            row(L("iPhone 位址", "iPhone address"), engine.localIP ?? L("沒有 Wi-Fi", "No Wi-Fi"))
            row(L("串流埠", "Stream port"), engine.serverPort > 0 ? "\(engine.serverPort)" : "-")
            if let url = engine.streamUrl {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("最近推給音箱的網址", "Last URL sent to the speaker"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            if NetUtils.isVPNLikelyActive() {
                Text(L("偵測到 VPN。若音箱抓不到串流，請先關掉 VPN。", "A VPN appears active. If the speaker cannot fetch the stream, turn it off."))
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
        } header: {
            Text(L("本地串流", "Local stream"))
        } footer: {
            Text(L("用同一個 Wi-Fi 上的電腦瀏覽器開「http://iPhone位址:埠/」，看得到頁面就代表音箱也連得到。",
                   "Open http://<iPhone address>:<port>/ from a computer on the same Wi-Fi; if the page loads, the speaker can reach it too."))
        }
    }

    private var backgroundSection: some View {
        Section {
            Toggle(L("背景 / 鎖屏時保持串流", "Keep streaming in background"), isOn: $keepAlive)
                .onChange(of: keepAlive) { value in
                    model.platform.keepAliveEnabled = value
                }
        } header: {
            Text(L("背景", "Background"))
        } footer: {
            Text(L("iOS 會在 App 進背景後幾秒內把它暫停，音箱就抓不到音樂。開啟後，播放期間 App 會在手機端播放一段無聲音訊來保持運作，並在鎖定畫面顯示播放控制；代價是會中斷手機上其他 App 的音樂，也會多耗一些電。",
                   "iOS suspends apps seconds after they leave the foreground, which cuts the speaker off. When on, the app plays silent audio on the phone during playback to stay alive and shows lock-screen controls; this interrupts other audio apps on the phone and uses some extra battery."))
        }
    }

    private var librarySection: some View {
        Section {
            row(L("曲目數", "Tracks"), "\(library.tracks.count)")
            Button(action: { library.scan() }) {
                HStack {
                    Label(L("重新掃描曲庫", "Rescan library"), systemImage: "arrow.clockwise")
                    Spacer()
                    if library.scanning { ProgressView() }
                }
            }
            .disabled(library.scanning)
        } header: {
            Text(L("曲庫", "Library"))
        } footer: {
            Text(L("音樂放在「檔案」App → 我的 iPhone → ZONOZ。Sonos 本地播放上限 48 kHz；WAV / AIFF 只支援 16 bit。",
                   "Music lives in Files → On My iPhone → ZONOZ. Sonos local playback tops out at 48 kHz; WAV/AIFF 16-bit only."))
        }
    }

    private var aboutSection: some View {
        Section {
            row(L("版本", "Version"), Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
            NavigationLink(L("授權與致謝", "License & credits")) { LicenseView() }
        } header: {
            Text(L("關於", "About"))
        } footer: {
            Text(L("ZONOZ Local Stream 的非官方 iOS 移植版。完全在區域網路內運作：沒有帳號、沒有雲端、不連外部網路。與 Sonos, Inc. 無關。",
                   "Unofficial iOS port of ZONOZ Local Stream. Works entirely on the local network: no account, no cloud, no external requests. Not affiliated with Sonos, Inc."))
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct DeviceRow: View {
    let device: SonosDevice
    let selected: Bool
    let subtitle: String
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selected ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .foregroundColor(.primary)
                    if !device.generationLabel.isEmpty {
                        Text(device.generationLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.2))
                            .clipShape(Capsule())
                            .foregroundColor(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(status)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var log: LogBus
    @State private var copied = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        List {
            ForEach(log.entries.reversed()) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Text(LogView.timeFormatter.string(from: entry.time))
                        .foregroundColor(.secondary)
                    Text(entry.level.rawValue)
                        .foregroundColor(color(entry.level))
                    Text(entry.message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2.monospaced())
                .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
            }
        }
        .listStyle(.plain)
        .navigationTitle(L("日誌", "Log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(copied ? L("已複製", "Copied") : L("複製", "Copy")) {
                    UIPasteboard.general.string = log.exportText()
                    copied = true
                }
                Button(L("清除", "Clear")) {
                    log.clear()
                    copied = false
                }
            }
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warn: return .orange
        case .tx, .rx: return .blue
        case .info: return .primary
        case .debug: return .secondary
        }
    }
}

struct LicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("這個 App 是開源專案 ZONOZ LOCAL STREAM（Android）的 iOS 移植，協定層的做法與實測結論都來自原專案。",
                       "This app is an iOS port of the open-source ZONOZ LOCAL STREAM (Android). The protocol approach and its field-tested findings come from the original project."))
                Text("https://github.com/Chris94666/ZONOZ-LOCAL-STREAM")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text(LicenseView.mit)
                    .font(.caption.monospaced())
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(L("授權與致謝", "License & credits"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static let mit = """
    MIT License

    Copyright (c) 2026 大气放电现象

    Permission is hereby granted, free of charge, to any person obtaining a copy \
    of this software and associated documentation files (the "Software"), to deal \
    in the Software without restriction, including without limitation the rights \
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
    copies of the Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """
}
