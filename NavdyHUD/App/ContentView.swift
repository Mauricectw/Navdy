import NavdyWire
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var hud: HUDController
    @EnvironmentObject private var search: PlaceSearch
    @State private var resolving = false
    @State private var resolveError: String?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                navigationSection
                searchSection
                logSection
            }
            .navigationTitle("Navdy HUD")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(search) }
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section("連線") {
            switch hud.connection {
            case .searching:
                Label("尋找 HUD 中…", systemImage: "antenna.radiowaves.left.and.right")
                Button("配對 HUD（第一次使用）") { hud.pair() }
                Button("重新掃描") { hud.rescan() }
            case .connecting(let name):
                Label("連線到 \(name)…", systemImage: "hourglass")
            case .connected(let name):
                Label(name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let info = hud.hudInfo {
                    LabeledContent("HUD 韌體", value: info.clientVersion)
                }
            }
        }
    }

    // MARK: Navigation

    @ViewBuilder private var navigationSection: some View {
        if hud.activeLabel != nil || hud.maneuver != nil || hud.lastRouteStatus != nil {
            Section("導航") {
                if let label = hud.activeLabel { LabeledContent("目的地", value: label) }
                if let status = hud.lastRouteStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
                if let m = hud.maneuver {
                    HStack(spacing: 16) {
                        Image(systemName: TurnText.symbol(m.pendingTurn))
                            .font(.system(size: 40, weight: .semibold))
                            .frame(width: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(m.distanceToPendingTurn) 後\(TurnText.text(m.pendingTurn))").font(.headline)
                            if !m.pendingStreet.isEmpty { Text(m.pendingStreet) }
                            Text("目前：\(m.currentRoad)　抵達 \(m.eta)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let s = hud.sessionState { LabeledContent("狀態", value: TurnText.state(s)) }
                Button("停止導航", role: .destructive) { hud.stopNavigation() }
            }
        }
    }

    // MARK: Search

    private var searchSection: some View {
        Section {
            TextField(search.effectiveProvider == .google ? "搜尋 Google 地圖" : "搜尋地點或地址",
                      text: $search.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in go(search.linkSuggestion(for: text)) }
            }
            .labelStyle(.titleAndIcon)
            if let e = search.error ?? resolveError {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
            if resolving { ProgressView("取得座標中…") }
            ForEach(search.suggestions) { s in
                Button {
                    go(s)
                } label: {
                    VStack(alignment: .leading) {
                        Text(s.title).foregroundStyle(.primary)
                        if !s.subtitle.isEmpty { Text(s.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .disabled(resolving)
            }
        } header: {
            Text("目的地")
        } footer: {
            Text("搜尋來源：\(search.effectiveProvider.title)。也可以在 Google 地圖 App 按「分享」→「複製」，再按上面的「貼上」。")
        }
    }

    private func go(_ s: Suggestion) {
        resolving = true
        resolveError = nil
        Task { @MainActor in
            defer { resolving = false }
            do {
                let dest = try await search.resolve(s) { msg in Task { @MainActor in hud.note(msg) } }
                hud.note("目的地：\(dest.name) \(dest.address ?? "") (\(dest.latitude), \(dest.longitude))")
                guard hud.isConnected else {
                    resolveError = "已取得「\(dest.name)」的座標，但 HUD 尚未連線。"
                    return
                }
                hud.navigate(to: dest)
                search.query = ""
            } catch {
                resolveError = error.localizedDescription
                hud.note("解析目的地失敗：\(error)")
            }
        }
    }

    // MARK: Log

    private var logSection: some View {
        Section {
            DisclosureGroup("通訊紀錄（\(hud.logLines.count)）") {
                ForEach(Array(hud.logLines.suffix(200).enumerated().reversed()), id: \.offset) { item in
                    Text(item.element).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }
            Button("複製全部紀錄") { UIPasteboard.general.string = hud.logLines.joined(separator: "\n") }
        }
    }
}

enum TurnText {
    static func text(_ t: NavigationTurn?) -> String {
        switch t {
        case .left: return "左轉"
        case .right: return "右轉"
        case .easyLeft, .keepLeft: return "靠左"
        case .easyRight, .keepRight: return "靠右"
        case .sharpLeft: return "向左急轉"
        case .sharpRight: return "向右急轉"
        case .straight, .followRoute: return "直行"
        case .uturnLeft, .uturnRight: return "迴轉"
        case .exitLeft: return "左側出口"
        case .exitRight: return "右側出口"
        case .mergeLeft: return "向左匯入"
        case .mergeRight: return "向右匯入"
        case .motorway: return "上高速公路"
        case .exitRoundabout: return "離開圓環"
        case .roundaboutN, .roundaboutNE, .roundaboutE, .roundaboutSE,
             .roundaboutS, .roundaboutSW, .roundaboutW, .roundaboutNW: return "進入圓環"
        case .ferry: return "搭渡輪"
        case .end: return "抵達目的地"
        case .start: return "出發"
        default: return ""
        }
    }

    static func symbol(_ t: NavigationTurn?) -> String {
        switch t {
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .easyLeft, .keepLeft, .exitLeft, .mergeLeft: return "arrow.up.left"
        case .easyRight, .keepRight, .exitRight, .mergeRight: return "arrow.up.right"
        case .uturnLeft: return "arrow.uturn.down"
        case .uturnRight: return "arrow.uturn.down"
        case .end: return "flag.checkered"
        case .roundaboutN, .roundaboutNE, .roundaboutE, .roundaboutSE,
             .roundaboutS, .roundaboutSW, .roundaboutW, .roundaboutNW, .exitRoundabout: return "arrow.triangle.turn.up.right.circle"
        default: return "arrow.up"
        }
    }

    static func state(_ s: NavigationSessionState) -> String {
        switch s {
        case .started: return "導航中"
        case .stopped: return "已停止"
        case .paused: return "暫停"
        case .arrived: return "已抵達"
        case .rerouted: return "重新規劃路線"
        case .engineReady: return "導航引擎就緒"
        case .engineNotReady: return "導航引擎未就緒（地圖載入中？）"
        case .locationServicesNotReady: return "HUD 尚未定位"
        case .error: return "錯誤"
        }
    }
}
