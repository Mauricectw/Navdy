using System.Collections.ObjectModel;
using System.Windows.Threading;
using Zonoz.Core;
using CoreTrack = Zonoz.Core.Track;

namespace Zonoz.App;

public enum SourceKind { All, Favorites, Recent, Playlist }

/// <summary>側欄的一列：資料庫來源或一份播放清單。</summary>
public sealed class SourceRow : Observable
{
    public required SourceKind Kind { get; init; }
    public Playlist? Playlist { get; init; }
    public string Glyph { get; init; } = "";
    private string _name = "";
    public string Name { get => _name; set => Set(ref _name, value); }
    private string _count = "";
    public string Count { get => _count; set => Set(ref _count, value); }
    private bool _isEditing;
    public bool IsEditing { get => _isEditing; set { if (Set(ref _isEditing, value)) Raise(nameof(IsNotEditing)); } }
    public bool IsNotEditing => !_isEditing;
    private string _editName = "";
    public string EditName { get => _editName; set => Set(ref _editName, value); }
    /// <summary>設定檔裡記錄「上次停在哪」用的代號</summary>
    public string Token => Kind == SourceKind.Playlist ? $"playlist:{Playlist?.Id}" : Kind.ToString().ToLowerInvariant();
}

public sealed partial class MainViewModel
{
    public PlaylistStore Playlists { get; private set; } = new();
    public ObservableCollection<SourceRow> LibrarySources { get; } = new();
    public ObservableCollection<SourceRow> PlaylistSources { get; } = new();

    private SourceRow _currentSource = new() { Kind = SourceKind.All };
    public SourceRow CurrentSource
    {
        get => _currentSource;
        private set
        {
            if (!Set(ref _currentSource, value)) return;
            Raise(nameof(IsPlaylistSource));
            Raise(nameof(SortEnabled));
            Raise(nameof(SourceTitle));
            Raise(nameof(EmptyText));
        }
    }

    public bool IsPlaylistSource => CurrentSource.Kind == SourceKind.Playlist;
    public bool SortEnabled => CurrentSource.Kind is SourceKind.All or SourceKind.Favorites;
    /// <summary>可以拖曳調整順序：在播放清單裡，而且沒有搜尋條件（否則看到的順序不是完整順序）</summary>
    public bool CanReorder => IsPlaylistSource && _query.Trim().Length == 0;
    public bool NoPlaylists => PlaylistSources.Count == 0;

    private void InitSources()
    {
        LibrarySources.Add(new SourceRow { Kind = SourceKind.All, Name = "歌曲", Glyph = "" });
        LibrarySources.Add(new SourceRow { Kind = SourceKind.Favorites, Name = "收藏", Glyph = "" });
        LibrarySources.Add(new SourceRow { Kind = SourceKind.Recent, Name = "最近播放", Glyph = "" });
        foreach (var playlist in Playlists.Playlists) PlaylistSources.Add(RowFor(playlist));
        var all = LibrarySources.Concat(PlaylistSources);
        _currentSource = all.FirstOrDefault(r => r.Token == Settings.LastSource) ?? LibrarySources[0];
    }

    private static SourceRow RowFor(Playlist playlist) =>
        new() { Kind = SourceKind.Playlist, Playlist = playlist, Name = playlist.Name, Glyph = "" };

    public void SelectSource(SourceRow row)
    {
        if (ReferenceEquals(row, CurrentSource)) return;
        CurrentSource = row;
        Settings.LastSource = row.Token;
        Settings.Save();
        ApplyFilter();
    }

    private void RefreshSourceCounts()
    {
        foreach (var row in LibrarySources)
        {
            row.Count = row.Kind switch
            {
                SourceKind.All => _allRows.Count.ToString(),
                SourceKind.Favorites => _allRows.Count(r => r.IsFavorite).ToString(),
                _ => "",
            };
        }
        foreach (var row in PlaylistSources) row.Count = (row.Playlist?.Paths.Count ?? 0).ToString();
        Raise(nameof(NoPlaylists));
        Raise(nameof(CanReorder));
    }

    // ---------------- 清單上方的標題區 ----------------

    public string SourceTitle => CurrentSource.Name;
    private string _sourceSubtitle = "";
    public string SourceSubtitle { get => _sourceSubtitle; private set => Set(ref _sourceSubtitle, value); }

    public string EmptyText => CurrentSource.Kind switch
    {
        SourceKind.Favorites => "還沒有收藏。在歌曲上按右鍵 →「加入 / 取消收藏」。",
        SourceKind.Recent => "還沒有播放紀錄。",
        SourceKind.Playlist => "這份播放清單是空的。從「歌曲」把歌拖到左邊的清單名稱上，或在歌曲上按右鍵 →「加入播放清單」。",
        _ => "",
    };

