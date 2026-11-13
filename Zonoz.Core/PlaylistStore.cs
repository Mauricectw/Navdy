using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Zonoz.Core;

/// <summary>一份使用者自訂的播放清單：存的是檔案完整路徑，順序就是播放順序。</summary>
public sealed class Playlist
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "";
    public List<string> Paths { get; set; } = new();
}

/// <summary>
/// 播放清單的儲存與編輯（%AppData%\ZonozLocalStream\playlists.json）。
/// 存路徑而不是 fileId：檔案暫時不在（外接硬碟沒插）時清單不會被清掉，檔案回來就自動恢復。
/// </summary>
public sealed class PlaylistStore
{
    public List<Playlist> Playlists { get; set; } = new();

    [JsonIgnore] public string? FilePath { get; private set; }

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    private static readonly StringComparer PathComparer = StringComparer.OrdinalIgnoreCase;

    public static PlaylistStore Load(string? filePath)
    {
        PlaylistStore store = new();
        if (filePath != null && File.Exists(filePath))
        {
            try { store = JsonSerializer.Deserialize<PlaylistStore>(File.ReadAllText(filePath)) ?? new PlaylistStore(); }
            catch (Exception ex) { LogBus.W($"播放清單讀取失敗：{ex.Message}"); }
        }
        store.FilePath = filePath;
        return store;
    }

    public void Save()
    {
        if (FilePath == null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            // 先寫暫存檔再換名：寫到一半當機也不會把原本的清單毀掉
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Options));
            File.Move(temp, FilePath, true);
        }
        catch (Exception ex)
        {
            LogBus.W($"播放清單寫入失敗：{ex.Message}");
        }
    }

    /// <summary>名稱重複時自動加上「 2」「 3」…</summary>
    public string UniqueName(string baseName, Playlist? except = null)
    {
        var name = baseName.Trim();
        if (name.Length == 0) name = "新播放清單";
        var taken = Playlists.Where(p => p != except).Select(p => p.Name).ToHashSet(StringComparer.CurrentCultureIgnoreCase);
        if (!taken.Contains(name)) return name;
        for (var n = 2; ; n++)
        {
            var candidate = $"{name} {n}";
            if (!taken.Contains(candidate)) return candidate;
        }
    }

    public Playlist Create(string? name = null, IEnumerable<string>? paths = null)
    {
        var playlist = new Playlist { Name = UniqueName(name ?? "新播放清單") };
        Playlists.Add(playlist);
        if (paths != null) Add(playlist, paths, save: false);
        Save();
        return playlist;
    }

    public bool Rename(Playlist playlist, string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return false;
        playlist.Name = UniqueName(name, playlist);
        Save();
        return true;
    }

    public void Delete(Playlist playlist)
    {
        if (Playlists.Remove(playlist)) Save();
    }

    public Playlist Duplicate(Playlist playlist) => Create(playlist.Name + " 副本", playlist.Paths);

    /// <summary>加入曲目（已在清單裡的略過）。回傳實際加入的數量。</summary>
    public int Add(Playlist playlist, IEnumerable<string> paths, bool save = true)
    {
        var existing = playlist.Paths.ToHashSet(PathComparer);
        var added = 0;
        foreach (var path in paths)
        {
            if (string.IsNullOrWhiteSpace(path) || !existing.Add(path)) continue;
            playlist.Paths.Add(path);
            added++;
        }
        if (added > 0 && save) Save();
        return added;
    }

    public int Remove(Playlist playlist, IEnumerable<string> paths)
    {
        var doomed = paths.ToHashSet(PathComparer);
        var removed = playlist.Paths.RemoveAll(doomed.Contains);
        if (removed > 0) Save();
        return removed;
    }

    /// <summary>
    /// 把一批曲目（維持彼此的相對順序）搬到 before 這首之前；before 為 null 表示搬到最後。
    /// </summary>
    public bool Move(Playlist playlist, IReadOnlyList<string> paths, string? before)
    {
        var moving = paths.ToHashSet(PathComparer);
        if (moving.Count == 0) return false;
        if (before != null && moving.Contains(before)) return false;   // 拖到自己身上：不動
        var block = playlist.Paths.Where(moving.Contains).ToList();
        if (block.Count == 0) return false;
        var rest = playlist.Paths.Where(p => !moving.Contains(p)).ToList();
        var index = before == null ? rest.Count : rest.FindIndex(p => PathComparer.Equals(p, before));
        if (index < 0) index = rest.Count;
        rest.InsertRange(index, block);
        if (rest.SequenceEqual(playlist.Paths, PathComparer)) return false;
        playlist.Paths = rest;
        Save();
        return true;
    }

    /// <summary>匯出成 M3U8（UTF-8，絕對路徑），可給其他播放器使用或當備份。</summary>
    public static void ExportM3u(Playlist playlist, string file, Func<string, Track?> lookup)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#EXTM3U");
        sb.AppendLine($"#PLAYLIST:{playlist.Name}");
        foreach (var path in playlist.Paths)
        {
            var track = lookup(path);
            if (track != null)
            {
                var label = track.Artist.Length > 0 ? $"{track.Artist} - {track.Title}" : track.Title;
                sb.AppendLine($"#EXTINF:{Math.Max(0, track.DurationMs / 1000)},{label}");
            }
            sb.AppendLine(path);
        }
        File.WriteAllText(file, sb.ToString(), new UTF8Encoding(true));
    }

    /// <summary>讀 M3U / M3U8：相對路徑以清單檔所在資料夾為準；網址略過。</summary>
    public static (string Name, List<string> Paths) ReadM3u(string file)
    {
        var name = Path.GetFileNameWithoutExtension(file);
        var baseDir = Path.GetDirectoryName(Path.GetFullPath(file)) ?? "";
        var paths = new List<string>();
        foreach (var raw in File.ReadAllLines(file, Encoding.UTF8))
        {
            var line = raw.Trim().Trim('﻿');
            if (line.Length == 0) continue;
            if (line.StartsWith("#PLAYLIST:", StringComparison.OrdinalIgnoreCase))
            {
                var declared = line.Substring(10).Trim();
                if (declared.Length > 0) name = declared;
                continue;
            }
            if (line.StartsWith('#') || line.Contains("://")) continue;
            try
            {
                paths.Add(Path.IsPathRooted(line) ? Path.GetFullPath(line) : Path.GetFullPath(Path.Combine(baseDir, line)));
            }
            catch
            {
                // 路徑含非法字元：略過這一行
            }
        }
        return (name, paths);
    }

    public Playlist Import(string file)
    {
        var (name, paths) = ReadM3u(file);
        return Create(name, paths);
    }
}

