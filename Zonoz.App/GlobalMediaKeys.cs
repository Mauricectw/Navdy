using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Zonoz.Core;

namespace Zonoz.App;

/// <summary>
/// 全域媒體鍵：用 RegisterHotKey 接管 播放/暫停、上一首、下一首、停止。
/// 註冊期間其他播放器收不到這幾個鍵，所以只在「有歌在播」時註冊，停止後立刻釋放。
/// </summary>
public sealed class GlobalMediaKeys : IDisposable
{
    private const int WmHotkey = 0x0312;
    private static readonly (int Id, uint Key)[] Keys =
    {
        (0x5A01, 0xB3),   // VK_MEDIA_PLAY_PAUSE
        (0x5A02, 0xB0),   // VK_MEDIA_NEXT_TRACK
        (0x5A03, 0xB1),   // VK_MEDIA_PREV_TRACK
        (0x5A04, 0xB2),   // VK_MEDIA_STOP
    };

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private readonly HwndSource? _source;
    private readonly Action<int> _onKey;
    private bool _registered;

    /// <summary>onKey 的參數：0 播放/暫停、1 下一首、2 上一首、3 停止</summary>
    public GlobalMediaKeys(Window window, Action<int> onKey)
    {
        _onKey = onKey;
        _source = HwndSource.FromHwnd(new WindowInteropHelper(window).EnsureHandle());
        _source?.AddHook(Hook);
    }

    public bool IsRegistered => _registered;

    public void SetEnabled(bool enabled)
    {
        if (_source == null || enabled == _registered) return;
        if (enabled)
        {
            var ok = 0;
            foreach (var (id, key) in Keys)
                if (RegisterHotKey(_source.Handle, id, 0, key)) ok++;
            _registered = ok > 0;
            LogBus.D(ok == Keys.Length ? "已接管鍵盤媒體鍵" : $"媒體鍵只註冊到 {ok}/{Keys.Length} 個（其餘被別的程式佔用）");
        }
        else
        {
            foreach (var (id, _) in Keys) UnregisterHotKey(_source.Handle, id);
            _registered = false;
            LogBus.D("已釋放鍵盤媒體鍵");
        }
    }

    private IntPtr Hook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != WmHotkey) return IntPtr.Zero;
        var id = wParam.ToInt32();
        for (var i = 0; i < Keys.Length; i++)
        {
            if (Keys[i].Id != id) continue;
            _onKey(i);
            handled = true;
            break;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        SetEnabled(false);
        _source?.RemoveHook(Hook);
    }
}
