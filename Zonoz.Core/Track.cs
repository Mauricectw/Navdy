using System.Security.Cryptography;
using System.Text;

namespace Zonoz.Core;

/// <summary>
/// 曲庫裡的一首歌。Id 就是 fileId：由檔案完整路徑算出的 12 位十六進位，
/// 只由路徑決定（重開 App 後不變），HTTP 伺服器只暴露它，不洩漏真實路徑。
/// </summary>
public sealed record Track
{
    public string Id { get; init; } = "";
    public string Path { get; init; } = "";
    public string Title { get; init; } = "";
    public string Artist { get; init; } = "";
    public string Album { get; init; } = "";
    public int DurationMs { get; init; }
    public long SizeBytes { get; init; }
    public string MimeType { get; init; } = MimeTypes.DefaultAudio;
    public long ModifiedTicks { get; init; }
    /// <summary>例如 "ec-3"、"alac"、"mp4a"；讀不到為空</summary>
    public string Codec { get; init; } = "";
    /// <summary>MP4 裡的 E-AC-3 帶 JOC 擴充（Dolby Atmos）</summary>
    public bool IsAtmos { get; init; }
    public int SampleRate { get; init; }
    public int Channels { get; init; }

    public string FileName => System.IO.Path.GetFileName(Path);
    public string Folder => System.IO.Path.GetDirectoryName(Path) ?? "";
    public string DurationLabel => DurationMs > 0 ? FormatDuration(DurationMs / 1000) : "";

    public string FormatBadge
    {
        get
        {
            if (IsAtmos) return "Dolby Atmos";
            return Codec switch
            {
                "ec-3" => "E-AC-3", "ac-3" => "AC-3", "alac" => "ALAC", "fLaC" => "FLAC", "mp4a" => "AAC",
                _ => MimeTypes.FileExtension(Path).ToUpperInvariant(),
            };
        }
    }

    public static string FormatDuration(int seconds)
    {
        var s = Math.Max(0, seconds);
        return s >= 3600 ? $"{s / 3600}:{s % 3600 / 60:00}:{s % 60:00}" : $"{s / 60}:{s % 60:00}";
    }

    /// <summary>fileId：對正規化後的完整路徑做 MD5 取前 12 位。不能混入時間，否則音箱佇列裡的舊 URL 會全部 404。</summary>
    public static string FileIdFor(string fullPath)
    {
        var hash = MD5.HashData(Encoding.UTF8.GetBytes(fullPath.ToLowerInvariant()));
        return Convert.ToHexString(hash, 0, 6).ToLowerInvariant();
    }
}

/// <summary>HTTP 伺服器實際要送出的檔案。</summary>
public sealed record ServedFile(string FileId, string Path, string DisplayName, string MimeType, long SizeBytes);

/// <summary>fileId → 檔案 的註冊表（HTTP 伺服器在背景執行緒讀）。</summary>
public sealed class MediaRegistry
{
    public static MediaRegistry Shared { get; } = new();
    private volatile Dictionary<string, ServedFile> _items = new();

    public void ReplaceAll(IEnumerable<Track> tracks)
    {
        var next = new Dictionary<string, ServedFile>();
        foreach (var t in tracks) next[t.Id] = new ServedFile(t.Id, t.Path, t.Title, t.MimeType, t.SizeBytes);
        _items = next;
    }

    public ServedFile? Get(string fileId) => _items.TryGetValue(fileId, out var file) ? file : null;
    public int Count => _items.Count;

    /// <summary>交給 Sonos 的 URL —— 必須是這台電腦在區網中的位址，絕不能是 127.0.0.1</summary>
    public static string StreamUrl(string ip, int port, Track track) =>
        $"http://{ip}:{port}/stream/{track.Id}{MimeTypes.UrlSuffix(track.MimeType)}";

    /// <summary>從音箱回讀的 TrackURI 取出 fileId（…/stream/&lt;id&gt;.&lt;ext&gt;）</summary>
    public static string? FileIdFromStreamUri(string uri)
    {
        var at = uri.IndexOf("/stream/", StringComparison.Ordinal);
        if (at < 0) return null;
        var segment = uri.Substring(at + 8).Split('/')[0];
        var id = segment.Split('.')[0];
        return id.Length == 0 ? null : id;
    }
}
