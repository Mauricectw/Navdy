namespace Zonoz.Core;

public enum LogLevel { Debug, Info, Warn, Error, Tx, Rx }

public sealed record LogEntry(int Id, DateTime Time, LogLevel Level, string Message)
{
    public string LevelMark => Level switch
    {
        LogLevel.Debug => "D", LogLevel.Info => "I", LogLevel.Warn => "W",
        LogLevel.Error => "E", LogLevel.Tx => "→", _ => "←",
    };

    public string Line => $"{Time:HH:mm:ss.fff} {LevelMark} {Message}";
}

/// <summary>App 內的診斷日誌（可檢視 / 複製 / 寫檔）。執行緒安全。</summary>
public static class LogBus
{
    public const int Capacity = 2000;
    private static readonly object Gate = new();
    private static readonly LinkedList<LogEntry> Entries = new();
    private static int _nextId;

    /// <summary>可能在任何執行緒觸發；UI 訂閱時要自己轉回 UI 執行緒。</summary>
    public static event Action<LogEntry>? Appended;
    /// <summary>設定後每一行同時寫進這個檔案（冒煙測試 / 排錯用）</summary>
    public static string? MirrorFile { get; set; }

    public static void Log(LogLevel level, string message)
    {
        LogEntry entry;
        lock (Gate)
        {
            entry = new LogEntry(++_nextId, DateTime.Now, level, message);
            Entries.AddLast(entry);
            while (Entries.Count > Capacity) Entries.RemoveFirst();
            if (MirrorFile != null)
            {
                try { File.AppendAllText(MirrorFile, entry.Line + Environment.NewLine); } catch { /* 日誌不能讓 App 掛掉 */ }
            }
        }
        Appended?.Invoke(entry);
    }

    public static void D(string m) => Log(LogLevel.Debug, m);
    public static void I(string m) => Log(LogLevel.Info, m);
    public static void W(string m) => Log(LogLevel.Warn, m);
    public static void E(string m) => Log(LogLevel.Error, m);

    public static List<LogEntry> Snapshot()
    {
        lock (Gate) return Entries.ToList();
    }

    public static void Clear()
    {
        lock (Gate) Entries.Clear();
    }

    public static string ExportText() => string.Join(Environment.NewLine, Snapshot().Select(e => e.Line));
}