/// <summary>搜尋建議：打字時即時列出最相關的幾首歌。</summary>
public static class SearchSuggest
{
    /// <summary>
    /// 排序原則：歌名開頭符合 &gt; 歌名任一個詞開頭符合 &gt; 歌名包含 &gt; 演出者 &gt; 專輯 &gt; 檔名。
    /// 多個關鍵字（空白分隔）必須全部命中。
    /// </summary>
    public static List<Track> Find(IEnumerable<Track> tracks, string query, int limit = 8)
    {
        var terms = query.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (terms.Length == 0) return new List<Track>();
        const StringComparison c = StringComparison.CurrentCultureIgnoreCase;
        var scored = new List<(int Score, Track Track)>();
        foreach (var t in tracks)
        {
            var total = 0;
            var all = true;
            foreach (var term in terms)
            {
                int score;
                if (t.Title.StartsWith(term, c)) score = 100;
                else if (t.Title.Contains(" " + term, c)) score = 80;
                else if (t.Title.Contains(term, c)) score = 60;
                else if (t.Artist.StartsWith(term, c)) score = 50;
                else if (t.Artist.Contains(term, c)) score = 40;
                else if (t.Album.Contains(term, c)) score = 30;
                else if (t.FileName.Contains(term, c)) score = 10;
                else { all = false; break; }
                total += score;
            }
            if (all) scored.Add((total, t));
        }
        return scored.OrderByDescending(s => s.Score)
            .ThenBy(s => s.Track.Title, StringComparer.CurrentCultureIgnoreCase)
            .Take(limit).Select(s => s.Track).ToList();
    }
}