    private bool _sourceEmpty;
    /// <summary>目前來源沒有任何曲目（曲庫本身不是空的時才顯示提示）</summary>
    public bool SourceEmpty { get => _sourceEmpty; private set => Set(ref _sourceEmpty, value); }

    private void RefreshSourceHeader(List<TrackRow> all)
    {
        Raise(nameof(SourceTitle));
        var totalSec = all.Sum(r => (long)r.Track.DurationMs) / 1000;
        var parts = new List<string> { $"{all.Count} 首" };
        if (totalSec > 0)
        {
            var hours = totalSec / 3600;
            var minutes = totalSec % 3600 / 60;
            parts.Add(hours > 0 ? $"{hours} 小時 {minutes} 分" : minutes > 0 ? $"{minutes} 分鐘" : $"{totalSec} 秒");
        }
        if (CurrentSource is { Kind: SourceKind.Playlist, Playlist: { } playlist })
        {
            var missing = playlist.Paths.Count - all.Count;
            if (missing > 0 && !LibraryScanning) parts.Add($"{missing} 首找不到檔案");
        }
        SourceSubtitle = string.Join(" · ", parts);
        SourceEmpty = all.Count == 0 && _allRows.Count > 0 && CurrentSource.Kind != SourceKind.All;
    }

    // ---------------- 播放清單編輯 ----------------

    public SourceRow NewPlaylist(IEnumerable<TrackRow>? initial = null, string? name = null, bool edit = true)
    {
        var playlist = Playlists.Create(name, initial?.Select(r => r.Track.Path));
        var row = RowFor(playlist);
        PlaylistSources.Add(row);
        RefreshSourceCounts();
        if (edit) BeginRename(row);
        LogBus.I($"已建立播放清單「{playlist.Name}」");
        return row;
    }

    public void BeginRename(SourceRow row)
    {
        if (row.Playlist == null) return;
        row.EditName = row.Name;
        row.IsEditing = true;
    }

    public void CommitRename(SourceRow row, bool accept)
    {
        if (!row.IsEditing || row.Playlist == null) return;
        row.IsEditing = false;
        if (!accept || row.EditName.Trim() == row.Name) return;
        if (Playlists.Rename(row.Playlist, row.EditName)) row.Name = row.Playlist.Name;
        if (ReferenceEquals(row, CurrentSource)) Raise(nameof(SourceTitle));
    }

    public void DeletePlaylist(SourceRow row)
    {
        if (row.Playlist == null) return;
        Playlists.Delete(row.Playlist);
        PlaylistSources.Remove(row);
        if (ReferenceEquals(row, CurrentSource)) SelectSource(LibrarySources[0]);
        else RefreshSourceCounts();
    }

    public SourceRow DuplicatePlaylist(SourceRow row)
    {
        var copy = RowFor(Playlists.Duplicate(row.Playlist!));
        PlaylistSources.Add(copy);
        RefreshSourceCounts();
        return copy;
    }

    /// <summary>回傳實際加入的數量（已在清單裡的會略過）。</summary>
    public int AddToPlaylist(SourceRow target, IEnumerable<TrackRow> rows)
    {
        if (target.Playlist == null) return 0;
        var list = rows.ToList();
        var added = Playlists.Add(target.Playlist, list.Select(r => r.Track.Path));
        LogBus.I(added == list.Count
            ? $"已把 {added} 首加入「{target.Name}」"
            : $"已把 {added} 首加入「{target.Name}」（{list.Count - added} 首原本就在裡面）");
        if (ReferenceEquals(target, CurrentSource)) ApplyFilter();
        else RefreshSourceCounts();
        return added;
    }

    public void RemoveFromCurrentPlaylist(IEnumerable<TrackRow> rows)
    {
        if (CurrentSource.Playlist is not { } playlist) return;
        if (Playlists.Remove(playlist, rows.Select(r => r.Track.Path).ToList()) > 0) ApplyFilter();
    }

    /// <summary>在目前的播放清單裡把 rows 搬到 before 之前（null = 最後）。</summary>
    public bool MoveInCurrentPlaylist(IReadOnlyList<TrackRow> rows, TrackRow? before)
    {
        if (!CanReorder || CurrentSource.Playlist is not { } playlist) return false;
        if (!Playlists.Move(playlist, rows.Select(r => r.Track.Path).ToList(), before?.Track.Path)) return false;
        ApplyFilter();
        return true;
    }

    public void ExportPlaylist(SourceRow row, string file)
    {
        if (row.Playlist == null) return;
        try
        {
            PlaylistStore.ExportM3u(row.Playlist, file, path => RowForPath(path)?.Track);
            LogBus.I($"已匯出「{row.Name}」→ {file}");
        }
        catch (Exception ex)
        {
            LogBus.E($"匯出失敗：{ex.Message}");
        }
    }

