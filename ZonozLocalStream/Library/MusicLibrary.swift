import Foundation
import AVFoundation
import CryptoKit
import Combine

/// 快取格式版本：Track 欄位有變就加一，舊快取會被整份重掃
private let libraryCacheVersion = 2

enum LibrarySort: String, CaseIterable, Identifiable {
    case title, artist, album, recent, folder
    var id: String { rawValue }
}

/// 本地曲庫。
///
/// iOS 沒有 Android 那種「掃描整台手機音樂」的權限模型，所以曲庫 = App 的「文件」資料夾：
/// 用「檔案」App（我的 iPhone → ZONOZ）、Windows 的 iTunes / Apple 裝置 App 檔案共享，
/// 或 App 內的「匯入」把音檔放進來。Apple Music 資料庫裡的歌有 DRM / 沙盒限制，無法直接提供給音箱。
@MainActor
final class MusicLibrary: ObservableObject {

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var scanning = false
    @Published var query = ""
    @Published var sort: LibrarySort = .title {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "zonoz.sort"); resort() }
    }
    @Published private(set) var favorites: Set<String> = []
    @Published var importMessage: String? = nil

    /// 掃描完成後通知引擎
    var onChange: (([Track]) -> Void)?

    nonisolated static var documentsURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private nonisolated static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("library-cache.json")
    }

    init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: "zonoz.favorites") ?? [])
        sort = LibrarySort(rawValue: UserDefaults.standard.string(forKey: "zonoz.sort") ?? "") ?? .title
    }

    // MARK: - 檢視

    var visibleTracks: [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return tracks }
        return tracks.filter { track in
            track.title.localizedCaseInsensitiveContains(trimmed)
                || track.artist.localizedCaseInsensitiveContains(trimmed)
                || track.album.localizedCaseInsensitiveContains(trimmed)
                || track.fileName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var favoriteTracks: [Track] {
        return visibleTracks.filter { favorites.contains($0.id) }
    }

    func isFavorite(_ track: Track) -> Bool {
        return favorites.contains(track.id)
    }

    func toggleFavorite(_ track: Track) {
        if favorites.contains(track.id) {
            favorites.remove(track.id)
        } else {
            favorites.insert(track.id)
        }
        UserDefaults.standard.set(Array(favorites), forKey: "zonoz.favorites")
    }

    private func resort() {
        tracks = MusicLibrary.sorted(tracks, by: sort)
    }

    nonisolated static func sorted(_ list: [Track], by sort: LibrarySort) -> [Track] {
        func compare(_ a: String, _ b: String) -> ComparisonResult {
            return a.localizedStandardCompare(b)
        }
        return list.sorted { a, b in
            switch sort {
            case .title:
                return compare(a.title, b.title) == .orderedAscending
            case .artist:
                let r = compare(a.artist, b.artist)
                if r != .orderedSame { return r == .orderedAscending }
                return compare(a.album + a.relPath, b.album + b.relPath) == .orderedAscending
            case .album:
                let r = compare(a.album, b.album)
                if r != .orderedSame { return r == .orderedAscending }
                return compare(a.relPath, b.relPath) == .orderedAscending
            case .recent:
                return a.modified > b.modified
            case .folder:
                return compare(a.relPath, b.relPath) == .orderedAscending
            }
        }
    }

    // MARK: - 掃描

    func scan() {
        if scanning { return }
        scanning = true
        let sort = self.sort
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await MusicLibrary.scanDocuments(sort: sort)
            }.value
            tracks = result
            MediaRegistry.shared.replaceAll(result.map { track in
                ServedFile(
                    fileId: track.id,
                    url: MusicLibrary.documentsURL.appendingPathComponent(track.relPath),
                    displayName: track.title,
                    mimeType: track.mimeType,
                    sizeBytes: track.sizeBytes
                )
            })
            scanning = false
            LogBus.i("曲庫掃描完成：\(result.count) 首")
            onChange?(result)
        }
    }

    /// fileId：對「Documents 內的相對路徑」做 MD5 取前 12 位十六進位。
    /// 只由路徑決定 —— 不能混入時間或容器絕對路徑（重裝 / 更新後會變），
    /// 否則音箱佇列裡的舊 URL 會全部 404。
    nonisolated static func fileId(forRelativePath relPath: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(relPath.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private struct CacheFile: Codable {
        var version: Int
        var tracks: [Track]
    }

    private nonisolated static func scanDocuments(sort: LibrarySort) async -> [Track] {
        let fm = FileManager.default
        let root = documentsURL.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"

        var cached: [String: Track] = [:]
        if let data = try? Data(contentsOf: cacheURL),
           let file = try? JSONDecoder().decode(CacheFile.self, from: data),
           file.version == libraryCacheVersion {
            for track in file.tracks { cached[track.relPath] = track }
        }

        var found: [(url: URL, relPath: String, size: Int64, modified: Double)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            while let item = enumerator.nextObject() as? URL {
                let ext = item.pathExtension.lowercased()
                guard MimeTypes.audioExtensions.contains(ext) else { continue }
                guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let fullPath = item.standardizedFileURL.path
                guard fullPath.hasPrefix(rootPath) else { continue }
                let relPath = String(fullPath.dropFirst(rootPath.count))
                found.append((
                    item, relPath,
                    Int64(values.fileSize ?? 0),
                    values.contentModificationDate?.timeIntervalSince1970 ?? 0
                ))
            }
        }

        var result: [Track] = []
        result.reserveCapacity(found.count)
        for entry in found {
            if let hit = cached[entry.relPath], hit.sizeBytes == entry.size, abs(hit.modified - entry.modified) < 1 {
                result.append(hit)
                continue
            }
            result.append(await readTrack(url: entry.url, relPath: entry.relPath, size: entry.size, modified: entry.modified))
        }

        let sortedResult = sorted(result, by: sort)
        if let data = try? JSONEncoder().encode(CacheFile(version: libraryCacheVersion, tracks: sortedResult)) {
            try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return sortedResult
    }

    /// 用 AVFoundation 讀標籤；它不認得的格式（ogg / wma / 裸 ec3）就退回檔名。
    private nonisolated static func readTrack(url: URL, relPath: String, size: Int64, modified: Double) async -> Track {
        let fileName = url.lastPathComponent
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        var durationMs = 0
        var codec = ""
        var isAtmos = false
        var sampleRate = 0
        var channels = 0

        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds > 0 { durationMs = Int(seconds * 1000) }
        }
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                guard let value = try? await item.load(.stringValue) else { continue }
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                if key == .commonKeyTitle {
                    title = text
                } else if key == .commonKeyArtist {
                    artist = text
                } else if key == .commonKeyAlbumName {
                    album = text
                }
            }
        }
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio), let first = audioTracks.first {
            if let descriptions = try? await first.load(.formatDescriptions), let description = descriptions.first {
                codec = fourCC(CMFormatDescriptionGetMediaSubType(description))
                if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    sampleRate = Int(basic.pointee.mSampleRate)
                    channels = Int(basic.pointee.mChannelsPerFrame)
                }
            }
        }
        if codec == "ec-3" {
            isAtmos = detectAtmos(url: url)
        }

        return Track(
            id: fileId(forRelativePath: relPath),
            relPath: relPath,
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs,
            sizeBytes: size,
            mimeType: MimeTypes.resolve(fileName: fileName),
            modified: modified,
            codec: codec,
            isAtmos: isAtmos,
            sampleRate: sampleRate,
            channels: channels
        )
    }

    private nonisolated static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ]
        let text = String(decoding: bytes, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 走訪 MP4 頂層 box 找到 moov，載入後找 dec3，看有沒有 JOC（Atmos）旗標。
    private nonisolated static func detectAtmos(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 16 else { return false }

        var offset: UInt64 = 0
        var guardCount = 0
        while offset + 8 <= fileSize && guardCount < 64 {
            guardCount += 1
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let headData = try? handle.read(upToCount: 16), headData.count >= 8,
                  let box = Mp4Boxes.parseHeader([UInt8](headData), at: offset, fileSize: fileSize) else { return false }
            if box.type == "moov" {
                let bodySize = box.size - box.headerSize
                if bodySize == 0 || bodySize > 32 * 1024 * 1024 { return false }
                guard (try? handle.seek(toOffset: offset + box.headerSize)) != nil,
                      let body = try? handle.read(upToCount: Int(bodySize)) else { return false }
                guard let payload = Dolby.findDec3(inMoov: [UInt8](body)) else { return false }
                return Dolby.parseDec3(payload: payload)?.isJOC ?? false
            }
            offset += box.size
        }
        return false
    }

    // MARK: - 匯入 / 刪除

    /// 把「檔案」App 選到的音檔 / 資料夾複製進 Documents。
    func importItems(_ urls: [URL]) {
        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                MusicLibrary.copyIntoDocuments(urls)
            }.value
            importMessage = summary
            scan()
        }
    }

    private nonisolated static func copyIntoDocuments(_ urls: [URL]) -> String {
        let fm = FileManager.default
        var copied = 0
        var skipped = 0
        var failed = 0

        func copyFile(_ source: URL, toFolder folder: URL) {
            guard MimeTypes.audioExtensions.contains(source.pathExtension.lowercased()) else {
                skipped += 1
                return
            }
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                skipped += 1
                return
            }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
                copied += 1
            } catch {
                failed += 1
                LogBus.w("匯入失敗：\(source.lastPathComponent) · \(error.localizedDescription)")
            }
        }

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                failed += 1
                continue
            }
            if isDirectory.boolValue {
                let base = documentsURL.appendingPathComponent(url.lastPathComponent)
                let sourceRoot = url.standardizedFileURL.path
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    while let item = enumerator.nextObject() as? URL {
                        guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                        let itemPath = item.standardizedFileURL.deletingLastPathComponent().path
                        var subfolder = ""
                        if itemPath.hasPrefix(sourceRoot) {
                            subfolder = String(itemPath.dropFirst(sourceRoot.count))
                            while subfolder.hasPrefix("/") { subfolder.removeFirst() }
                        }
                        let folder = subfolder.isEmpty ? base : base.appendingPathComponent(subfolder)
                        copyFile(item, toFolder: folder)
                    }
                }
            } else {
                copyFile(url, toFolder: documentsURL)
            }
        }
        return L("已匯入 \(copied) 首，略過 \(skipped)，失敗 \(failed)", "Imported \(copied), skipped \(skipped), failed \(failed)")
    }

    func delete(_ track: Track) {
        let url = MusicLibrary.documentsURL.appendingPathComponent(track.relPath)
        try? FileManager.default.removeItem(at: url)
        favorites.remove(track.id)
        UserDefaults.standard.set(Array(favorites), forKey: "zonoz.favorites")
        tracks.removeAll { $0.id == track.id }
        onChange?(tracks)
    }
}
