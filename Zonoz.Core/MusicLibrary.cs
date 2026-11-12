using System.Text.Json;

namespace Zonoz.Core;

public sealed record TagInfo(string Title, string Artist, string Album, int DurationMs, int SampleRate, int Channels);

/// <summary>讀標籤的實作由 App 層提供（用第三方函式庫），核心不綁死任何套件。</summary>
public interface ITagReader
{
    TagInfo? Read(string path);
    byte[]? ReadCover(string path);
}

public enum LibrarySort { Title, Artist, Album, Recent, Folder }

/// <summary>
/// 本地曲庫：遞迴掃描使用者指定的資料夾。標籤讀取結果以「路徑 + 大小 + 修改時間」快取，
/// 第二次啟動不必重讀。
/// </summary>
public sealed class MusicLibrary
{
    private const int CacheVersion = 1;
    private readonly ITagReader? _tagReader;
    private readonly string? _cachePath;

    public MusicLibrary(ITagReader? tagReader, string? cachePath)
    {
        _tagReader = tagReader;
        _cachePath = cachePath;
    }

    private sealed class CacheFile
    {
        public int Version { get; set; }
        public List<Track> Tracks { get; set; } = new();
    }

    /// <summary>掃描（在背景執行緒跑）。progress 回報已處理 / 總數。</summary>
    public Task<List<Track>> ScanAsync(IReadOnlyList<string> folders, LibrarySort sort, IProgress<(int Done, int Total)>? progress = null) =>
        Task.Run(() => Scan(folders, sort, progress));

    private List<Track> Scan(IReadOnlyList<string> folders, LibrarySort sort, IProgress<(int, int)>? progress)
    {
        var cached = new Dictionary<string, Track>(StringComparer.OrdinalIgnoreCase);
        if (_cachePath != null && File.Exists(_cachePath))
        {
            try
            {
                var file = JsonSerializer.Deserialize<CacheFile>(File.ReadAllText(_cachePath));
                if (file is { Version: CacheVersion })
                    foreach (var t in file.Tracks) cached[t.Path] = t;
            }
            catch { /* 快取壞了就整份重掃 */ }
        }

        var files = new List<FileInfo>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.System };
        foreach (var folder in folders)
        {
            if (!Directory.Exists(folder)) continue;
            try
            {
                foreach (var info in new DirectoryInfo(folder).EnumerateFiles("*", options))
                {
                    if (!MimeTypes.IsAudioExtension(info.Extension)) continue;
                    if (seen.Add(info.FullName)) files.Add(info);
                }
            }
            catch (Exception ex)
            {
                LogBus.W($"掃描資料夾失敗：{folder} · {ex.Message}");
            }
        }

        var result = new List<Track>(files.Count);
        var done = 0;
        foreach (var info in files)
        {
            var modified = info.LastWriteTimeUtc.Ticks;
            if (cached.TryGetValue(info.FullName, out var hit) && hit.SizeBytes == info.Length && hit.ModifiedTicks == modified)
                result.Add(hit);
            else
                result.Add(ReadTrack(info, modified));
            done++;
            if (done % 25 == 0) progress?.Report((done, files.Count));
        }
        progress?.Report((files.Count, files.Count));

        var sorted = Sorted(result, sort);
        if (_cachePath != null)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_cachePath)!);
                File.WriteAllText(_cachePath, JsonSerializer.Serialize(new CacheFile { Version = CacheVersion, Tracks = sorted }));
            }
            catch (Exception ex)
            {
                LogBus.W($"曲庫快取寫入失敗：{ex.Message}");
            }
        }
        return sorted;
    }

    private Track ReadTrack(FileInfo info, long modified)
    {
        TagInfo? tag = null;
        try { tag = _tagReader?.Read(info.FullName); }
        catch (Exception ex) { LogBus.D($"讀標籤失敗：{info.Name} · {ex.Message}"); }

        var mime = MimeTypes.Resolve(info.Name);
        var codec = "";
        var atmos = false;
        if (mime == "audio/mp4")
        {
            var mp4 = Mp4Info.Probe(info.FullName);
            if (mp4 != null) { codec = mp4.Codec; atmos = mp4.IsAtmos; }
        }
        var title = string.IsNullOrWhiteSpace(tag?.Title) ? Path.GetFileNameWithoutExtension(info.Name) : tag!.Title.Trim();
        return new Track
        {
            Id = Track.FileIdFor(info.FullName),
            Path = info.FullName,
            Title = title,
            Artist = tag?.Artist.Trim() ?? "",
            Album = tag?.Album.Trim() ?? "",
            DurationMs = tag?.DurationMs ?? 0,
            SizeBytes = info.Length,
            MimeType = mime,
            ModifiedTicks = modified,
            Codec = codec,
            IsAtmos = atmos,
            SampleRate = tag?.SampleRate ?? 0,
            Channels = tag?.Channels ?? 0,
        };
    }

    public static List<Track> Sorted(IEnumerable<Track> tracks, LibrarySort sort)
    {
        var c = StringComparer.CurrentCultureIgnoreCase;
        return sort switch
        {
            LibrarySort.Artist => tracks.OrderBy(t => t.Artist, c).ThenBy(t => t.Album, c).ThenBy(t => t.Path, c).ToList(),
            LibrarySort.Album => tracks.OrderBy(t => t.Album, c).ThenBy(t => t.Path, c).ToList(),
            LibrarySort.Recent => tracks.OrderByDescending(t => t.ModifiedTicks).ToList(),
            LibrarySort.Folder => tracks.OrderBy(t => t.Path, c).ToList(),
            _ => tracks.OrderBy(t => t.Title, c).ThenBy(t => t.Path, c).ToList(),
        };
    }

    public static List<Track> Filter(IEnumerable<Track> tracks, string query)
    {
        var q = query.Trim();
        if (q.Length == 0) return tracks.ToList();
        return tracks.Where(t => t.Title.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                                 || t.Artist.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                                 || t.Album.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                                 || t.FileName.Contains(q, StringComparison.CurrentCultureIgnoreCase)).ToList();
    }
}
