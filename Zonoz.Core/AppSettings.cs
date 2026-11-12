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

    [JsonIgnore] public string? FilePath { get; private set; }

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ZonozLocalStream");

    public static AppSettings Load(string? filePath)
    {
        AppSettings settings = new();
        if (filePath != null && File.Exists(filePath))
        {
            try { settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(filePath)) ?? new AppSettings(); }
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
