using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Zonoz.Core;

namespace Zonoz.App;

public partial class MainWindow : Window
{
    private readonly MainViewModel _vm;
    private bool _closing;

    public MainWindow()
    {
        InitializeComponent();
        _vm = new MainViewModel(App.Options);
        DataContext = _vm;
        LogBus.Appended += entry => Dispatcher.BeginInvoke(() => _vm.AppendLog(entry));
        Loaded += (_, _) =>
        {
            _vm.Start();
            if (App.Options.SmokeDir != null) _ = RunSmokeAsync(App.Options.SmokeDir);
        };
    }

    // ---------------- 音箱 ----------------

    private void ScanSpeakers_Click(object sender, RoutedEventArgs e) => _vm.Engine.Scan();

    private void AddManual_Click(object sender, RoutedEventArgs e)
    {
        var ip = ManualIpBox.Text.Trim();
        if (ip.Length == 0) return;
        _vm.Engine.AddManualDevice(ip);
        ManualIpBox.Clear();
    }

    private void ManualIpBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) AddManual_Click(sender, e);
    }

    private void ManualIpBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (ManualIpHint != null) ManualIpHint.Visibility = ManualIpBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void DeviceCheck_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is DeviceRow row) _vm.Engine.ToggleSelection(row.Key);
    }

    private void RemoveDevice_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is DeviceRow row) _vm.Engine.RemoveDevice(row.Key);
    }

    // ---------------- 曲庫 ----------------

    private TrackRow? SelectedTrack => TrackList.SelectedItem as TrackRow;

    private void TrackList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        // 點在欄位標題或捲軸上不算
        if (e.OriginalSource is DependencyObject source && FindAncestor<ListViewItem>(source) == null) return;
        if (SelectedTrack is { } row) _vm.PlayRow(row);
    }

    private void TrackList_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && SelectedTrack is { } row)
        {
            _vm.PlayRow(row);
            e.Handled = true;
        }
    }

    private void TrackPlay_Click(object sender, RoutedEventArgs e) { if (SelectedTrack is { } row) _vm.PlayRow(row); }
    private void TrackPlayNext_Click(object sender, RoutedEventArgs e) { if (SelectedTrack is { } row) _vm.Engine.InsertNext(row.Track); }
    private void TrackFavorite_Click(object sender, RoutedEventArgs e) { if (SelectedTrack is { } row) _vm.ToggleFavorite(row); }

    private void TrackReveal_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedTrack is not { } row) return;
        try { Process.Start("explorer.exe", $"/select,\"{row.Track.Path}\""); }
        catch (Exception ex) { LogBus.W($"無法開啟檔案總管：{ex.Message}"); }
    }

    /// <summary>讓「歌名」欄吃掉剩餘寬度（第 2 欄，索引 1）。</summary>
    private void List_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (sender is not ListView { View: GridView grid } list || grid.Columns.Count < 2) return;
        var others = grid.Columns.Where((_, i) => i != 1).Sum(c => double.IsNaN(c.Width) ? c.ActualWidth : c.Width);
        var width = list.ActualWidth - others - 40;
        if (list.ActualWidth > 0) grid.Columns[1].Width = Math.Max(140, width);
    }

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Link : DragDropEffects.None;
        e.Handled = true;
    }

    /// <summary>把資料夾（或檔案）拖進視窗 = 加入曲庫資料夾。</summary>
    private void Window_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        foreach (var path in paths)
        {
            var folder = Directory.Exists(path) ? path : System.IO.Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(folder) && Directory.Exists(folder)) _vm.AddFolder(folder);
        }
    }

    private void Rescan_Click(object sender, RoutedEventArgs e) => _ = _vm.ScanLibraryAsync();

    private void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "選擇放音樂的資料夾", Multiselect = true };
        if (dialog.ShowDialog(this) != true) return;
        foreach (var folder in dialog.FolderNames) _vm.AddFolder(folder);
    }

    private void RemoveFolder_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is string folder) _vm.RemoveFolder(folder);
    }

    // ---------------- 播放清單 ----------------

    private void QueueList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source && FindAncestor<ListViewItem>(source) == null) return;
        QueuePlay_Click(sender, e);
    }

    private void QueuePlay_Click(object sender, RoutedEventArgs e)
    {
        if (QueueList.SelectedIndex >= 0) _vm.Engine.PlayQueueItem(QueueList.SelectedIndex);
    }

    private void QueueRemove_Click(object sender, RoutedEventArgs e)
    {
        if (QueueList.SelectedIndex >= 0) _vm.Engine.RemoveFromQueue(QueueList.SelectedIndex);
    }

    // ---------------- 播放控制 ----------------

    private void PlayPause_Click(object sender, RoutedEventArgs e) => _vm.Engine.TogglePlayPause();
    private void Next_Click(object sender, RoutedEventArgs e) => _vm.Engine.Next();
    private void Previous_Click(object sender, RoutedEventArgs e) => _vm.Engine.Previous();
    private void Stop_Click(object sender, RoutedEventArgs e) => _vm.Engine.Stop();
    private void Shuffle_Click(object sender, RoutedEventArgs e) => _vm.Engine.ToggleShuffle();
    private void Repeat_Click(object sender, RoutedEventArgs e) => _vm.Engine.CycleRepeat();

    private void PositionSlider_Down(object sender, MouseButtonEventArgs e) => _vm.SeekDragging = true;

    private void PositionSlider_Up(object sender, MouseButtonEventArgs e)
    {
        if (!_vm.SeekDragging) return;
        // 等滑桿把這次點擊 / 拖曳的最終值算完再讀
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            _vm.Engine.Seek((int)PositionSlider.Value);
            _vm.SeekDragging = false;
        });
    }

    private void PositionSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_vm is { SeekDragging: true }) PositionLabel.Text = Track.FormatDuration((int)e.NewValue);
    }

    private void VolumeSlider_Down(object sender, MouseButtonEventArgs e) => _vm.VolumeDragging = true;

    private void VolumeSlider_Up(object sender, MouseButtonEventArgs e)
    {
        if (!_vm.VolumeDragging) return;
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            _vm.Engine.SetVolume((int)VolumeSlider.Value);
            _vm.VolumeDragging = false;
        });
    }

    private void VolumeSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_vm is not { VolumeDragging: true }) return;
        VolumeLabel.Text = ((int)e.NewValue).ToString();
        // 拖動時每變 2 格才送一次，避免洗版
        if (Math.Abs((int)e.NewValue - _vm.Engine.Volume) >= 2) _vm.Engine.SetVolume((int)e.NewValue);
    }

    // ---------------- 視窗 ----------------

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        var typing = Keyboard.FocusedElement is TextBox;
        switch (e.Key)
        {
            case Key.MediaPlayPause: _vm.Engine.TogglePlayPause(); e.Handled = true; break;
            case Key.MediaNextTrack: _vm.Engine.Next(); e.Handled = true; break;
            case Key.MediaPreviousTrack: _vm.Engine.Previous(); e.Handled = true; break;
            case Key.MediaStop: _vm.Engine.Stop(); e.Handled = true; break;
            case Key.Space when !typing && Keyboard.FocusedElement is not System.Windows.Controls.Primitives.ButtonBase:
                _vm.Engine.TogglePlayPause();
                e.Handled = true;
                break;
            case Key.F when Keyboard.Modifiers == ModifierKeys.Control:
                Tabs.SelectedIndex = 0;
                SearchBox.Focus();
                SearchBox.SelectAll();
                e.Handled = true;
                break;
        }
    }

    private async void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_closing) return;
        if (_vm.Engine.HasSession)
        {
            // 關掉程式 = HTTP 伺服器消失，音箱遲早會斷；先明確叫它停，避免卡在半首歌
            e.Cancel = true;
            _closing = true;
            try { await Task.WhenAny(_vm.Engine.StopAsync(), Task.Delay(2500)); }
            catch { /* 關閉流程不能被擋住 */ }
            Close();
            return;
        }
        _vm.Engine.Shutdown();
        _vm.Platform.Server.Stop();
    }

    private void CopyLog_Click(object sender, RoutedEventArgs e)
    {
        try { Clipboard.SetText(LogBus.ExportText()); }
        catch (Exception ex) { LogBus.W($"複製失敗：{ex.Message}"); }
    }

    private void ClearLog_Click(object sender, RoutedEventArgs e)
    {
        LogBus.Clear();
        _vm.Log.Clear();
    }

    private static T? FindAncestor<T>(DependencyObject? node) where T : DependencyObject
    {
        while (node != null)
        {
            if (node is T hit) return hit;
            node = node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node);
        }
        return null;
    }

    // ---------------- 自動化冒煙測試（--smoke <資料夾>） ----------------

    private async Task RunSmokeAsync(string dir)
    {
        var ok = false;
        var notes = new List<string>();
        try
        {
            async Task<bool> WaitFor(Func<bool> condition, double seconds)
            {
                var deadline = DateTime.UtcNow.AddSeconds(seconds);
                while (DateTime.UtcNow < deadline)
                {
                    if (condition()) return true;
                    await Task.Delay(200);
                }
                return condition();
            }

            var ready = await WaitFor(() => _vm.LibraryReady && _vm.Engine.Devices.Count > 0 && !_vm.Engine.Scanning, 40);
            notes.Add($"ready={ready}");
            await Settle();
            Screenshot(dir, "1-library");

            var rows = _vm.VisibleTracks;
            var target = rows.FirstOrDefault(r => r.Track.MimeType == "audio/mp4") ?? rows.FirstOrDefault();
            if (target != null)
            {
                TrackList.SelectedItem = target;
                _vm.PlayRow(target);
            }
            var playing = await WaitFor(() => _vm.Engine.IsPlaying && !_vm.Engine.Busy, 25);
            notes.Add($"playing={playing}");
            await Task.Delay(4500);
            await Settle();
            Screenshot(dir, "2-playing");
            for (var tab = 1; tab < Tabs.Items.Count; tab++)
            {
                Tabs.SelectedIndex = tab;
                await Settle();
                Screenshot(dir, $"{tab + 2}-tab{tab}");
            }
            Tabs.SelectedIndex = 0;

            var engine = _vm.Engine;
            var report = new
            {
                tracks = rows.Select(r => new { r.Title, r.Artist, r.Album, r.Duration, r.Badge, r.Track.MimeType, r.Track.Codec, r.Track.SampleRate, r.Track.Channels }).ToList(),
                devices = engine.Devices.Select(d => new { d.DisplayName, d.Ip, d.ModelName, d.SwGen }).ToList(),
                playing,
                nativeQueue = engine.NativeQueueActive,
                current = engine.CurrentTrack?.Title,
                positionSec = engine.PositionSec,
                durationSec = engine.DurationSec,
                hasCover = _vm.HasCover,
                localIp = engine.LocalIP,
                serverPort = engine.ServerPort,
                hint = _vm.HintText,
                windowBackground = Background?.ToString(),
                bindingErrors = BindingErrorListener.Errors.ToList(),
                notes,
            };
            File.WriteAllText(System.IO.Path.Combine(dir, "smoke.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions
            {
                WriteIndented = true,
                Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            }));
            ok = ready && playing && rows.Count > 0 && BindingErrorListener.Errors.Count == 0;
            await engine.StopAsync();
        }
        catch (Exception ex)
        {
            File.WriteAllText(System.IO.Path.Combine(dir, "crash.txt"), ex.ToString());
        }
        _vm.Engine.Shutdown();
        _vm.Platform.Server.Stop();
        Environment.Exit(ok ? 0 : 2);
    }

    private async Task Settle()
    {
        await Task.Delay(400);
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }

    /// <summary>把視窗內容畫成 PNG（不依賴螢幕擷取，沒有實體螢幕的 CI 也能用）。</summary>
    private void Screenshot(string dir, string name)
    {
        if (Content is not FrameworkElement root || root.ActualWidth < 1) return;
        var dpi = VisualTreeHelper.GetDpi(this);
        var width = (int)Math.Ceiling(root.ActualWidth * dpi.DpiScaleX);
        var height = (int)Math.Ceiling(root.ActualHeight * dpi.DpiScaleY);
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            var bounds = new Rect(0, 0, root.ActualWidth, root.ActualHeight);
            // 視窗背景可能是半透明（系統主題材質），先鋪一層不透明底色
            var dark = Application.Current.ThemeMode == ThemeMode.Dark;
            context.DrawRectangle(dark ? new SolidColorBrush(Color.FromRgb(0x20, 0x20, 0x20)) : Brushes.White, null, bounds);
            context.DrawRectangle(new VisualBrush(root) { Stretch = Stretch.None }, null, bounds);
        }
        var bitmap = new RenderTargetBitmap(width, height, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(System.IO.Path.Combine(dir, name + ".png"));
        encoder.Save(stream);
    }
}
