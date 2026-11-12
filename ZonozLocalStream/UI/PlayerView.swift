import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var engine: CastEngine
    @State private var dragging = false
    @State private var dragValue: Double = 0
    @State private var volumeDragging = false
    @State private var volumeValue: Double = 30
    @State private var showQueue = false

    private var duration: Int {
        if engine.durationSec > 0 { return engine.durationSec }
        return (engine.currentTrack?.durationMs ?? 0) / 1000
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if engine.externalSource {
                        HintBanner(
                            text: L("音箱正在播放其他來源（Sonos App、AirPlay、電視…）。按播放鍵可把控制權拿回來。",
                                    "The speaker is playing another source (Sonos app, AirPlay, TV…). Press play to take it back."),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    if let hint = engine.hint {
                        HintBanner(text: hint.message)
                    }
                    artwork
                    titles
                    progress
                    transport
                    volume
                    speakers
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .navigationTitle(L("播放", "Now Playing"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showQueue = true }) {
                        Image(systemName: "list.bullet")
                    }
                    .disabled(engine.queue.isEmpty)
                }
            }
            .sheet(isPresented: $showQueue) {
                QueueView()
            }
        }
    }

    private var artwork: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, 340)
            CoverView(track: engine.currentTrack, size: side, corner: 18)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 340)
    }

    private var titles: some View {
        VStack(spacing: 6) {
            Text(engine.currentTrack?.title ?? L("尚未播放", "Nothing playing"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let track = engine.currentTrack {
                Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    FormatBadge(track: track)
                    if track.sampleRate > 0 {
                        Text(sampleRateText(track))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(engine.nativeQueueActive ? L("音箱佇列", "Speaker queue") : L("逐首推送", "Single cast"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func sampleRateText(_ track: Track) -> String {
        let khz = Double(track.sampleRate) / 1000.0
        let rate = track.sampleRate % 1000 == 0 ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
        return track.channels > 0 ? "\(rate) · \(track.channels) ch" : rate
    }

    private var progress: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { dragging ? dragValue : Double(min(engine.positionSec, max(duration, 1))) },
                    set: { dragValue = $0 }
                ),
                in: 0...Double(max(duration, 1)),
                onEditingChanged: { editing in
                    if editing {
                        dragValue = Double(engine.positionSec)
                        dragging = true
                    } else {
                        engine.seek(to: Int(dragValue))
                        dragging = false
                    }
                }
            )
            .disabled(duration <= 0 || !engine.hasSession || engine.externalSource)
            HStack {
                Text(Track.formatDuration(seconds: dragging ? Int(dragValue) : engine.positionSec))
                Spacer()
                Text(Track.formatDuration(seconds: duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    private var transport: some View {
        HStack {
            Button(action: { engine.toggleShuffle() }) {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundColor(engine.shuffle ? .accentColor : .secondary)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button(action: { engine.previous() }) {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(width: 54, height: 54)
            }
            Spacer()
            Button(action: { engine.togglePlayPause() }) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 72, height: 72)
                    if engine.busy {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                }
            }
            Spacer()
            Button(action: { engine.next() }) {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(width: 54, height: 54)
            }
            Spacer()
            Button(action: { engine.cycleRepeat() }) {
                Image(systemName: engine.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundColor(engine.shuffle ? .secondary : .accentColor)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .foregroundColor(.secondary)
            Slider(
                value: Binding(
                    get: { volumeDragging ? volumeValue : Double(engine.volume) },
                    set: { newValue in
                        volumeValue = newValue
                        // 拖動時每變 2 格才送一次，避免洗版
                        if abs(Int(newValue) - engine.volume) >= 2 { engine.setVolume(Int(newValue)) }
                    }
                ),
                in: 0...100,
                onEditingChanged: { editing in
                    if editing {
                        volumeValue = Double(engine.volume)
                        volumeDragging = true
                    } else {
                        engine.setVolume(Int(volumeValue))
                        volumeDragging = false
                    }
                }
            )
            Image(systemName: "speaker.wave.3.fill")
                .foregroundColor(.secondary)
            Text("\(volumeDragging ? Int(volumeValue) : engine.volume)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var speakers: some View {
        VStack(alignment: .leading, spacing: 8) {
            let selected = engine.selectedDevices()
            if selected.isEmpty {
                Text(L("尚未選取音箱 —— 到「設定」分頁選一台。", "No speaker selected — pick one in Settings."))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(selected) { device in
                HStack(spacing: 8) {
                    Image(systemName: "hifispeaker")
                        .foregroundColor(.secondary)
                    Text(device.displayName)
                        .font(.footnote.weight(.medium))
                    Text(device.modelName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text((engine.deviceStatus[device.key] ?? .idle).label)
                        .font(.caption2)
                        .foregroundColor(engine.deviceStatus[device.key] == .error ? .red : .secondary)
                }
            }
            if engine.connectionLost {
                Text(L("與音箱失去聯繫，正在等待恢復…", "Lost contact with the speaker, waiting…"))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct QueueView: View {
    @EnvironmentObject private var engine: CastEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(engine.queue.enumerated()), id: \.element.id) { index, track in
                        QueueRow(
                            index: index,
                            track: track,
                            isCurrent: index == engine.queueIndex,
                            isPlaying: engine.isPlaying
                        )
                        .id(track.id)
                        .contentShape(Rectangle())
                        .onTapGesture { engine.playQueueItem(at: index) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if index != engine.queueIndex {
                                Button(role: .destructive) {
                                    engine.removeFromQueue(at: index)
                                } label: {
                                    Label(L("移出清單", "Remove"), systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    if let current = engine.currentTrack { proxy.scrollTo(current.id, anchor: .center) }
                }
            }
            .navigationTitle(L("播放清單（\(engine.queue.count)）", "Queue (\(engine.queue.count))"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("完成", "Done")) { dismiss() }
                }
            }
        }
    }
}

struct QueueRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .foregroundColor(.accentColor)
                    .frame(width: 26)
            } else {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Text(track.artist.isEmpty ? track.fileName : track.artist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(track.durationMs > 0 ? track.durationLabel : "")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}
