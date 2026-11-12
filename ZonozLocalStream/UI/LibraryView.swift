import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var engine: CastEngine
    @EnvironmentObject private var library: MusicLibrary
    let openPlayer: () -> Void

    @State private var favoritesOnly = false
    @State private var showImporter = false
    @State private var pendingDelete: Track? = nil

    private var shownTracks: [Track] {
        return favoritesOnly ? library.favoriteTracks : library.visibleTracks
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L("曲庫", "Library"))
                .searchable(text: $library.query, prompt: L("搜尋歌名、演出者、專輯", "Search title, artist, album"))
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            Picker(L("排序", "Sort"), selection: $library.sort) {
                                ForEach(LibrarySort.allCases) { sort in
                                    Text(sort.label).tag(sort)
                                }
                            }
                            Toggle(L("只看收藏", "Favorites only"), isOn: $favoritesOnly)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.circle")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { showImporter = true }) {
                            Image(systemName: "plus")
                        }
                    }
                }
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: [UTType.item, UTType.folder],
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls):
                        library.importItems(urls)
                    case .failure(let error):
                        library.importMessage = error.localizedDescription
                    }
                }
                .alert(
                    L("刪除這首歌？", "Delete this song?"),
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    )
                ) {
                    Button(L("刪除檔案", "Delete file"), role: .destructive) {
                        if let track = pendingDelete { library.delete(track) }
                        pendingDelete = nil
                    }
                    Button(L("取消", "Cancel"), role: .cancel) { pendingDelete = nil }
                } message: {
                    Text(pendingDelete?.fileName ?? "")
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MiniPlayerBar(open: openPlayer)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.tracks.isEmpty {
            emptyState
        } else {
            trackList
        }
    }

    private var trackList: some View {
        List {
            if let hint = engine.hint {
                HintBanner(text: hint.message)
                    .listRowSeparator(.hidden)
            }
            if let message = library.importMessage {
                HintBanner(text: message, systemImage: "tray.and.arrow.down.fill")
                    .listRowSeparator(.hidden)
                    .onTapGesture { library.importMessage = nil }
            }
            Section {
                ForEach(shownTracks) { track in
                    TrackRow(
                        track: track,
                        isCurrent: engine.currentTrack?.id == track.id,
                        isFavorite: library.isFavorite(track)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.play(track, in: shownTracks)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = track
                        } label: {
                            Label(L("刪除", "Delete"), systemImage: "trash")
                        }
                        Button {
                            engine.insertNext(track)
                        } label: {
                            Label(L("下一首播放", "Play next"), systemImage: "text.insert")
                        }
                        .tint(.indigo)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            library.toggleFavorite(track)
                        } label: {
                            Label(L("收藏", "Favorite"), systemImage: library.isFavorite(track) ? "heart.slash" : "heart")
                        }
                        .tint(.pink)
                    }
                }
            } header: {
                Text(L("\(shownTracks.count) 首", "\(shownTracks.count) songs"))
            }
        }
        .listStyle(.plain)
        .refreshable { await library.scan() }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "music.note.house")
                    .font(.system(size: 54))
                    .foregroundColor(.secondary)
                    .padding(.top, 48)
                Text(library.scanning ? L("正在掃描…", "Scanning…") : L("曲庫是空的", "Your library is empty"))
                    .font(.title3.weight(.semibold))
                Text(L(
                    "把音樂檔放進這個 App 的資料夾就會出現在這裡：\n\n• 按右上角「＋」從「檔案」App 匯入檔案或整個資料夾\n• 或在「檔案」App → 我的 iPhone → ZONOZ 直接貼上\n• 或用電腦上的 iTunes / Apple 裝置 App 的「檔案共享」拖進來\n\n支援 MP3、M4A / MP4（含 Dolby Atmos 的 E-AC-3）、FLAC、WAV、AIFF、OGG。",
                    "Put audio files in this app's folder and they show up here:\n\n• Tap + to import files or a whole folder from the Files app\n• Or paste into Files → On My iPhone → ZONOZ\n• Or drag them in with iTunes / Apple Devices file sharing on a computer\n\nSupports MP3, M4A / MP4 (including Dolby Atmos E-AC-3), FLAC, WAV, AIFF, OGG."
                ))
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: { showImporter = true }) {
                    Label(L("匯入音樂", "Import music"), systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: { library.scan() }) {
                    Label(L("重新掃描", "Rescan"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if let message = library.importMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .padding(24)
        }
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverView(track: track, size: 46, corner: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundColor(isCurrent ? .accentColor : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    FormatBadge(track: track)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundColor(.pink)
            }
            Text(track.durationMs > 0 ? track.durationLabel : "")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if !track.album.isEmpty { parts.append(track.album) }
        if parts.isEmpty { parts.append(track.folder.isEmpty ? track.fileName : track.folder) }
        return parts.joined(separator: " · ")
    }
}
