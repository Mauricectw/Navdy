using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Zonoz.Core;
using CoreTrack = Zonoz.Core.Track;

namespace Zonoz.App;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }
}

public sealed class DeviceRow : Observable
{
    public required SonosDevice Device { get; init; }
    public string Key => Device.Key;
    public string Name => Device.DisplayName;
    public string Generation => Device.GenerationLabel;
    public bool CanSelect => !Device.IsSatellite;
    private bool _isSelected;
    public bool IsSelected { get => _isSelected; set => Set(ref _isSelected, value); }
    private string _subtitle = "";
    public string Subtitle { get => _subtitle; set => Set(ref _subtitle, value); }
    private string _status = "";
    public string Status { get => _status; set => Set(ref _status, value); }
}

public sealed class TrackRow : Observable
{
    public required CoreTrack Track { get; init; }
    public string Title => Track.Title;
    public string Artist => Track.Artist;
    public string Album => Track.Album;
    public string Badge => Track.FormatBadge;
    public string Duration => Track.DurationLabel;
    public string Folder => Track.Folder;
    private bool _isFavorite;
    public bool IsFavorite { get => _isFavorite; set { if (Set(ref _isFavorite, value)) Raise(nameof(Heart)); } }
    public string Heart => _isFavorite ? "" : "";
    private bool _isCurrent;
    public bool IsCurrent { get => _isCurrent; set => Set(ref _isCurrent, value); }
}

public sealed class QueueRow : Observable
{
    public required CoreTrack Track { get; init; }
    private int _number;
    public int Number { get => _number; set => Set(ref _number, value); }
    public string Title => Track.Title;
    public string Artist => Track.Artist.Length > 0 ? Track.Artist : Track.FileName;
    public string Duration => Track.DurationLabel;
    private bool _isCurrent;
    public bool IsCurrent { get => _isCurrent; set => Set(ref _isCurrent, value); }
}

public sealed class MainViewModel : Observable
{
    public AppSettings Settings { get; }
    public WinPlatform Platform { get; } = new();
    public CastEngine Engine { get; }
    private readonly AtlTagReader _tags = new();
    private readonly MusicLibrary _library;

    public ObservableCollection<DeviceRow> Devices { get; } = new();
    public ObservableCollection<QueueRow> Queue { get; } = new();
    public ObservableCollection<LogEntry> Log { get; } = new();
    public ObservableCollection<string> Folders { get; } = new();
    public string[] SortNames { get; } = { "歌名", "演出者", "專輯", "最近修改", "資料夾" };

    private List<TrackRow> _allRows = new();
    private Dictionary<string, TrackRow> _rowsById = new();
    private IReadOnlyList<TrackRow> _visibleTracks = Array.Empty<TrackRow>();
    public IReadOnlyList<TrackRow> VisibleTracks { get => _visibleTracks; private set => Set(ref _visibleTracks, value); }

    public bool LibraryReady { get; private set; }

    public MainViewModel(AppOptions options)
    {
        var dataDir = options.DataDir;
        Settings = AppSettings.Load(System.IO.Path.Combine(dataDir, "settings.json"));
        foreach (var folder in options.LibraryFolders)
            if (!Settings.LibraryFolders.Contains(folder, StringComparer.OrdinalIgnoreCase)) Settings.LibraryFolders.Add(folder);
        if (Settings.LibraryFolders.Count == 0 && options.SmokeDir == null)
        {
            // 第一次啟動：預設用「音樂」資料夾
            var music = Environment.GetFolderPath(Environment.SpecialFolder.MyMusic);
            if (!string.IsNullOrEmpty(music) && Directory.Exists(music)) Settings.LibraryFolders.Add(music);
        }
        foreach (var folder in Settings.LibraryFolders) Folders.Add(folder);
        _sortIndex = Math.Max(0, Array.IndexOf(Enum.GetNames<LibrarySort>(), Settings.Sort));

        _library = new MusicLibrary(_tags, System.IO.Path.Combine(dataDir, "library-cache.json"));
        Platform.KeepAwake = Settings.KeepAwake;
        Engine = new CastEngine(Platform, Settings);
        Engine.PropertyChanged += OnEngineChanged;
        Platform.Server.StreamRequested += (_, _) => { };
        _manualSpeakers = options.Speakers;
        foreach (var entry in LogBus.Snapshot()) Log.Insert(0, entry);
    }

