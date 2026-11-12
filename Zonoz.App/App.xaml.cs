using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Zonoz.Core;

namespace Zonoz.App;

public partial class App : Application
{
    /// <summary>命令列選項（主要給自動化冒煙測試用）</summary>
    public static AppOptions Options { get; private set; } = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        Options = AppOptions.Parse(e.Args);
        if (Options.SmokeDir != null)
        {
            Directory.CreateDirectory(Options.SmokeDir);
            LogBus.MirrorFile = System.IO.Path.Combine(Options.SmokeDir, "app.log");
            // 把 XAML 繫結錯誤收集起來：這類錯誤執行時不會跳視窗，只會默默顯示空白
            PresentationTraceSources.Refresh();
            PresentationTraceSources.DataBindingSource.Listeners.Add(new BindingErrorListener());
            PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Warning;
        }
        DispatcherUnhandledException += OnUnhandled;
        base.OnStartup(e);
        new MainWindow().Show();
    }

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        LogBus.E($"未處理的例外：{e.Exception}");
        if (Options.SmokeDir != null)
        {
            File.WriteAllText(System.IO.Path.Combine(Options.SmokeDir, "crash.txt"), e.Exception.ToString());
            Environment.Exit(3);
        }
        e.Handled = true;
        MessageBox.Show(e.Exception.Message, "ZONOZ Local Stream", MessageBoxButton.OK, MessageBoxImage.Warning);
    }
}

public sealed class BindingErrorListener : TraceListener
{
    public static readonly List<string> Errors = new();
    public override void Write(string? message) { }
    public override void WriteLine(string? message)
    {
        if (!string.IsNullOrWhiteSpace(message)) lock (Errors) Errors.Add(message);
    }
}

public sealed class AppOptions
{
    /// <summary>設定檔 / 快取所在資料夾（預設 %AppData%\ZonozLocalStream）</summary>
    public string DataDir { get; private set; } = AppSettings.DefaultDirectory;
    public List<string> LibraryFolders { get; } = new();
    public List<string> Speakers { get; } = new();
    public string? SmokeDir { get; private set; }

    public static AppOptions Parse(string[] args)
    {
        var options = new AppOptions();
        for (var i = 0; i < args.Length; i++)
        {
            string? Next() => i + 1 < args.Length ? args[++i] : null;
            switch (args[i])
            {
                case "--data": if (Next() is { } d) options.DataDir = d; break;
                case "--library": if (Next() is { } l) options.LibraryFolders.Add(l); break;
                case "--speaker": if (Next() is { } s) options.Speakers.Add(s); break;
                case "--smoke": options.SmokeDir = Next(); break;
            }
        }
        return options;
    }
}
