using System.Runtime.InteropServices;
using Zonoz.Core;

namespace Zonoz.App;

/// <summary>Windows 專屬的部分：播放期間阻止系統睡眠。</summary>
public sealed class WinPlatform : DesktopPlatform
{
    [Flags]
    private enum ExecutionState : uint
    {
        SystemRequired = 0x00000001,
        Continuous = 0x80000000,
    }

    [DllImport("kernel32.dll")]
    private static extern ExecutionState SetThreadExecutionState(ExecutionState flags);

    private bool _sessionActive;
    private bool _keepAwake = true;
    public event Action? NowPlaying;

    public bool KeepAwake
    {
        get => _keepAwake;
        set { _keepAwake = value; Apply(); }
    }

    public override void PlaybackSessionChanged(bool active)
    {
        _sessionActive = active;
        Apply();
    }

    public override void NowPlayingChanged() => NowPlaying?.Invoke();

    /// <summary>
    /// 電腦一睡眠，HTTP 伺服器就停了，音箱抓不到下一段音樂。
    /// 只在「有播放工作階段」時擋睡眠；螢幕仍可照常關閉。必須在同一條執行緒上設定與清除。
    /// </summary>
    private void Apply()
    {
        try
        {
            SetThreadExecutionState(_sessionActive && _keepAwake
                ? ExecutionState.Continuous | ExecutionState.SystemRequired
                : ExecutionState.Continuous);
        }
        catch (Exception ex)
        {
            LogBus.D($"SetThreadExecutionState 失敗：{ex.Message}");
        }
    }
}
