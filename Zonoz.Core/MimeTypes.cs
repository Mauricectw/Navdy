namespace Zonoz.Core;

/// <summary>
/// MIME 正規化。Sonos 對 Content-Type 很挑：錯的類型直接回 714，
/// 所以 HTTP 伺服器與 DIDL 的 protocolInfo 必須用同一個值。
/// </summary>
public static class MimeTypes
{
    public const string DefaultAudio = "audio/mpeg";

    private static readonly Dictionary<string, string> ExtToMime = new(StringComparer.OrdinalIgnoreCase)
    {
        ["mp3"] = "audio/mpeg", ["mp2"] = "audio/mpeg",
        ["m4a"] = "audio/mp4", ["m4b"] = "audio/mp4", ["mp4"] = "audio/mp4",
        ["aac"] = "audio/aac", ["flac"] = "audio/flac",
        ["wav"] = "audio/wav", ["wave"] = "audio/wav",
        ["aif"] = "audio/aiff", ["aiff"] = "audio/aiff",
        ["ogg"] = "audio/ogg", ["oga"] = "audio/ogg", ["opus"] = "audio/ogg",
        ["wma"] = "audio/x-ms-wma",
        // 以下為移植版新增的實驗性對應（原版 Android 沒有）：裸 Dolby 位元流
        ["ec3"] = "audio/eac3", ["eac3"] = "audio/eac3", ["ac3"] = "audio/ac3",
    };

    private static readonly HashSet<string> SonosSupported = new()
    {
        "audio/mpeg", "audio/mp4", "audio/flac", "audio/wav", "audio/aiff", "audio/ogg", "audio/x-ms-wma", "audio/aac",
    };

    public static bool IsAudioExtension(string ext) => ExtToMime.ContainsKey(ext.TrimStart('.'));

    public static string FileExtension(string fileName)
    {
        var dot = fileName.LastIndexOf('.');
        return dot < 0 ? "" : fileName.Substring(dot + 1).ToLowerInvariant();
    }

    public static string Resolve(string fileName) =>
        ExtToMime.TryGetValue(FileExtension(fileName), out var mime) ? mime : DefaultAudio;

    /// <summary>為 URL 產生副檔名（含前導點）。URL 的副檔名與 MIME 一致能幫助音箱判斷格式。</summary>
    public static string UrlSuffix(string mime) => mime switch
    {
        "audio/mpeg" => ".mp3", "audio/mp4" => ".m4a", "audio/aac" => ".aac", "audio/flac" => ".flac",
        "audio/wav" => ".wav", "audio/aiff" => ".aiff", "audio/ogg" => ".ogg", "audio/x-ms-wma" => ".wma",
        "audio/eac3" => ".ec3", "audio/ac3" => ".ac3", _ => "",
    };

    public static bool IsSonosSupported(string mime) => SonosSupported.Contains(mime);
}
