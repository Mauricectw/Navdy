using System.Text.Json;
using System.Text.Json.Serialization;

namespace Zonoz.Core;

/// <summary>使用者設定（%AppData%\ZonozLocalStream\settings.json）。</summary>
public sealed class AppSettings
{
    public List<string> SelectedKeys { get; set; } = new();
    public List<string> KnownIPs { get; set; } = new();
    public bool Shuffle { get; set; }
    public string RepeatMode { get; set; } = "all";
    public List<string> LibraryFolders { get; set; } = new();
    public List<string> Favorites { get; set; } = new();
    public string Sort { get; set; } = "title";
    /// <summary>播放期間阻止電腦進入睡眠（睡眠後音箱就抓不到音樂了）</summary>
    public bool KeepAwake { get; set; } = true;
    /// <summary>播放期間接管鍵盤的媒體鍵（視窗不在前景也有效）</summary>
    public bool GlobalMediaKeys { get; set; } = true;
    /// <summary>最近播放過的檔案路徑，最新的在前</summary>
    public List<string> RecentPaths { get; set; } = new();
    /// <summary>上次停留的來源：all / favorites / recent / playlist:&lt;id&gt;</summary>
    public string LastSource { get; set; } = "all";
    public double WindowLeft { get; set; } = double.NaN;
    public double WindowTop { get; set; } = double.NaN;
    public double WindowWidth { get; set; }
    public double WindowHeight { get; set; }
    public bool WindowMaximized { get; set; }

    [JsonIgnore] public string? FilePath { get; private set; }

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
    };

    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ZonozLocalStream");

    public static AppSettings Load(string? filePath)
    {
        AppSettings settings = new();
        if (filePath != null && File.Exists(filePath))
        {
            try { settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(filePath), Options) ?? new AppSettings(); }
            catch (Exception ex) { LogBus.W($"設定檔讀取失敗，改用預設值：{ex.Message}"); }
        }
        settings.FilePath = filePath;
        return settings;
    }

    public void Save()
    {
        if (FilePath == null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Options));
        }
        catch (Exception ex)
        {
            LogBus.W($"設定檔寫入失敗：{ex.Message}");
        }
    }
}