    private readonly List<string> _manualSpeakers;

    public void Start()
    {
        Engine.Start();
        foreach (var ip in _manualSpeakers) Engine.AddManualDevice(ip);
        _ = ScanLibraryAsync();
        RefreshAll();
    }

    // ---------------- 曲庫 ----------------

    private string _query = "";
    public string Query { get => _query; set { if (Set(ref _query, value)) { Raise(nameof(QueryEmpty)); ApplyFilter(); } } }
    public bool QueryEmpty => _query.Length == 0;

    private int _sortIndex;
    public int SortIndex
    {
        get => _sortIndex;
        set
        {
            if (!Set(ref _sortIndex, value) || value < 0) return;
            Settings.Sort = ((LibrarySort)value).ToString();
            Settings.Save();
            var sorted = MusicLibrary.Sorted(_allRows.Select(r => r.Track), (LibrarySort)value);
            _allRows = sorted.Select(t => _rowsById[t.Id]).ToList();
            ApplyFilter();
        }
    }

    private bool _favoritesOnly;
    public bool FavoritesOnly { get => _favoritesOnly; set { if (Set(ref _favoritesOnly, value)) ApplyFilter(); } }

    private string _libraryStatus = "";
    public string LibraryStatus { get => _libraryStatus; private set => Set(ref _libraryStatus, value); }
    private bool _libraryScanning;
    public bool LibraryScanning { get => _libraryScanning; private set => Set(ref _libraryScanning, value); }
    public bool LibraryEmpty => !_libraryScanning && _allRows.Count == 0;

    public async Task ScanLibraryAsync()
    {
        if (LibraryScanning) return;
        LibraryScanning = true;
        Raise(nameof(LibraryEmpty));
        LibraryStatus = "正在掃描曲庫…";
        try
        {
            var progress = new Progress<(int Done, int Total)>(p => LibraryStatus = $"正在讀取標籤 {p.Done} / {p.Total}");
            var sort = (LibrarySort)Math.Max(0, _sortIndex);
            var tracks = await _library.ScanAsync(Folders.ToList(), sort, progress);
            var favorites = Settings.Favorites.ToHashSet();
            _allRows = tracks.Select(t => new TrackRow { Track = t, IsFavorite = favorites.Contains(t.Id) }).ToList();
            _rowsById = _allRows.ToDictionary(r => r.Track.Id);
            MediaRegistry.Shared.ReplaceAll(tracks);
            Engine.LibraryChanged(tracks);
            LogBus.I($"曲庫掃描完成：{tracks.Count} 首");
        }
        catch (Exception ex)
        {
            LogBus.E($"曲庫掃描失敗：{ex.Message}");
        }
        finally
        {
            LibraryScanning = false;
            LibraryReady = true;
            Raise(nameof(LibraryEmpty));
            ApplyFilter();
            MarkCurrent();
        }
    }

    private void ApplyFilter()
    {
        IEnumerable<TrackRow> rows = _allRows;
        if (_favoritesOnly) rows = rows.Where(r => r.IsFavorite);
        var q = _query.Trim();
        if (q.Length > 0)
        {
            const StringComparison c = StringComparison.CurrentCultureIgnoreCase;
            rows = rows.Where(r => r.Title.Contains(q, c) || r.Artist.Contains(q, c) || r.Album.Contains(q, c) || r.Track.FileName.Contains(q, c));
        }
        VisibleTracks = rows.ToList();
        if (!_libraryScanning)
            LibraryStatus = VisibleTracks.Count == _allRows.Count ? $"{_allRows.Count} 首" : $"{VisibleTracks.Count} / {_allRows.Count} 首";
    }

    public void PlayRow(TrackRow row) => Engine.Play(row.Track, VisibleTracks.Select(r => r.Track).ToList());

