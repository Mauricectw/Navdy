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
    private bool _syncingSources;
    private GlobalMediaKeys? _mediaKeys;
    private const string DragFormat = "ZonozTracks";

    public MainWindow()
    {
        InitializeComponent();
        _vm = new MainViewModel(App.Options);
        DataContext = _vm;
        RestorePlacement();
        SyncSourceSelection();
        SuggestBorder.Background = ThemeBrush("SolidBackgroundFillColorBaseBrush", Color.FromRgb(0xFB, 0xFB, 0xFB), Color.FromRgb(0x2B, 0x2B, 0x2B));
        Deactivated += (_, _) => SuggestPopup.IsOpen = false;
        LocationChanged += (_, _) => SuggestPopup.IsOpen = false;
        _vm.SessionChanged += active => _mediaKeys?.SetEnabled(active && _vm.GlobalMediaKeys);
        LogBus.Appended += entry => Dispatcher.BeginInvoke(() => _vm.AppendLog(entry));
        Loaded += (_, _) =>
        {
            _vm.Start();
            _mediaKeys = new GlobalMediaKeys(this, key =>
            {
                switch (key)
                {
                    case 0: _vm.Engine.TogglePlayPause(); break;
                    case 1: _vm.Engine.Next(); break;
                    case 2: _vm.Engine.Previous(); break;
                    default: _vm.Engine.Stop(); break;
                }
            });
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

    /// <summary>目前選取的列，依畫面上的順序。</summary>
    private List<TrackRow> SelectedTracks()
    {
        var selected = TrackList.SelectedItems.OfType<TrackRow>().ToHashSet();
        return selected.Count <= 1 ? selected.ToList() : _vm.VisibleTracks.Where(selected.Contains).ToList();
    }

    private void TrackList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        // 點在欄位標題或捲軸上不算
        if (e.OriginalSource is DependencyObject source && FindAncestor<ListViewItem>(source)?.DataContext is TrackRow row)
            _vm.PlayRow(row);
    }

    private void TrackList_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && SelectedTrack is { } row)
        {
            _vm.PlayRow(row);
            e.Handled = true;
        }
        else if (e.Key == Key.Delete && _vm.IsPlaylistSource)
        {
            _vm.RemoveFromCurrentPlaylist(SelectedTracks());
            e.Handled = true;
        }
    }

    /// <summary>右鍵選單每次開啟時重建：內容取決於選了幾首、目前在哪個來源、有哪些播放清單。</summary>
    private void TrackList_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var rows = SelectedTracks();
        if (rows.Count == 0)
        {
            e.Handled = true;
            return;
        }
        MenuItem Item(string header, Action action, string? gesture = null)
        {
            var item = new MenuItem { Header = header, InputGestureText = gesture ?? "" };
            item.Click += (_, _) => action();
            return item;
        }
        var many = rows.Count > 1 ? $"（{rows.Count} 首）" : "";
        TrackMenu.Items.Clear();
        TrackMenu.Items.Add(Item("播放", () => _vm.PlayRow(rows[0]), "Enter"));
        TrackMenu.Items.Add(Item("下一首播放" + many, () =>
        {
            // 倒著插，插完之後的順序才會和選取順序一致
            foreach (var row in Enumerable.Reverse(rows.Take(25))) _vm.Engine.InsertNext(row.Track);
        }));

        var add = new MenuItem { Header = "加入播放清單" + many };
        add.Items.Add(Item("新增播放清單…", () => SelectAndRename(_vm.NewPlaylist(rows, edit: false))));
        if (_vm.PlaylistSources.Count > 0) add.Items.Add(new Separator());
        foreach (var playlist in _vm.PlaylistSources)
        {
            var target = playlist;
            var entry = Item(target.Name, () => _vm.AddToPlaylist(target, rows));
            entry.IsEnabled = !ReferenceEquals(target, _vm.CurrentSource);
            add.Items.Add(entry);
        }
        TrackMenu.Items.Add(add);
        if (_vm.IsPlaylistSource)
            TrackMenu.Items.Add(Item("從這份播放清單移除" + many, () => _vm.RemoveFromCurrentPlaylist(rows), "Del"));
        TrackMenu.Items.Add(Item("加入 / 取消收藏" + many, () => { foreach (var row in rows) _vm.ToggleFavorite(row); }));
        TrackMenu.Items.Add(new Separator());
        TrackMenu.Items.Add(Item("在檔案總管中顯示", () => Reveal(rows[0])));
    }

    private static void Reveal(TrackRow row)
    {
        try { Process.Start("explorer.exe", $"/select,\"{row.Track.Path}\""); }
        catch (Exception ex) { LogBus.W($"無法開啟檔案總管：{ex.Message}"); }
    }

    // ---- 拖曳：歌曲 → 側欄的播放清單；在播放清單內拖曳調整順序 ----

    private Point? _dragStart;
    private TrackRow? _deferredSelect;
    private List<TrackRow> _dragRows = new();

    private void TrackList_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        _deferredSelect = null;
        var item = e.OriginalSource is DependencyObject source ? FindAncestor<ListViewItem>(source) : null;
        if (item == null)
        {
            _dragStart = null;
            return;
        }
        _dragStart = e.GetPosition(null);
        // 在「已多選」的其中一列按下：先不要讓 ListView 把選取縮成一列，否則沒辦法一次拖多首
        if (item.IsSelected && TrackList.SelectedItems.Count > 1 && Keyboard.Modifiers == ModifierKeys.None && e.ClickCount == 1)
        {
            _deferredSelect = item.DataContext as TrackRow;
            TrackList.Focus();
            e.Handled = true;
        }
    }

    private void TrackList_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (_dragStart is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
        var now = e.GetPosition(null);
        if (Math.Abs(now.X - start.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(now.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        var rows = SelectedTracks();
        _dragStart = null;
        _deferredSelect = null;
        if (rows.Count == 0) return;
        _dragRows = rows;
        try { DragDrop.DoDragDrop(TrackList, new DataObject(DragFormat, "1"), DragDropEffects.Copy | DragDropEffects.Move); }
        finally
        {
            _dragRows = new List<TrackRow>();
            ClearDropHighlight();
        }
    }

    private void TrackList_PreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_deferredSelect is { } row)
        {
            TrackList.SelectedItems.Clear();
            TrackList.SelectedItem = row;
        }
        _dragStart = null;
        _deferredSelect = null;
    }

    private void TrackList_DragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DragFormat)) return;   // 外部檔案交給視窗層處理
        e.Effects = _vm.CanReorder ? DragDropEffects.Move : DragDropEffects.None;
        e.Handled = true;
    }

    private void TrackList_Drop(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DragFormat)) return;
        e.Handled = true;
        if (!_vm.CanReorder || _dragRows.Count == 0) return;
        var moved = _dragRows.ToList();
        var target = e.OriginalSource is DependencyObject source ? FindAncestor<ListViewItem>(source)?.DataContext as TrackRow : null;
        if (!_vm.MoveInCurrentPlaylist(moved, target)) return;
        TrackList.SelectedItems.Clear();
        foreach (var row in moved) TrackList.SelectedItems.Add(row);
    }

    private ListBoxItem? _dropHighlight;

    private void ClearDropHighlight()
    {
        if (_dropHighlight != null) _dropHighlight.Tag = null;
        _dropHighlight = null;
    }

    private void PlaylistList_DragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DragFormat)) return;
        var item = e.OriginalSource is DependencyObject source ? FindAncestor<ListBoxItem>(source) : null;
        if (!ReferenceEquals(item, _dropHighlight))
        {
            ClearDropHighlight();
            if (item != null) item.Tag = "drop";
            _dropHighlight = item;
        }
        // 放在某份清單上 = 加入那份清單；放在空白處 = 用這些歌建立新清單
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
    }

    private void PlaylistList_DragLeave(object sender, DragEventArgs e) => ClearDropHighlight();

    private void PlaylistList_Drop(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DragFormat)) return;
        e.Handled = true;
        var target = _dropHighlight?.DataContext as SourceRow;
        ClearDropHighlight();
        var rows = _dragRows.ToList();
        if (rows.Count == 0) return;
        if (target != null) _vm.AddToPlaylist(target, rows);
        else SelectAndRename(_vm.NewPlaylist(rows, edit: false));
    }

    // ---------------- 側欄：來源與播放清單 ----------------

    private void SyncSourceSelection()
    {
        _syncingSources = true;
        var current = _vm.CurrentSource;
        LibrarySourceList.SelectedItem = current.Kind == SourceKind.Playlist ? null : current;
        PlaylistSourceList.SelectedItem = current.Kind == SourceKind.Playlist ? current : null;
        _syncingSources = false;
    }

    private void SourceList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSources || e.AddedItems.Count == 0 || e.AddedItems[0] is not SourceRow row) return;
        _vm.SelectSource(row);
        SyncSourceSelection();
        TrackList.SelectedItems.Clear();
        if (_vm.VisibleTracks.Count > 0) TrackList.ScrollIntoView(_vm.VisibleTracks[0]);
    }

    private SourceRow? SelectedPlaylist => PlaylistSourceList.SelectedItem as SourceRow;

    private void SelectAndRename(SourceRow row)
    {
        Tabs.SelectedIndex = 0;
        PlaylistSourceList.SelectedItem = row;
        PlaylistSourceList.ScrollIntoView(row);
        // 等這一列真的產生出來再進入編輯，輸入框才拿得到焦點
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => _vm.BeginRename(row));
    }

    private void AddPlaylistMenu_Click(object sender, RoutedEventArgs e)
    {
        if (AddPlaylistButton.ContextMenu is not { } menu) return;
        menu.PlacementTarget = AddPlaylistButton;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    private void NewPlaylist_Click(object sender, RoutedEventArgs e) => SelectAndRename(_vm.NewPlaylist(edit: false));

    private void ImportPlaylist_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = "匯入播放清單", Filter = "M3U 播放清單|*.m3u8;*.m3u|所有檔案|*.*", Multiselect = true };
        if (dialog.ShowDialog(this) != true) return;
        SourceRow? last = null;
        foreach (var file in dialog.FileNames) last = _vm.ImportPlaylist(file) ?? last;
        if (last != null) PlaylistSourceList.SelectedItem = last;
    }

    private void PlaylistPlay_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedPlaylist != null) _vm.PlaySource(false);
    }

    private void PlaylistRename_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedPlaylist is { } row) _vm.BeginRename(row);
    }

    private void PlaylistDuplicate_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedPlaylist is { } row) PlaylistSourceList.SelectedItem = _vm.DuplicatePlaylist(row);
    }

    private void PlaylistExport_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedPlaylist is not { } row) return;
        var safeName = string.Concat(row.Name.Select(ch => System.IO.Path.GetInvalidFileNameChars().Contains(ch) ? '_' : ch));
        var dialog = new Microsoft.Win32.SaveFileDialog { Title = "匯出播放清單", Filter = "M3U8 播放清單|*.m3u8", FileName = safeName + ".m3u8" };
        if (dialog.ShowDialog(this) == true) _vm.ExportPlaylist(row, dialog.FileName);
    }

    private void PlaylistDelete_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedPlaylist is not { } row) return;
        var answer = MessageBox.Show(this, $"確定要刪除播放清單「{row.Name}」嗎？\n\n只會刪除清單本身，音樂檔案不受影響。", "刪除播放清單",
            MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer != MessageBoxResult.OK) return;
        _vm.DeletePlaylist(row);
        SyncSourceSelection();
    }

    private void PlaylistList_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.OriginalSource is TextBox) return;   // 正在改名：按鍵留給輸入框
        if (e.Key == Key.F2) PlaylistRename_Click(sender, e);
        else if (e.Key == Key.Delete) PlaylistDelete_Click(sender, e);
        else if (e.Key == Key.Enter) PlaylistPlay_Click(sender, e);
        else return;
        e.Handled = true;
    }

    private void PlaylistList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is TextBox) return;
        if (e.OriginalSource is DependencyObject source && FindAncestor<ListBoxItem>(source) != null) _vm.PlaySource(false);
    }

    private void RenameBox_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (sender is not TextBox { IsVisible: true } box) return;
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            box.Focus();
            box.SelectAll();
        });
    }

    private void RenameBox_KeyDown(object sender, KeyEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not SourceRow row) return;
        if (e.Key == Key.Enter) _vm.CommitRename(row, true);
        else if (e.Key == Key.Escape) _vm.CommitRename(row, false);
        else return;
        e.Handled = true;
        PlaylistSourceList.Focus();
    }

    private void RenameBox_LostFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is SourceRow row) _vm.CommitRename(row, true);
    }

    private void PlaySource_Click(object sender, RoutedEventArgs e) => _vm.PlaySource(false);
    private void ShuffleSource_Click(object sender, RoutedEventArgs e) => _vm.PlaySource(true);

    // ---------------- 搜尋建議 ----------------

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        // Suggestions 是在 Query 的 setter 裡算的；等繫結把文字推過去之後再決定要不要開
        Dispatcher.BeginInvoke(DispatcherPriority.DataBind, () =>
        {
            SuggestList.SelectedIndex = -1;
            SuggestPopup.IsOpen = SearchBox.IsKeyboardFocused && _vm.Suggestions.Count > 0;
        });
    }

    private void SearchBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        var count = _vm.Suggestions.Count;
        switch (e.Key)
        {
            case Key.Down when count > 0:
                SuggestPopup.IsOpen = true;
                SuggestList.SelectedIndex = Math.Min(count - 1, SuggestList.SelectedIndex + 1);
                e.Handled = true;
                break;
            case Key.Up when SuggestPopup.IsOpen:
                SuggestList.SelectedIndex = Math.Max(-1, SuggestList.SelectedIndex - 1);
                e.Handled = true;
                break;
            case Key.Enter when SuggestPopup.IsOpen && count > 0:
                ChooseSuggestion(_vm.Suggestions[Math.Max(0, SuggestList.SelectedIndex)]);
                e.Handled = true;
                break;
            case Key.Escape:
                if (SuggestPopup.IsOpen) SuggestPopup.IsOpen = false;
                else SearchBox.Clear();
                e.Handled = true;
                break;
        }
    }

    private void SearchBox_LostFocus(object sender, KeyboardFocusChangedEventArgs e) => SuggestPopup.IsOpen = false;

    /// <summary>用「按下」而不是「放開」：按下的瞬間搜尋框會失焦並關掉建議，等到放開就來不及了。</summary>
    private void SuggestList_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source && FindAncestor<ListBoxItem>(source)?.DataContext is TrackRow row)
        {
            e.Handled = true;
            ChooseSuggestion(row);
        }
    }

    private void ChooseSuggestion(TrackRow row)
    {
        SuggestPopup.IsOpen = false;
        _vm.PlaySuggestion(row);
        if (_vm.VisibleTracks.Contains(row))
        {
            TrackList.SelectedItems.Clear();
            TrackList.SelectedItem = row;
            TrackList.ScrollIntoView(row);
        }
    }

    /// <summary>取主題色；主題沒有這個資源時，依文字顏色判斷深淺再給備用色。</summary>
    private static Brush ThemeBrush(string key, Color light, Color dark)
    {
        if (Application.Current.TryFindResource(key) is SolidColorBrush { Color.A: 255 } themed) return themed;
        var isDark = Application.Current.ThemeMode == ThemeMode.Dark
                     || (Application.Current.TryFindResource("TextFillColorPrimaryBrush") is SolidColorBrush text
                         && text.Color.R + text.Color.G + text.Color.B > 384);
        return new SolidColorBrush(isDark ? dark : light);
    }

    // ---------------- 睡眠定時 ----------------

    private void SleepMenu_Click(object sender, RoutedEventArgs e)
    {
        if (SleepButton.ContextMenu is not { } menu) return;
        menu.PlacementTarget = SleepButton;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Top;
        menu.IsOpen = true;
    }

    private void Sleep_Click(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem { Tag: string tag } && int.TryParse(tag, out var minutes)) _vm.SetSleep(minutes);
    }

    // ---------------- 視窗位置 ----------------

    private void RestorePlacement()
    {
        if (App.Options.SmokeDir != null) return;
        var s = _vm.Settings;
        if (s.WindowWidth >= MinWidth && s.WindowHeight >= MinHeight)
        {
            Width = s.WindowWidth;
            Height = s.WindowHeight;
        }
        // 上次的位置還在某個螢幕範圍內才套用（螢幕配置可能變了）
        var screen = new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop,
            SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
        if (!double.IsNaN(s.WindowLeft) && !double.IsNaN(s.WindowTop)
            && screen.Contains(new Point(s.WindowLeft + 60, s.WindowTop + 20)))
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = s.WindowLeft;
            Top = s.WindowTop;
        }
        if (s.WindowMaximized) WindowState = WindowState.Maximized;
    }

    private void SavePlacement()
    {
        if (App.Options.SmokeDir != null) return;
        var s = _vm.Settings;
        s.WindowMaximized = WindowState == WindowState.Maximized;
        var bounds = WindowState == WindowState.Normal ? new Rect(Left, Top, Width, Height) : RestoreBounds;
        if (!bounds.IsEmpty && bounds.Width >= MinWidth)
        {
            s.WindowLeft = bounds.Left;
            s.WindowTop = bounds.Top;
            s.WindowWidth = bounds.Width;
            s.WindowHeight = bounds.Height;
        }
        s.Save();
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
            case Key.N when Keyboard.Modifiers == ModifierKeys.Control:
                NewPlaylist_Click(sender, e);
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
        SavePlacement();
        _mediaKeys?.Dispose();
        _mediaKeys = null;
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

            var libraryRows = _vm.VisibleTracks;

            // 播放清單：用前 4 首（倒序）建立一份，切過去
            var playlistRow = _vm.NewPlaylist(libraryRows.Take(4).Reverse().ToList(), "測試歌單", edit: false);
            _vm.NewPlaylist(name: "通勤", edit: false);
            PlaylistSourceList.SelectedItem = playlistRow;
            await Settle();
            Screenshot(dir, "1b-playlist");
            var playlistView = _vm.VisibleTracks.Select(r => $"{r.Number}. {r.Title}").ToList();
            var moved = _vm.MoveInCurrentPlaylist(new[] { _vm.VisibleTracks[^1] }, _vm.VisibleTracks[0]);
            var afterMove = _vm.VisibleTracks.Select(r => $"{r.Number}. {r.Title}").ToList();

            // 搜尋建議
            Activate();
            SearchBox.Focus();
            SearchBox.Text = "te";
            await Settle();
            var suggestOpenedByTyping = SuggestPopup.IsOpen;
            var suggestions = _vm.Suggestions.Select(r => $"{r.Title} | {r.Subtitle}").ToList();
            SuggestPopup.IsOpen = suggestions.Count > 0;
            SuggestList.SelectedIndex = 0;
            await Settle();
            Screenshot(dir, "1c-suggest", SuggestBorder);
            SuggestPopup.IsOpen = false;
            SearchBox.Text = "";
            await Settle();

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
                tracks = libraryRows.Select(r => new { r.Title, r.Artist, r.Album, r.Duration, r.Badge, r.Track.MimeType, r.Track.Codec, r.Track.SampleRate, r.Track.Channels }).ToList(),
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
                sourceTitle = _vm.SourceTitle,
                sourceSubtitle = _vm.SourceSubtitle,
                playlistView,
                moved,
                afterMove,
                suggestOpenedByTyping,
                suggestions,
                playlistsOnDisk = PlaylistStore.Load(System.IO.Path.Combine(App.Options.DataDir, "playlists.json")).Playlists.Select(p => $"{p.Name}:{p.Paths.Count}").ToList(),
                recent = _vm.Settings.RecentPaths.Select(System.IO.Path.GetFileName).ToList(),
                mediaKeysRegistered = _mediaKeys?.IsRegistered,
                bindingErrors = BindingErrorListener.Errors.ToList(),
                notes,
            };
            File.WriteAllText(System.IO.Path.Combine(dir, "smoke.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions
            {
                WriteIndented = true,
                Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            }));
            ok = ready && playing && rows.Count == 4 && moved && suggestions.Count > 0 && BindingErrorListener.Errors.Count == 0;
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
    private void Screenshot(string dir, string name, FrameworkElement? element = null)
    {
        var root = element ?? Content as FrameworkElement;
        if (root == null || root.ActualWidth < 1) return;
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
