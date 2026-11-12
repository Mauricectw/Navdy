import SwiftUI
import UIKit

enum AppTab: Hashable {
    case library, player, settings
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var engine: CastEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .library

    var body: some View {
        TabView(selection: $tab) {
            LibraryView(openPlayer: { tab = .player })
                .tabItem { Label(L("曲庫", "Library"), systemImage: "music.note.list") }
                .tag(AppTab.library)
            PlayerView()
                .tabItem { Label(L("播放", "Now Playing"), systemImage: "hifispeaker.fill") }
                .tag(AppTab.player)
            SettingsView()
                .tabItem { Label(L("設定", "Settings"), systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.becameActive() }
        }
    }
}

/// 曲目封面（內嵌圖片，沒有就顯示音符）
struct CoverView: View {
    let track: Track?
    var size: CGFloat
    var corner: CGFloat = 8
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.gray.opacity(0.18))
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: track?.id ?? "") {
            guard let track = track else {
                image = nil
                return
            }
            image = CoverLoader.shared.cached(track)
            if image == nil {
                image = await CoverLoader.shared.load(track)
            }
        }
    }
}

/// 格式徽章（Dolby Atmos / FLAC / …）
struct FormatBadge: View {
    let track: Track

    var body: some View {
        let text = track.formatBadge
        if !text.isEmpty {
            Text(text)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(track.isAtmos ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.18))
                .clipShape(Capsule())
        }
    }
}

/// 提示橫幅
struct HintBanner: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(.orange)
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// 曲庫底部的迷你播放列
struct MiniPlayerBar: View {
    @EnvironmentObject private var engine: CastEngine
    let open: () -> Void

    var body: some View {
        if let track = engine.currentTrack {
            HStack(spacing: 12) {
                CoverView(track: track, size: 40, corner: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? track.fileName : track.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if engine.busy {
                    ProgressView()
                }
                Button(action: { engine.togglePlayPause() }) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                Button(action: { engine.next() }) {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 36, height: 40)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .contentShape(Rectangle())
            .onTapGesture { open() }
        }
    }
}