    public void ToggleFavorite(TrackRow row)
    {
        row.IsFavorite = !row.IsFavorite;
        Settings.Favorites = _allRows.Where(r => r.IsFavorite).Select(r => r.Track.Id).ToList();
        Settings.Save();
        if (_favoritesOnly) ApplyFilter();
    }

    public void AddFolder(string folder)
    {
        if (Folders.Contains(folder, StringComparer.OrdinalIgnoreCase)) return;
        Folders.Add(folder);
        Settings.LibraryFolders = Folders.ToList();
        Settings.Save();
        _ = ScanLibraryAsync();
    }

    public void RemoveFolder(string folder)
    {
        if (!Folders.Remove(folder)) return;
        Settings.LibraryFolders = Folders.ToList();
        Settings.Save();
        _ = ScanLibraryAsync();
    }

    public bool KeepAwake
    {
        get => Settings.KeepAwake;
        set
        {
            Settings.KeepAwake = value;
            Settings.Save();
            Platform.KeepAwake = value;
            Raise();
        }
    }

    // ---------------- 引擎狀態 → 畫面 ----------------

    private void OnEngineChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(CastEngine.Devices):
            case nameof(CastEngine.SelectedKeys):
            case "DeviceStatus":
                RefreshDevices();
                break;
            case nameof(CastEngine.Queue):
                RefreshQueue();
                break;
            case nameof(CastEngine.QueueIndex):
            case nameof(CastEngine.CurrentTrack):
                MarkCurrent();
                RefreshNowPlaying();
                break;
            case nameof(CastEngine.PositionSec):
            case nameof(CastEngine.DurationSec):
                RefreshPosition();
                break;
            case nameof(CastEngine.Volume):
                if (!VolumeDragging) Raise(nameof(VolumeValue));
                Raise(nameof(VolumeText));
                break;
            case nameof(CastEngine.Hint):
            case nameof(CastEngine.ExternalSource):
            case nameof(CastEngine.ConnectionLost):
                Raise(nameof(HintText));
                Raise(nameof(HasHint));
                break;
            case nameof(CastEngine.LocalIP):
            case nameof(CastEngine.ServerPort):
            case nameof(CastEngine.StreamUrl):
            case nameof(CastEngine.NativeQueueActive):
                Raise(nameof(StreamInfo));
                Raise(nameof(ModeText));
                break;
            case nameof(CastEngine.Scanning):
                Raise(nameof(SpeakerScanning));
                Raise(nameof(SpeakerScanningInverse));
                Raise(nameof(ScanButtonText));
                Raise(nameof(NoSpeakers));
                break;
        }
        if (e.PropertyName is nameof(CastEngine.IsPlaying) or nameof(CastEngine.Busy) or nameof(CastEngine.Shuffle)
            or nameof(CastEngine.RepeatMode) or nameof(CastEngine.HasSession))
        {
            Raise(nameof(PlayGlyph));
            Raise(nameof(IsBusy));
            Raise(nameof(ShuffleOn));
            Raise(nameof(RepeatGlyph));
            Raise(nameof(RepeatOn));
            Raise(nameof(WindowTitle));
        }
    }

    private void RefreshAll()
    {
        RefreshDevices();
        RefreshQueue();
        RefreshNowPlaying();
        RefreshPosition();
        Raise(nameof(StreamInfo));
    }

    public bool SpeakerScanning => Engine.Scanning;
    public bool SpeakerScanningInverse => !Engine.Scanning;
    public string ScanButtonText => Engine.Scanning ? "正在尋找音箱…" : "重新尋找音箱";
    public bool NoSpeakers => Engine.Devices.Count == 0 && !Engine.Scanning;

    private void RefreshDevices()
    {
        var live = Engine.Devices;
        // 清單內容（哪些音箱）變了才重建列，只是狀態變了就原地更新，避免打斷滑鼠操作
        if (live.Count != Devices.Count || live.Where((d, i) => !Equals(Devices[i].Device, d)).Any())
        {
            Devices.Clear();
            foreach (var device in live) Devices.Add(new DeviceRow { Device = device });
        }
        foreach (var row in Devices)
        {
            var device = row.Device;
            row.IsSelected = Engine.IsSelected(device.Key);
            var parts = new List<string> { device.ModelName, device.Ip };
            if (device.IsSatellite) parts.Add("從屬音箱" + (device.ChannelRole.Length > 0 ? $" {device.ChannelRole}" : ""));
            if (Engine.ErrorOf(device.Key) is { } error) parts.Add(error);
            row.Subtitle = string.Join(" · ", parts);
            row.Status = Engine.StatusOf(device.Key) switch
            {
                DeviceStatus.Pushing => "推送中", DeviceStatus.Playing => "播放中", DeviceStatus.Paused => "已暫停",
                DeviceStatus.Error => "錯誤", DeviceStatus.Following => "隨主箱同步", _ => "",
            };
        }
        Raise(nameof(NoSpeakers));
    }

    private void RefreshQueue()
    {
        Queue.Clear();
        var number = 1;
        foreach (var track in Engine.Queue) Queue.Add(new QueueRow { Track = track, Number = number++ });
        MarkCurrent();
        Raise(nameof(QueueHeader));
    }

    public string QueueHeader => $"播放清單（{Engine.Queue.Count}）";

    private string? _markedId;

    private void MarkCurrent()
    {
        var currentId = Engine.CurrentTrack?.Id;
        if (_markedId != null && _rowsById.TryGetValue(_markedId, out var old)) old.IsCurrent = false;
        if (currentId != null && _rowsById.TryGetValue(currentId, out var row)) row.IsCurrent = true;
        _markedId = currentId;
        for (var i = 0; i < Queue.Count; i++) Queue[i].IsCurrent = i == Engine.QueueIndex;
    }

    // ---------------- 播放列 ----------------

    public string NowTitle => Engine.CurrentTrack?.Title ?? "尚未播放";
    public string NowSubtitle
    {
        get
        {
            var t = Engine.CurrentTrack;
            if (t == null) return "在曲庫點兩下一首歌開始播放";
            var parts = new[] { t.Artist, t.Album }.Where(s => s.Length > 0).ToList();
            return parts.Count > 0 ? string.Join(" · ", parts) : t.FileName;
        }
    }
    public string NowBadge
    {
        get
        {
            var t = Engine.CurrentTrack;
            if (t == null) return "";
            var text = t.FormatBadge;
            if (t.SampleRate > 0) text += $" · {t.SampleRate / 1000.0:0.#} kHz";
            if (t.Channels > 0) text += $" · {t.Channels} ch";
            return text;
        }
    }
    public bool HasBadge => NowBadge.Length > 0;
    public string WindowTitle => Engine.CurrentTrack is { } t && Engine.HasSession ? $"{t.Title} — ZONOZ Local Stream" : "ZONOZ Local Stream";

    private ImageSource? _cover;
    public ImageSource? Cover { get => _cover; private set { if (Set(ref _cover, value)) Raise(nameof(HasCover)); } }
    public bool HasCover => _cover != null;
    private string? _coverTrackId;

    private void RefreshNowPlaying()
    {
        Raise(nameof(NowTitle));
        Raise(nameof(NowSubtitle));
        Raise(nameof(NowBadge));
        Raise(nameof(HasBadge));
        Raise(nameof(WindowTitle));
        var track = Engine.CurrentTrack;
        if (track?.Id == _coverTrackId) return;
        _coverTrackId = track?.Id;
        Cover = null;
        if (track != null) _ = LoadCoverAsync(track);
    }

    private async Task LoadCoverAsync(CoreTrack track)
    {
        var image = await Task.Run(() =>
        {
            try
            {
                var data = _tags.ReadCover(track.Path);
                if (data == null || data.Length == 0) return null;
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth = 320;
                bitmap.StreamSource = new MemoryStream(data);
                bitmap.EndInit();
                bitmap.Freeze();
                return (ImageSource)bitmap;
            }
            catch
            {
                return null;
            }
        });
        if (_coverTrackId == track.Id) Cover = image;
    }

    public bool SeekDragging { get; set; }
    public bool VolumeDragging { get; set; }

    private int Duration => Engine.DurationSec > 0 ? Engine.DurationSec : (Engine.CurrentTrack?.DurationMs ?? 0) / 1000;
    public double DurationValue => Math.Max(1, Duration);
    public double PositionValue => Math.Min(Engine.PositionSec, DurationValue);
    public string PositionText => CoreTrack.FormatDuration(Engine.PositionSec);
    public string DurationText => CoreTrack.FormatDuration(Duration);
    public bool CanSeek => Duration > 0 && Engine.HasSession && !Engine.ExternalSource;

    private void RefreshPosition()
    {
        Raise(nameof(DurationValue));
        if (!SeekDragging)
        {
            Raise(nameof(PositionValue));
            Raise(nameof(PositionText));
        }
        Raise(nameof(DurationText));
        Raise(nameof(CanSeek));
    }

    public double VolumeValue => Engine.Volume;
    public string VolumeText => Engine.Volume.ToString();

    public string PlayGlyph => Engine.IsPlaying ? "" : "";
    public bool IsBusy => Engine.Busy;
    public bool ShuffleOn => Engine.Shuffle;
    public bool RepeatOn => !Engine.Shuffle;
    public string RepeatGlyph => Engine.RepeatMode == RepeatMode.One && !Engine.Shuffle ? "" : "";

    public string ModeText => !Engine.HasSession ? "" : Engine.NativeQueueActive ? "音箱佇列" : "逐首推送";

    public string StreamInfo
    {
        get
        {
            var ip = Engine.LocalIP ?? "找不到區網位址";
            var port = Engine.ServerPort > 0 ? Engine.ServerPort.ToString() : "-";
            return $"本機串流位址  http://{ip}:{port}/";
        }
    }

    public bool HasHint => HintText.Length > 0;

    public string HintText
    {
        get
        {
            if (Engine.ExternalSource) return "音箱正在播放其他來源（Sonos App、AirPlay、電視…）。按播放鍵可把控制權拿回來。";
            var hint = Engine.Hint;
            if (hint == null) return Engine.ConnectionLost ? "與音箱失去聯繫，恢復後會自動重新同步。" : "";
            return hint.Kind switch
            {
                HintKind.PickSong => "先在曲庫點兩下一首歌。",
                HintKind.NoDevice => "還沒找到 / 選取音箱。請確認電腦與 Sonos 在同一個區域網路；也可以在左側手動輸入音箱 IP。",
                HintKind.NoNetwork => "這台電腦沒有連上區域網路，無法把音樂提供給音箱。",
                HintKind.ServerFailed => "本地串流伺服器啟動失敗（8080–8089 都被佔用？），請關掉佔用的程式後重開。",
                HintKind.Reach => "音箱連不到這台電腦的串流。請在 Windows 防火牆允許 ZonozLocalStream（私人網路），並確認兩者在同一網段、沒有開 VPN。",
                HintKind.Format => "音箱不接受這個檔案格式。",
                HintKind.BadRequest => "音箱拒絕了這次請求（中繼資料有問題），請把日誌回報給開發者。",
                HintKind.Offline => $"連不上音箱{(hint.Detail.Length > 0 ? $"（{hint.Detail}）" : "")}，請確認它在線上且 IP 正確。",
                HintKind.Satellite => "選到的是配對 / 環繞的從屬音箱，請改選主音箱。",
                HintKind.UnsupportedFormat => $"這個檔案超出 Sonos 規格（{hint.Detail}）：上限 48 kHz，WAV / AIFF 只支援 16 bit。",
                HintKind.MixedGeneration => "同時選了 S1 與 S2 音箱，S1 只能逐首推送。",
                HintKind.ConnectionLost => "與音箱失去聯繫，恢復後會自動重新同步。",
                _ => "播放失敗，詳情請看「日誌」分頁。",
            };
        }
    }

    public void AppendLog(LogEntry entry)
    {
        Log.Insert(0, entry);
        while (Log.Count > 1500) Log.RemoveAt(Log.Count - 1);
    }
}