    public SourceRow? ImportPlaylist(string file)
    {
        try
        {
            var playlist = Playlists.Import(file);
            var row = RowFor(playlist);
            PlaylistSources.Add(row);
            RefreshSourceCounts();
            var found = playlist.Paths.Count(p => RowForPath(p) != null);
            LogBus.I($"已匯入「{playlist.Name}」：{playlist.Paths.Count} 首，其中 {found} 首在曲庫裡");
            return row;
        }
        catch (Exception ex)
        {
            LogBus.E($"匯入失敗：{ex.Message}");
            return null;
        }
    }

    /// <summary>播放目前來源：從第一首開始，或隨機挑一首並開啟隨機模式。</summary>
    public void PlaySource(bool shuffle)
    {
        var rows = VisibleTracks;
        if (rows.Count == 0) return;
        if (shuffle != Engine.Shuffle) Engine.ToggleShuffle();
        PlayRow(shuffle ? rows[Random.Shared.Next(rows.Count)] : rows[0]);
    }

    // ---------------- 最近播放 ----------------

    private void NoteRecent(CoreTrack track)
    {
        var recent = Settings.RecentPaths;
        if (recent.Count > 0 && string.Equals(recent[0], track.Path, StringComparison.OrdinalIgnoreCase)) return;
        recent.RemoveAll(p => string.Equals(p, track.Path, StringComparison.OrdinalIgnoreCase));
        recent.Insert(0, track.Path);
        if (recent.Count > 100) recent.RemoveRange(100, recent.Count - 100);
        Settings.Save();
        // 正在看「最近播放」時不即時重排：歌會在眼前跳來跳去，下次切進來再更新
    }

    // ---------------- 搜尋建議 ----------------

    private IReadOnlyList<TrackRow> _suggestions = Array.Empty<TrackRow>();
    /// <summary>打字時即時列出的建議（搜尋整個曲庫，不受目前來源限制）</summary>
    public IReadOnlyList<TrackRow> Suggestions { get => _suggestions; private set => Set(ref _suggestions, value); }

    private void UpdateSuggestions()
    {
        var found = SearchSuggest.Find(_allRows.Select(r => r.Track), _query, 8);
        Suggestions = found.Select(t => _rowsById[t.Id]).ToList();
    }

    /// <summary>選了一筆建議：直接播放。那首歌在目前清單裡就沿用目前清單，否則以整個曲庫為清單。</summary>
    public void PlaySuggestion(TrackRow row)
    {
        NoteRecent(row.Track);
        var context = VisibleTracks.Contains(row) ? VisibleTracks : _allRows;
        Engine.Play(row.Track, context.Select(r => r.Track).ToList());
    }

    // ---------------- 睡眠定時 ----------------

    private DispatcherTimer? _sleepTimer;
    private DateTime? _sleepAt;
    private bool _sleepAfterTrack;
    private string? _sleepTrackId;

    public string SleepText
    {
        get
        {
            if (_sleepAfterTrack) return "播完這首後停止";
            if (_sleepAt is not { } at) return "";
            var left = at - DateTime.Now;
            return left <= TimeSpan.Zero ? "" : $"{(int)left.TotalMinutes}:{left.Seconds:00} 後停止";
        }
    }
    public bool SleepActive => _sleepAfterTrack || _sleepAt != null;

    /// <summary>minutes：0 = 取消；-1 = 播完目前這首後停止；其餘為分鐘數。</summary>
    public void SetSleep(int minutes)
    {
        _sleepAt = null;
        _sleepAfterTrack = false;
        _sleepTrackId = null;
        if (minutes == -1)
        {
            _sleepAfterTrack = true;
            _sleepTrackId = Engine.CurrentTrack?.Id;
            LogBus.I("睡眠定時：播完這首後停止");
        }
        else if (minutes > 0)
        {
            _sleepAt = DateTime.Now.AddMinutes(minutes);
            LogBus.I($"睡眠定時：{minutes} 分鐘後停止");
        }
        if (_sleepAt != null)
        {
            _sleepTimer ??= new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => SleepTick(), Dispatcher.CurrentDispatcher);
            _sleepTimer.Start();
        }
        else _sleepTimer?.Stop();
        Raise(nameof(SleepText));
        Raise(nameof(SleepActive));
    }

    private void SleepTick()
    {
        if (_sleepAt is { } at && DateTime.Now >= at)
        {
            LogBus.I("睡眠定時到了，停止播放");
            SetSleep(0);
            Engine.Stop();
            return;
        }
        Raise(nameof(SleepText));
    }

    private void SleepTrackChanged()
    {
        if (!_sleepAfterTrack || Engine.CurrentTrack?.Id == _sleepTrackId) return;
        LogBus.I("睡眠定時：這首播完了，停止播放");
        SetSleep(0);
        Engine.Stop();
    }
}
