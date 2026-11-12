using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Zonoz.Core;

public enum DeviceStatus { Idle, Pushing, Playing, Paused, Error, Following }

public enum RepeatMode { All, One }

public enum HintKind
{
    PickSong, NoDevice, NoNetwork, ServerFailed,
    Reach, Format, BadRequest, Offline, Satellite, Unknown,
    UnsupportedFormat, MixedGeneration, ConnectionLost,
}

public sealed record Hint(HintKind Kind, string Detail = "");

/// <summary>
/// 播放引擎 —— 對應 Android 版的 SonosCastService + AppState。
///
/// 把整份播放清單塞進「音箱自己的佇列」（AddMultipleURIsToQueue → x-rincon-queue），切歌由音箱執行，
/// 電腦只負責觀察；佇列路徑任何一步自檢不過，就退回逐首推 URL（SetAVTransportURI + Play）。
///
/// 執行緒模型：所有公開方法與狀態都只在建立它的那條執行緒（UI 執行緒）上使用；
/// await 之後靠 SynchronizationContext 回到同一條執行緒，所以內部不需要鎖。
/// </summary>
public sealed class CastEngine : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Raise(name);
    }

    // ---- 對 UI 公開的狀態 ----

    private IReadOnlyList<SonosDevice> _devices = Array.Empty<SonosDevice>();
    public IReadOnlyList<SonosDevice> Devices { get => _devices; private set { _devices = value; Raise(); } }

    private readonly HashSet<string> _selectedKeys = new();
    public IReadOnlyCollection<string> SelectedKeys => _selectedKeys;

    private readonly Dictionary<string, DeviceStatus> _deviceStatus = new();
    private readonly Dictionary<string, string> _deviceError = new();
    public DeviceStatus StatusOf(string key) => _deviceStatus.TryGetValue(key, out var s) ? s : DeviceStatus.Idle;
    public string? ErrorOf(string key) => _deviceError.TryGetValue(key, out var e) ? e : null;

    private bool _scanning;
    public bool Scanning { get => _scanning; private set => Set(ref _scanning, value); }
    private bool _busy;
    public bool Busy { get => _busy; private set => Set(ref _busy, value); }

    private IReadOnlyList<Track> _queue = Array.Empty<Track>();
    public IReadOnlyList<Track> Queue { get => _queue; private set { _queue = value; Raise(); Raise(nameof(CurrentTrack)); } }
    private int _queueIndex = -1;
    public int QueueIndex { get => _queueIndex; private set { if (_queueIndex != value) { _queueIndex = value; Raise(); Raise(nameof(CurrentTrack)); } } }

    private bool _shuffle;
    public bool Shuffle { get => _shuffle; private set => Set(ref _shuffle, value); }
    private RepeatMode _repeatMode = RepeatMode.All;
    public RepeatMode RepeatMode { get => _repeatMode; private set => Set(ref _repeatMode, value); }
    private int _positionSec;
    public int PositionSec { get => _positionSec; private set => Set(ref _positionSec, value); }
    private int _durationSec;
    public int DurationSec { get => _durationSec; private set => Set(ref _durationSec, value); }
    private int _volume = 30;
    public int Volume { get => _volume; private set => Set(ref _volume, value); }
    private Hint? _hint;
    public Hint? Hint { get => _hint; private set => Set(ref _hint, value); }
    private bool _externalSource;
    /// <summary>音箱正在播別的來源（Sonos App、AirPlay…），ZONOZ 不搶</summary>
    public bool ExternalSource { get => _externalSource; private set { if (_externalSource != value) { _externalSource = value; Raise(); Raise(nameof(IsPlaying)); } } }
    private bool _connectionLost;
    public bool ConnectionLost { get => _connectionLost; private set { if (_connectionLost != value) { _connectionLost = value; Raise(); Raise(nameof(IsPlaying)); } } }
    private string? _localIP;
    public string? LocalIP { get => _localIP; private set => Set(ref _localIP, value); }
    private int _serverPort;
    public int ServerPort { get => _serverPort; private set => Set(ref _serverPort, value); }
    private string? _streamUrl;
    public string? StreamUrl { get => _streamUrl; private set => Set(ref _streamUrl, value); }
    private bool _nativeQueueActive;
    /// <summary>目前是否走音箱原生佇列（false = 逐首推送）</summary>
    public bool NativeQueueActive { get => _nativeQueueActive; private set => Set(ref _nativeQueueActive, value); }

    /// <summary>完整曲庫，用於重建清單與恢復狀態</summary>
    public IReadOnlyList<Track> Library { get; private set; } = Array.Empty<Track>();

    public Track? CurrentTrack => _queueIndex >= 0 && _queueIndex < _queue.Count ? _queue[_queueIndex] : null;
    public bool IsPlaying => !_connectionLost && !_externalSource && _deviceStatus.Values.Contains(DeviceStatus.Playing);
    public bool HasSession => _deviceStatus.Values.Any(s => s is DeviceStatus.Playing or DeviceStatus.Paused or DeviceStatus.Pushing);

    // ---- 內部狀態 ----

    public SonosSoapClient Soap { get; } = new();
    private readonly DeviceProber _prober = new(2.5);
    private readonly IEnginePlatform _platform;
    private readonly AppSettings _settings;

    private List<Track> _queueSource = new();
    private string _sonosQueueSignature = "";
    private int _lastQueueTrack;
    private string? _lastTransportState;
    private double _castAt;
    private int _castDurationMs;
    private double _castSettledAt;
    private int _earlyStopRetries;
    private double _lastAdvanceAt = -1000;
    private double _lastVolumeSetAt = -1000;
    private double _lastUrlHealAt = -1000;
    private double _lastAuditRebuildAt = -1000;
    private int _soapFailStreak;
    private int _pausedAtSec;
    private (int ResumeAtSec, bool AutoPlay)? _pendingCast;
    private int? _pendingSeekSec;
    private bool _pollKick;
    private bool _sessionActive;
    private bool _started;
    private CancellationTokenSource? _pollCts;

    private const int QueueChunkSize = 12;
    private const double QueueSettle = 1.5;
    private const double EarlyStopTolerance = 20.0;
    private const int MaxEarlyStopRetries = 2;
    private const double AutoAdvanceDebounce = 10.0;
    private const double VolumeSyncGuard = 3.0;
    private const double AuditRebuildCooldown = 60.0;

    public CastEngine(IEnginePlatform platform, AppSettings settings)
    {
        _platform = platform;
        _settings = settings;
        _shuffle = settings.Shuffle;
        _repeatMode = settings.RepeatMode == "one" && !settings.Shuffle ? RepeatMode.One : RepeatMode.All;
        foreach (var key in settings.SelectedKeys) _selectedKeys.Add(key);
    }

    // ---- 小工具 ----

    /// <summary>射後不理的非同步工作：例外只寫日誌，不讓 App 掛掉。</summary>
    private async void Run(Func<Task> work)
    {
        try { await work(); }
        catch (Exception ex) { LogBus.E($"內部錯誤：{ex.GetType().Name} · {ex.Message}"); }
    }

    public List<SonosDevice> SelectedDevices() => _devices.Where(d => _selectedKeys.Contains(d.Key)).ToList();
    public List<SonosDevice> Coordinators() => _devices.Where(d => !d.IsSatellite).ToList();

    private List<SonosDevice> ControlTargets()
    {
        var active = _devices.Where(d => StatusOf(d.Key) is DeviceStatus.Playing or DeviceStatus.Paused or DeviceStatus.Pushing).ToList();
        return (active.Count > 0 ? active : SelectedDevices()).Where(d => !d.IsSatellite).ToList();
    }

    private void SetStatus(string key, DeviceStatus status, string? error = null)
    {
        _deviceStatus[key] = status;
        if (error != null) _deviceError[key] = error; else _deviceError.Remove(key);
        StatusChanged();
    }

    private void StatusChanged()
    {
        Raise("DeviceStatus");
        Raise(nameof(IsPlaying));
        Raise(nameof(HasSession));
        var active = HasSession;
        if (active != _sessionActive)
        {
            _sessionActive = active;
            _platform.PlaybackSessionChanged(active);
        }
    }

    private void NotifyNowPlaying() => _platform.NowPlayingChanged();

    private SonosDevice? PrimaryTarget() => SelectedDevices().FirstOrDefault(d => !d.IsSatellite) ?? Coordinators().FirstOrDefault();

    // ---- 啟動 / 探索 ----

    /// <summary>App 啟動時呼叫一次：起 HTTP 伺服器、找音箱、恢復狀態、開始輪詢。</summary>
    public void Start()
    {
        if (_started) return;
        _started = true;
        Run(async () =>
        {
            await PrepareServer(false);
            await ScanInternal();
            if (_devices.Count > 0) await RestorePlaybackState();
            StartPolling();
        });
    }

    public void Shutdown()
    {
        _pollCts?.Cancel();
        _pollCts = null;
    }

    public void Scan() => Run(ScanInternal);

    private async Task<bool> PrepareServer(bool force)
    {
        var ip = _platform.CurrentLanIP(PrimaryTarget());
        if (ip != LocalIP) LocalIP = ip;
        if (ip == null)
        {
            Hint = new Hint(HintKind.NoNetwork);
            LogBus.W("找不到區網的 IPv4 位址，無法提供串流");
            return false;
        }
        var port = await _platform.EnsureServerAsync(force);
        if (port == null)
        {
            Hint = new Hint(HintKind.ServerFailed);
            LogBus.E("本地 HTTP 伺服器啟動失敗");
            return false;
        }
        if (port.Value != ServerPort) ServerPort = port.Value;
        return true;
    }

    private async Task ScanInternal()
    {
        if (Scanning) return;
        Scanning = true;
        try
        {
            LogBus.I("開始尋找音箱（SSDP）…");
            var found = await _platform.DiscoverAsync();

            // 上次見過的 IP 也直接敲一次（SSDP 被擋、音箱在別的網段時的保險）
            var foundIps = found.Select(d => d.Ip).ToHashSet();
            foreach (var known in _settings.KnownIPs.Where(ip => !foundIps.Contains(ip)).ToList())
            {
                var device = await _prober.Probe(known, DiscoverySource.Manual);
                if (device != null) found.Add(device);
            }

            if (found.Count == 0)
            {
                if (_devices.Count == 0) Hint = new Hint(HintKind.NoDevice);
                LogBus.W("未發現音箱（可手動輸入 IP）");
                return;
            }
            UpsertDevices(found);
            if (Hint?.Kind == HintKind.NoDevice) Hint = null;
            LogBus.I($"發現 {found.Count} 台：" + string.Join("、", found.Select(d => $"{d.DisplayName}({d.Ip})")));
            await RefreshTopology(found);
            ApplyDefaultSelection();
            var ip = _platform.CurrentLanIP(PrimaryTarget());
            if (ip != null && ip != LocalIP) LocalIP = ip;
        }
        finally
        {
            Scanning = false;
        }
    }

    public void AddManualDevice(string rawIp)
    {
        var ip = rawIp.Trim();
        if (!NetUtils.IsValidIPv4(ip))
        {
            Hint = new Hint(HintKind.Offline, ip);
            return;
        }
        Run(async () =>
        {
            LogBus.I($"手動探測音箱：{ip}");
            var device = await _prober.Probe(ip, DiscoverySource.Manual);
            if (device == null)
            {
                Hint = new Hint(HintKind.Offline, ip);
                LogBus.E($"手動新增失敗：{ip}");
                return;
            }
            UpsertDevices(new List<SonosDevice> { device });
            await RefreshTopology(new List<SonosDevice> { device });
            var live = _devices.FirstOrDefault(d => d.Key == device.Key);
            if (live is { IsSatellite: false })
            {
                _selectedKeys.Add(live.Key);
                PersistSelection();
            }
            Hint = null;
            LogBus.I($"已新增：{device.DisplayName} · {device.ModelName} · {device.Ip}");
        });
    }

    public void RemoveDevice(string key)
    {
        Devices = _devices.Where(d => d.Key != key).ToList();
        _selectedKeys.Remove(key);
        _deviceStatus.Remove(key);
        _deviceError.Remove(key);
        PersistSelection();
        PersistKnownIPs();
        StatusChanged();
    }

    public void ToggleSelection(string key)
    {
        if (!_selectedKeys.Remove(key)) _selectedKeys.Add(key);
        PersistSelection();
        KickPoll();
    }

    public bool IsSelected(string key) => _selectedKeys.Contains(key);

    private void UpsertDevices(List<SonosDevice> found)
    {
        var list = _devices.ToList();
        foreach (var device in found)
        {
            var i = list.FindIndex(d => d.Key == device.Key);
            if (i >= 0)
            {
                // 保留已知的拓撲資訊
                list[i] = device with
                {
                    IsSatellite = list[i].IsSatellite,
                    ChannelRole = list[i].ChannelRole,
                    SwGen = device.SwGen == 0 ? list[i].SwGen : device.SwGen,
                };
            }
            else list.Add(device);
        }
        Devices = list.OrderBy(d => d.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList();
        PersistKnownIPs();
    }

    private void ApplyDefaultSelection()
    {
        var live = _devices.Select(d => d.Key).ToHashSet();
        if (_selectedKeys.Any(live.Contains)) return;
        // 沒有可用的既有選擇：預設選第一台主箱
        var first = Coordinators().FirstOrDefault();
        if (first == null) return;
        _selectedKeys.Clear();
        _selectedKeys.Add(first.Key);
        PersistSelection();
    }

    private void PersistSelection()
    {
        _settings.SelectedKeys = _selectedKeys.ToList();
        _settings.Save();
        Raise(nameof(SelectedKeys));
    }

    private void PersistKnownIPs()
    {
        _settings.KnownIPs = _devices.Select(d => d.Ip).ToList();
        _settings.Save();
    }

    private async Task RefreshTopology(List<SonosDevice> targets)
    {
        var probe = targets.FirstOrDefault();
        if (probe == null) return;
        var body = await Soap.GetZoneGroupState(probe);
        if (body == null)
        {
            LogBus.D("GetZoneGroupState 無回應，略過拓撲識別");
            return;
        }
        var nodes = ZoneTopology.Parse(body);
        if (nodes.Count == 0)
        {
            LogBus.D("拓撲解析為空，略過（推送時用 1023 兜底）");
            return;
        }
        var byUuid = new Dictionary<string, ZoneTopology.Node>();
        foreach (var node in nodes) byUuid[node.Uuid] = node;
        Devices = _devices.Select(d => byUuid.TryGetValue(d.Uuid, out var node)
            ? d with
            {
                IsSatellite = node.IsSatellite,
                ChannelRole = node.Channel,
                SwGen = node.SwGen > 0 ? node.SwGen : d.SwGen,
                SoftwareVersion = node.SoftwareVersion.Length > 0 ? node.SoftwareVersion : d.SoftwareVersion,
            }
            : d).ToList();
        LogBus.I("區域組拓撲：" + string.Join("、", nodes.Select(n =>
            $"{(n.Uuid.Length > 8 ? n.Uuid[^8..] : n.Uuid)}:{(n.IsSatellite ? "從" : "主")}{n.Channel}")));
    }

    // ---- 播放清單 ----

    /// <summary>使用者在某個清單點了一首歌：以該清單為來源建立播放清單並開始播放。</summary>
    public void Play(Track track, IReadOnlyList<Track> source)
    {
        StartQueue(source.Count == 0 ? new List<Track> { track } : source, track);
        CastCurrent();
    }

    private void StartQueue(IReadOnlyList<Track> source, Track current)
    {
        _queueSource = source.ToList();
        var ordered = OrderFor(_queueSource, current);
        Queue = ordered;
        QueueIndex = Math.Max(0, ordered.FindIndex(t => t.Id == current.Id));
        Raise(nameof(CurrentTrack));
    }

    private List<Track> OrderFor(List<Track> source, Track? current)
    {
        if (current == null || !Shuffle) return source.ToList();
        var rest = source.Where(t => t.Id != current.Id).ToList();
        for (var i = rest.Count - 1; i > 0; i--)
        {
            var j = Random.Shared.Next(i + 1);
            (rest[i], rest[j]) = (rest[j], rest[i]);
        }
        rest.Insert(0, current);
        return rest;
    }

    private void ReorderQueue()
    {
        var current = CurrentTrack;
        if (current == null) return;
        var source = _queueSource.Count == 0 ? _queue.ToList() : _queueSource;
        var ordered = OrderFor(source, current);
        Queue = ordered;
        QueueIndex = Math.Max(0, ordered.FindIndex(t => t.Id == current.Id));
        Raise(nameof(CurrentTrack));
    }

    private Track? Step(int offset)
    {
        if (_queue.Count == 0) return null;
        var size = _queue.Count;
        QueueIndex = ((_queueIndex + offset) % size + size) % size;
        return _queue[_queueIndex];
    }

    /// <summary>清單沒建立時用曲庫兜底，避免「上一首/下一首」點了沒反應</summary>
    private void EnsureQueueReady()
    {
        if (_queue.Count > 0 || Library.Count == 0) return;
        StartQueue(Library, Library[0]);
        LogBus.D($"播放清單缺失，已按曲庫重建（{Library.Count} 首）");
    }

    public void PlayQueueItem(int index)
    {
        if (index < 0 || index >= _queue.Count) return;
        QueueIndex = index;
        CastCurrent();
    }

    /// <summary>「下一首播放」：把曲目插到目前這首後面。</summary>
    public void InsertNext(Track track)
    {
        if (_queue.Count == 0)
        {
            Play(track, new List<Track> { track });
            return;
        }
        var list = _queue.ToList();
        var currentIdx = Math.Clamp(_queueIndex, 0, list.Count - 1);
        if (list[currentIdx].Id == track.Id) return;
        var existing = list.FindIndex(t => t.Id == track.Id);
        if (existing == currentIdx + 1) return;
        if (existing >= 0)
        {
            list.RemoveAt(existing);
            // 被移走的在目前曲之前 → 目前曲前移一位，下標必須跟著修正，否則之後按序號定位會跳歌
            if (existing < currentIdx) currentIdx--;
        }
        list.Insert(Math.Min(currentIdx + 1, list.Count), track);
        Queue = list;
        QueueIndex = currentIdx;
        if (_queueSource.All(t => t.Id != track.Id)) _queueSource.Add(track);
        SyncSpeakerQueue(track, existing >= 0);
    }

    public void RemoveFromQueue(int index)
    {
        if (index < 0 || index >= _queue.Count || index == _queueIndex) return;
        var removed = _queue[index];
        var list = _queue.ToList();
        list.RemoveAt(index);
        var newIndex = index < _queueIndex ? _queueIndex - 1 : _queueIndex;
        Queue = list;
        QueueIndex = newIndex;
        _queueSource.RemoveAll(t => t.Id == removed.Id);
        RecastIfQueueActive("移除曲目");
    }

    /// <summary>曲庫重新掃描後：把清單裡已不存在的曲目拿掉。</summary>
    public void LibraryChanged(IReadOnlyList<Track> tracks)
    {
        Library = tracks;
        if (_queue.Count > 0)
        {
            var alive = tracks.Select(t => t.Id).ToHashSet();
            var currentId = CurrentTrack?.Id;
            var filtered = _queue.Where(t => alive.Contains(t.Id)).ToList();
            if (filtered.Count != _queue.Count)
            {
                _queueSource = _queueSource.Where(t => alive.Contains(t.Id)).ToList();
                var index = currentId == null ? -1 : filtered.FindIndex(t => t.Id == currentId);
                Queue = filtered;
                QueueIndex = index >= 0 ? index : filtered.Count == 0 ? -1 : 0;
                _sonosQueueSignature = "";
            }
        }
        if (_started && CurrentTrack == null && _devices.Count > 0) Run(RestorePlaybackState);
    }

    private bool ShouldUseQueue() => _queue.Count >= 2;

    // URL 取決於 IP 與埠：任何一個變了，音箱裡的佇列就全部失效
    private string QueueSignature() => $"{LocalIP ?? "-"}:{ServerPort}|" + string.Join(",", _queue.Select(t => t.Id));

    // ---- 推送入口 ----

    /// <summary>推送「清單中的目前曲目」。上一次推送還沒結束時記下來，結束後補跑（以最後一次為準）。</summary>
    public void CastCurrent(int resumeAtSec = 0, bool autoPlay = true)
    {
        if (CurrentTrack == null)
        {
            Hint = new Hint(HintKind.PickSong);
            return;
        }
        if (SelectedDevices().Count == 0)
        {
            Hint = new Hint(HintKind.NoDevice);
            return;
        }
        if (Busy)
        {
            _pendingCast = (resumeAtSec, autoPlay);
            LogBus.D("上一次推送尚未結束，排到它之後");
            return;
        }
        Busy = true;
        Run(async () =>
        {
            try { await RunCast(resumeAtSec, autoPlay); }
            finally { Busy = false; }
            NotifyNowPlaying();
            KickPoll();
            if (_pendingCast is { } pending)
            {
                _pendingCast = null;
                _pendingSeekSec = null;
                CastCurrent(pending.ResumeAtSec, pending.AutoPlay);
            }
            else if (_pendingSeekSec is { } seconds)
            {
                _pendingSeekSec = null;
                Seek(seconds);
            }
        });
    }

    private async Task RunCast(int resumeAtSec, bool autoPlay)
    {
        Hint = null;
        if (!await PrepareServer(false)) return;
        await RefreshTopology(SelectedDevices());
        var targets = SelectedDevices();
        var index = _queueIndex;
        var track = CurrentTrack;
        if (track == null) return;
        PositionSec = resumeAtSec;
        DurationSec = track.DurationMs / 1000;
        NotifyNowPlaying();

        if (await CastNativeQueue(targets, index, 0, resumeAtSec, autoPlay)) return;
        NativeQueueActive = false;
        if (!await PerformCast(track, targets)) return;
        var masters = targets.Where(d => !d.IsSatellite).ToList();
        if (resumeAtSec > 0)
        {
            foreach (var device in masters) await Soap.Seek(device, resumeAtSec);
            PositionSec = resumeAtSec;
            LogBus.I($"逐首推送後恢復到 {resumeAtSec}s");
        }
        if (!autoPlay)
        {
            foreach (var device in masters)
            {
                await Soap.Pause(device);
                SetStatus(device.Key, DeviceStatus.Paused);
            }
            _lastTransportState = "PAUSED_PLAYBACK";
        }
    }

    /// <summary>
    /// 超出音箱規格的檔案（>48 kHz、WAV/AIFF >16 bit）直接擋下並提示，
    /// 否則音箱會「拉一段資料後自己跳過」，看起來像 App 壞了。
    /// </summary>
    private bool BlockIfUnsupported(Track track)
    {
        var format = _platform.ProbeFormat(track);
        if (format == null || !AudioProbe.IsUnsupported(format)) return false;
        var description = AudioProbe.Describe(format);
        LogBus.W($"略過不支援的格式：{track.Title} · {description}（音箱上限 48 kHz，WAV/AIFF 16 bit）");
        Hint = new Hint(HintKind.UnsupportedFormat, description);
        return true;
    }

    // ---- 原生佇列 ----

    /// <summary>回傳 true 表示「已處理」（成功，或已明確提示使用者）；false 表示呼叫方應退回逐首推送。</summary>
    private async Task<bool> CastNativeQueue(List<SonosDevice> targets, int index, int attempt, int resumeAtSec, bool autoPlay)
    {
        var list = _queue;
        if (index >= 0 && index < list.Count && BlockIfUnsupported(list[index])) return true;
        if (list.Count < 2)
        {
            LogBus.D($"播放清單只有 {list.Count} 首，不建佇列，走逐首推送");
            return false;
        }
        var ip = LocalIP;
        var port = ServerPort;
        if (ip == null || port <= 0)
        {
            LogBus.W("本機 IP 或 HTTP 伺服器未就緒，無法建佇列");
            return false;
        }
        var speakers = targets.Where(d => !d.IsSatellite && !d.IsLegacyS1).ToList();
        if (speakers.Count == 0)
        {
            LogBus.W("選中的設備裡沒有可用主箱（從箱 / S1 被排除），走逐首推送");
            return false;
        }

        var signature = QueueSignature();
        var needRebuild = !NativeQueueActive || signature != _sonosQueueSignature;
        var safeIndex = Math.Clamp(index, 0, list.Count - 1);
        var targetTrack = list[safeIndex];
        var targetFileId = targetTrack.Id;
        LogBus.D($"推佇列：第 {safeIndex + 1}/{list.Count} 首「{targetTrack.Title}」（{targetFileId}）");

        foreach (var speaker in speakers)
        {
            SetStatus(speaker.Key, DeviceStatus.Pushing);

            if (needRebuild)
            {
                await Soap.RemoveAllTracksFromQueue(speaker);
                var entries = list.Select(t =>
                {
                    var url = MediaRegistry.StreamUrl(ip, port, t);
                    return (url, SoapXml.DidlLite(t.Title, url, t.MimeType, t.Id));
                }).ToList();
                if (!await EnqueueAll(speaker, entries))
                {
                    SetStatus(speaker.Key, DeviceStatus.Idle);
                    return false;
                }
                // 必須先切傳輸再讀 NrTracks：它報的是「目前 transport」的曲目數
                var transport = await Soap.SetQueueTransport(speaker);
                if (!transport.IsSuccess)
                {
                    LogBus.W($"切換佇列傳輸失敗：{transport.FailureText}，退回逐首推送");
                    SetStatus(speaker.Key, DeviceStatus.Idle);
                    return false;
                }
                var size = await Soap.GetQueueSize(speaker);
                if (size != null && size != list.Count)
                {
                    LogBus.W($"音箱佇列長度不符（音箱 {size} / 清單 {list.Count}），為避免播錯歌，退回逐首推送");
                    SetStatus(speaker.Key, DeviceStatus.Idle);
                    return false;
                }
            }

            await Soap.SetPlayMode(speaker, NativePlayMode());
            await Soap.SeekToTrack(speaker, safeIndex + 1);

            // 定位自檢要輪詢：音箱切傳輸有幾百毫秒延遲，讀一次很容易讀到舊值
            var positioned = await PollTrackNumber(speaker, safeIndex + 1, 4, 300);
            if (positioned != null && positioned != safeIndex + 1)
            {
                LogBus.W($"佇列定位不符（期望第 {safeIndex + 1} 首，實際第 {positioned} 首），重新定位");
                await Soap.SeekToTrack(speaker, safeIndex + 1);
                positioned = await PollTrackNumber(speaker, safeIndex + 1, 3, 300);
                if (positioned != null && positioned != safeIndex + 1)
                {
                    LogBus.W($"佇列定位仍不符（第 {positioned} 首），退回逐首推送");
                    SetStatus(speaker.Key, DeviceStatus.Idle);
                    return false;
                }
            }

            if (resumeAtSec > 0)
            {
                await Soap.Seek(speaker, resumeAtSec);
                LogBus.D($"重建後恢復到 {resumeAtSec}s");
            }

            if (autoPlay)
            {
                var play = await Soap.Play(speaker);
                if (!play.IsSuccess)
                {
                    LogBus.W($"佇列播放失敗：{play.FailureText}，退回逐首推送");
                    SetStatus(speaker.Key, DeviceStatus.Idle);
                    return false;
                }
            }
            else LogBus.D("保持暫停：只重建佇列並定位，不送 Play");

            // 端到端校驗：讀回 TrackURI，確認音箱放的確實是我們要的那一首
            string? actualUri = null;
            var matched = false;
            for (var round = 0; round < 4; round++)
            {
                actualUri = await Soap.GetPlaybackTrackUri(speaker);
                if (actualUri != null && actualUri.Contains(targetFileId))
                {
                    matched = true;
                    break;
                }
                if (round < 3) await Task.Delay(400);
            }
            if (!matched && !string.IsNullOrEmpty(actualUri))
            {
                LogBus.W($"聲畫不一致：期望 {targetFileId}，音箱在放 {actualUri.Split('/').Last()}（第 {attempt + 1} 次）");
                if (attempt == 0)
                {
                    NativeQueueActive = false;
                    _sonosQueueSignature = "";
                    return await CastNativeQueue(targets, safeIndex, 1, resumeAtSec, autoPlay);
                }
                SetStatus(speaker.Key, DeviceStatus.Idle);
                return false;
            }
            if (matched) LogBus.D($"聲畫一致：{targetFileId} ✓");
            SetStatus(speaker.Key, autoPlay ? DeviceStatus.Playing : DeviceStatus.Paused);
        }

        _sonosQueueSignature = signature;
        NativeQueueActive = true;
        ExternalSource = false;
        _lastQueueTrack = safeIndex + 1;
        var now = _platform.Uptime();
        _castSettledAt = now;
        _castAt = now;
        _castDurationMs = targetTrack.DurationMs;
        _lastTransportState = autoPlay ? "PLAYING" : "PAUSED_PLAYBACK";
        _earlyStopRetries = 0;
        Hint = null;
        StreamUrl = MediaRegistry.StreamUrl(ip, port, targetTrack);
        MirrorSatelliteStatus(autoPlay ? DeviceStatus.Playing : DeviceStatus.Paused);
        LogBus.I($"已把 {list.Count} 首灌進音箱佇列（{(needRebuild ? "重建" : "沿用")}），從第 {safeIndex + 1} 首開始");
        return true;
    }

    private async Task<int?> PollTrackNumber(SonosDevice speaker, int expect, int rounds, int delayMs)
    {
        int? value = null;
        for (var round = 0; round < rounds; round++)
        {
            value = await Soap.GetQueueTrackNumber(speaker);
            if (value == null || value == expect) break;
            if (round < rounds - 1) await Task.Delay(delayMs);
        }
        return value;
    }

    /// <summary>每批 12 首（實測一次超過 16 首會 402 / 500），插入位置逐批遞增。</summary>
    private async Task<bool> EnqueueAll(SonosDevice speaker, List<(string Url, string Metadata)> entries)
    {
        for (var index = 0; index < entries.Count; index += QueueChunkSize)
        {
            var chunk = entries.GetRange(index, Math.Min(QueueChunkSize, entries.Count - index));
            if (!await EnqueueChunk(speaker, chunk, index + 1)) return false;
        }
        return true;
    }

    /// <summary>某一批失敗就對半拆分重試，拆到單首仍失敗才放棄整條佇列路徑。</summary>
    private async Task<bool> EnqueueChunk(SonosDevice speaker, List<(string Url, string Metadata)> entries, int firstTrackNumber)
    {
        if (entries.Count == 0) return true;
        var result = await Soap.AddMultipleURIsToQueue(speaker, entries, firstTrackNumber);
        if (result.IsSuccess) return true;
        if (entries.Count == 1)
        {
            LogBus.W($"單首入隊失敗：{result.FailureText}");
            return false;
        }
        LogBus.W($"一次入隊 {entries.Count} 首失敗（{result.FailureText}），對半拆分重試");
        var mid = entries.Count / 2;
        if (!await EnqueueChunk(speaker, entries.GetRange(0, mid), firstTrackNumber)) return false;
        return await EnqueueChunk(speaker, entries.GetRange(mid, entries.Count - mid), firstTrackNumber + mid);
    }

    /// <summary>隨機是在 App 端把清單洗牌後整份入隊，所以音箱端一律 REPEAT_ALL / REPEAT_ONE。</summary>
    private string NativePlayMode() => !Shuffle && RepeatMode == RepeatMode.One ? "REPEAT_ONE" : "REPEAT_ALL";

    // ---- 逐首推送（兜底路徑） ----

    private sealed record PushResult(bool Ok, bool Skipped, int? ErrorCode, string? Message);

    private async Task<bool> PerformCast(Track track, List<SonosDevice> targets)
    {
        if (BlockIfUnsupported(track)) return false;
        var ip = LocalIP;
        if (ip == null || ServerPort <= 0) return false;
        var url = MediaRegistry.StreamUrl(ip, ServerPort, track);
        StreamUrl = url;
        LogBus.I("────────────────────────");
        LogBus.I($"推送「{track.Title}」→ " + string.Join("、", targets.Select(d => d.DisplayName)));
        if (!MimeTypes.IsSonosSupported(track.MimeType)) LogBus.W($"{track.MimeType} 不在原版列出的支援格式內，可能回 714");
        if (targets.Any(d => d.IsLegacyS1) && targets.Any(d => d.SwGen >= 2)) Hint = new Hint(HintKind.MixedGeneration);

        var results = new List<PushResult>();
        foreach (var device in targets) results.Add(await PushOne(device, url, track));

        // 701：音箱拿不到串流 —— 換埠重建 HTTP 伺服器後對所有音箱重試一次
        if (results.Any(r => r.ErrorCode == 701))
        {
            LogBus.W("偵測到 701 —— 重建 HTTP 伺服器（換埠）後重試一次");
            var newPort = await _platform.RestartServerOnNewPortAsync();
            var newIp = _platform.CurrentLanIP(PrimaryTarget());
            if (newPort != null && newIp != null)
            {
                ServerPort = newPort.Value;
                LocalIP = newIp;
                url = MediaRegistry.StreamUrl(newIp, newPort.Value, track);
                StreamUrl = url;
                results.Clear();
                foreach (var device in targets) results.Add(await PushOne(device, url, track));
            }
            else LogBus.E("重建 HTTP 伺服器失敗，放棄重試");
        }

        var played = results.Count(r => r.Ok);
        var following = results.Count(r => r.Skipped);
        var failures = results.Where(r => !r.Ok && !r.Skipped).ToList();
        if (failures.Count == 0 && played > 0)
        {
            Hint = null;
            ExternalSource = false;
            LogBus.I($"完成：{played} 台主箱播放" + (following > 0 ? $"，{following} 台從箱隨主箱同步" : ""));
            _lastTransportState = "PLAYING";
            var now = _platform.Uptime();
            _castAt = now;
            _castSettledAt = now;
            _earlyStopRetries = 0;
            _castDurationMs = track.DurationMs;
            return true;
        }
        var first = failures.FirstOrDefault();
        var kind = failures.Count == 0 ? HintKind.Satellite : UpnpErrors.Kind(first?.ErrorCode) switch
        {
            UpnpErrorKind.Reach => HintKind.Reach,
            UpnpErrorKind.Format => HintKind.Format,
            UpnpErrorKind.BadRequest => HintKind.BadRequest,
            UpnpErrorKind.Offline => HintKind.Offline,
            UpnpErrorKind.Satellite => HintKind.Satellite,
            _ => HintKind.Unknown,
        };
        Hint = new Hint(kind, $"{url} · {track.MimeType}");
        LogBus.E($"完成：{played} 成功 / {following} 從箱 / {failures.Count} 失敗；首個失敗 {first?.ErrorCode?.ToString() ?? "-"} {first?.Message}");
        return false;
    }

    private async Task<PushResult> PushOne(SonosDevice device, string url, Track track)
    {
        if (device.IsSatellite)
        {
            SetStatus(device.Key, DeviceStatus.Following);
            LogBus.I($"{device.DisplayName}({device.Ip}) 是配對從設備，隨主箱同步，略過獨立推送");
            return new PushResult(false, true, null, "satellite");
        }
        SetStatus(device.Key, DeviceStatus.Pushing);
        var metadata = SoapXml.DidlLite(track.Title, url, track.MimeType);

        var set = await Soap.SetAVTransportURI(device, url, metadata);
        if (!set.IsSuccess)
        {
            if (set.FaultCode == UpnpErrors.SatelliteCode)
            {
                SetStatus(device.Key, DeviceStatus.Following);
                LogBus.I($"{device.DisplayName} 回 1023 → 判定為配對從設備，隨主箱同步");
                return new PushResult(false, true, null, "satellite");
            }
            SetStatus(device.Key, DeviceStatus.Error, set.IsTransportError ? set.Description : UpnpErrors.Describe(set.FaultCode));
            LogBus.E($"{device.DisplayName} SetAVTransportURI 失敗：{set.FailureText}");
            return new PushResult(false, false, set.FaultCode, set.Description);
        }

        var play = await Soap.Play(device);
        if (!play.IsSuccess)
        {
            SetStatus(device.Key, DeviceStatus.Error, play.IsTransportError ? play.Description : UpnpErrors.Describe(play.FaultCode));
            LogBus.E($"{device.DisplayName} Play 失敗：{play.FailureText}");
            return new PushResult(false, false, play.FaultCode, play.Description);
        }
        SetStatus(device.Key, DeviceStatus.Playing);
        LogBus.I($"{device.DisplayName} 已開始播放");
        return new PushResult(true, false, null, null);
    }

    // ---- 傳輸控制 ----

    public void Next() => PlayRelative(1);
    public void Previous() => PlayRelative(-1);

    public void TogglePlayPause()
    {
        if (IsPlaying) Pause();
        else if (HasSession || ExternalSource) Resume();
        else
        {
            EnsureQueueReady();
            CastCurrent();
        }
    }

    private void PlayRelative(int offset)
    {
        _lastAdvanceAt = _platform.Uptime();

        // 音箱已有我們的佇列：直接叫音箱切歌，由它自己完成
        if (NativeQueueActive && !ExternalSource)
        {
            var targets = ControlTargets();
            if (targets.Count > 0)
            {
                Step(offset);
                PositionSec = 0;
                DurationSec = (CurrentTrack?.DurationMs ?? 0) / 1000;
                _castSettledAt = _platform.Uptime();
                NotifyNowPlaying();
                Run(async () =>
                {
                    foreach (var device in targets)
                    {
                        var result = offset > 0 ? await Soap.NextTrack(device) : await Soap.PreviousTrack(device);
                        if (!result.IsSuccess) LogBus.W($"音箱切歌失敗：{result.FailureText}");
                    }
                    KickPoll();
                });
                return;
            }
        }

        EnsureQueueReady();
        if (RepeatMode == RepeatMode.One && !Shuffle)
        {
            if (CurrentTrack != null)
            {
                LogBus.I("單曲循環：停在目前這首");
                CastCurrent();
            }
            else Stop();
            return;
        }
        var next = Step(offset);
        if (next == null)
        {
            LogBus.I("播放清單為空，停止");
            Stop();
            return;
        }
        LogBus.I($"{(offset > 0 ? "下一首" : "上一首")} →「{next.Title}」");
        CastCurrent();
    }

    public void Pause()
    {
        if (ExternalSource) return;   // 音箱在放別人的內容，不代為暫停
        Run(async () =>
        {
            var targets = ControlTargets();
            if (targets.Count == 0) return;
            foreach (var device in targets)
            {
                var result = await Soap.Pause(device);
                if (result.IsSuccess)
                {
                    SetStatus(device.Key, DeviceStatus.Paused);
                    LogBus.I($"{device.DisplayName} 已暫停");
                }
                else SetStatus(device.Key, DeviceStatus.Error, result.IsTransportError ? result.Description : UpnpErrors.Describe(result.FaultCode));
            }
            MirrorSatelliteStatus(DeviceStatus.Paused);
            _lastTransportState = "PAUSED_PLAYBACK";
            _pausedAtSec = PositionSec;
            NotifyNowPlaying();
        });
    }

    public void Resume()
    {
        if (ExternalSource)
        {
            LogBus.I("音箱在放其他來源，按播放 → 交還給 ZONOZ（從暫停處繼續）");
            ExternalSource = false;
            EnsureQueueReady();
            CastCurrent(_pausedAtSec > 0 ? _pausedAtSec : PositionSec);
            return;
        }
        Run(async () =>
        {
            await PrepareServer(false);
            var targets = ControlTargets();
            if (targets.Count == 0) return;
            foreach (var device in targets)
            {
                var result = await Soap.Play(device);
                if (result.IsSuccess)
                {
                    SetStatus(device.Key, DeviceStatus.Playing);
                    LogBus.I($"{device.DisplayName} 已繼續");
                }
                else SetStatus(device.Key, DeviceStatus.Error, result.IsTransportError ? result.Description : UpnpErrors.Describe(result.FaultCode));
            }
            MirrorSatelliteStatus(DeviceStatus.Playing);
            _lastTransportState = "PLAYING";
            NotifyNowPlaying();
            KickPoll();
        });
    }

    public void Stop() => Run(StopAsync);

    /// <summary>關閉 App 前也會呼叫：停掉音箱上屬於我們的播放。</summary>
    public async Task StopAsync()
    {
        var targets = ControlTargets();
        var foreign = ExternalSource;
        foreach (var device in targets)
        {
            // 音箱已被其他來源接手時只放掉本地狀態，不去停別人的播放
            if (!foreign && StatusOf(device.Key) != DeviceStatus.Idle) await Soap.Stop(device);
            SetStatus(device.Key, DeviceStatus.Idle);
        }
        ExternalSource = false;
        NativeQueueActive = false;
        MirrorSatelliteStatus(DeviceStatus.Idle);
        PositionSec = 0;
        _lastTransportState = null;
        LogBus.I($"已停止（{targets.Count} 台）");
        NotifyNowPlaying();
    }

    public void SetVolume(int value)
    {
        var clamped = Math.Clamp(value, 0, 100);
        Volume = clamped;
        _lastVolumeSetAt = _platform.Uptime();
        Run(async () =>
        {
            foreach (var device in ControlTargets())
            {
                var result = await Soap.SetVolume(device, clamped);
                if (!result.IsSuccess) LogBus.E($"音量設定失敗 {device.DisplayName}：{result.FailureText}");
            }
        });
    }

    public void Seek(int seconds)
    {
        var target = Math.Max(0, seconds);
        PositionSec = target;
        _castSettledAt = _platform.Uptime();
        if (Busy)
        {
            // 佇列正在重建：現在送出的 Seek 會被重建流程自己的定位蓋掉，等它結束再補
            _pendingSeekSec = target;
            return;
        }
        Run(async () =>
        {
            var targets = ControlTargets();
            if (targets.Count == 0)
            {
                LogBus.W("沒有正在播放的設備，Seek 無效");
                return;
            }
            foreach (var device in targets)
            {
                var result = await Soap.Seek(device, target);
                if (!result.IsSuccess) LogBus.E($"Seek 失敗 {device.DisplayName}：{result.FailureText}");
            }
            NotifyNowPlaying();
        });
    }

    public void ToggleShuffle()
    {
        Shuffle = !Shuffle;
        if (Shuffle) RepeatMode = RepeatMode.All;
        PersistModes();
        ReorderQueue();
        LogBus.I($"播放模式 → {(Shuffle ? "隨機" : "循序")}");
        RecastIfQueueActive("隨機開關");
    }

    public void CycleRepeat()
    {
        var wasShuffle = Shuffle;
        RepeatMode = RepeatMode == RepeatMode.All ? RepeatMode.One : RepeatMode.All;
        Shuffle = false;
        PersistModes();
        LogBus.I($"播放模式 → {(RepeatMode == RepeatMode.One ? "單曲循環" : "列表循環")}");
        if (wasShuffle)
        {
            ReorderQueue();
            RecastIfQueueActive("循環切換");
        }
        else ApplyPlayModeOnly("循環切換");
    }

    private void PersistModes()
    {
        _settings.Shuffle = Shuffle;
        _settings.RepeatMode = RepeatMode == RepeatMode.One ? "one" : "all";
        _settings.Save();
    }

    /// <summary>只切播放模式，不重建佇列（重建會讓目前這首從頭播）。</summary>
    private void ApplyPlayModeOnly(string reason)
    {
        if (!ShouldUseQueue() || !NativeQueueActive || ExternalSource) return;
        var speakers = ControlTargets();
        if (speakers.Count == 0) return;
        Run(async () =>
        {
            var mode = NativePlayMode();
            var allOk = true;
            foreach (var speaker in speakers)
                if (!(await Soap.SetPlayMode(speaker, mode)).IsSuccess) allOk = false;
            if (allOk) LogBus.I($"{reason} → 只切播放模式：{mode}（不重建佇列）");
            else
            {
                LogBus.W($"{reason}：SetPlayMode 失敗，退回重建佇列");
                RecastIfQueueActive(reason);
            }
        });
    }

    /// <summary>
    /// 清單順序 / 內容變了：按新順序重建音箱佇列，並保留播放位置與暫停狀態。
    /// 每個提前返回都寫日誌 —— 否則現場只剩「什麼都沒發生」，分不清沒觸發還是觸發後失敗。
    /// </summary>
    private void RecastIfQueueActive(string reason)
    {
        if (ExternalSource) { LogBus.D($"{reason}：音箱在放其他來源，略過重建"); return; }
        if (!HasSession)
        {
            LogBus.D($"{reason}：目前沒有播放中的工作階段，下次播放時再建佇列");
            _sonosQueueSignature = "";
            return;
        }
        if (CurrentTrack == null) { LogBus.D($"{reason}：沒有目前曲目，略過重建"); return; }
        if (SelectedDevices().Count == 0) { LogBus.D($"{reason}：沒有選中音箱，略過重建"); return; }
        var atSec = Math.Max(0, PositionSec);
        var wasPlaying = _deviceStatus.Values.Contains(DeviceStatus.Playing);
        LogBus.D($"{reason} → 按新順序重建佇列（第 {_queueIndex + 1} 首，{atSec}s）");
        CastCurrent(atSec, wasPlaying);
    }

    /// <summary>「下一首播放」後讓音箱佇列跟上：能原生插隊就插隊，否則重建。</summary>
    private void SyncSpeakerQueue(Track inserted, bool rebuild)
    {
        if (!HasSession || ExternalSource) return;
        if (rebuild || !NativeQueueActive || Busy)
        {
            RecastIfQueueActive("下一首播放");
            return;
        }
        var ip = LocalIP;
        if (ip == null || ServerPort <= 0) return;
        var speakers = ControlTargets().Where(d => !d.IsLegacyS1).ToList();
        if (speakers.Count == 0) return;
        var insertAt = Math.Max(1, _queueIndex + 2);
        var url = MediaRegistry.StreamUrl(ip, ServerPort, inserted);
        var didl = SoapXml.DidlLite(inserted.Title, url, inserted.MimeType, inserted.Id);
        Run(async () =>
        {
            var ok = true;
            foreach (var speaker in speakers)
            {
                var result = await Soap.AddMultipleURIsToQueue(speaker, new List<(string, string)> { (url, didl) }, insertAt, true);
                if (!result.IsSuccess)
                {
                    ok = false;
                    LogBus.W($"原生插隊失敗（{result.FailureText}）");
                }
            }
            if (ok)
            {
                _sonosQueueSignature = QueueSignature();
                LogBus.I($"已把「{inserted.Title}」插進音箱佇列第 {insertAt} 位（原生插隊）");
            }
            else
            {
                LogBus.W("原生插隊不成功，改為重建整個佇列");
                RecastIfQueueActive("下一首播放");
            }
        });
    }

    // ---- 恢復狀態 ----

    /// <summary>App 關掉但音箱還在播：重新開 App 時主動問音箱，把介面接回來。</summary>
    private async Task RestorePlaybackState()
    {
        if (CurrentTrack != null) return;
        var device = PrimaryTarget();
        if (device == null) return;
        var snapshot = await Soap.GetTransportSnapshot(device);
        if (snapshot == null || CurrentTrack != null) return;
        if (snapshot.Uri.Length == 0) { LogBus.D("音箱目前沒有載入媒體，無需恢復"); return; }
        var fileId = MediaRegistry.FileIdFromStreamUri(snapshot.Uri);
        if (fileId == null) { LogBus.I("音箱目前播的是外部音源，不接管介面"); return; }
        if (!snapshot.IsPlaying && !snapshot.IsPaused) { LogBus.D($"音箱狀態 {snapshot.State}，不恢復播放介面"); return; }
        var track = Library.FirstOrDefault(t => t.Id == fileId);
        if (track == null) { LogBus.D($"音箱在放的曲目（{fileId}）不在目前曲庫裡，不恢復"); return; }

        StartQueue(Library, track);
        PositionSec = snapshot.PositionSec;
        DurationSec = snapshot.DurationSec > 0 ? snapshot.DurationSec : track.DurationMs / 1000;
        SetStatus(device.Key, snapshot.IsPlaying ? DeviceStatus.Playing : DeviceStatus.Paused);
        _lastTransportState = snapshot.State;
        var mediaUri = await Soap.GetMediaUri(device) ?? "";
        NativeQueueActive = mediaUri.StartsWith("x-rincon-queue:");
        _sonosQueueSignature = "";   // 音箱裡的順序未必等於曲庫順序，下次點歌時重建
        _lastQueueTrack = snapshot.TrackNumber;
        _castAt = _platform.Uptime() - snapshot.PositionSec;
        _castDurationMs = track.DurationMs;
        LogBus.I($"已從音箱恢復播放狀態：{track.Title} · {snapshot.State} · {Track.FormatDuration(snapshot.PositionSec)}");
        NotifyNowPlaying();
    }

    // ---- 輪詢同步 ----

    private void StartPolling()
    {
        if (_pollCts != null) return;
        _pollCts = new CancellationTokenSource();
        var token = _pollCts.Token;
        Run(() => PollLoop(token));
    }

    private void KickPoll() => _pollKick = true;

    private async Task PollLoop(CancellationToken token)
    {
        var tick = 0;
        var forceSample = true;
        while (!token.IsCancellationRequested)
        {
            double interval;
            try { interval = await PollOnce(tick, forceSample); }
            catch (Exception ex)
            {
                LogBus.E($"輪詢失敗：{ex.Message}");
                interval = 5;
            }
            tick++;
            forceSample = false;
            // 以 0.25 秒為單位睡，KickPoll() 才能把長間隔（閒置 15 秒）提前打斷
            var waited = 0.0;
            while (waited < interval && !token.IsCancellationRequested)
            {
                if (_pollKick)
                {
                    _pollKick = false;
                    forceSample = true;
                    break;
                }
                var slice = Math.Min(0.25, interval - waited);
                await Task.Delay(TimeSpan.FromSeconds(slice));
                waited += slice;
            }
        }
    }

    /// <summary>要盯的那一台：優先正在播 / 暫停中的主箱，其次是選中的主箱。沒選中的音箱不看。</summary>
    private SonosDevice? PollTarget()
    {
        SonosDevice? fallback = null;
        foreach (var device in _devices)
        {
            if (device.IsSatellite) continue;
            var status = StatusOf(device.Key);
            if (status is DeviceStatus.Playing or DeviceStatus.Paused) return device;
            if (fallback == null && _selectedKeys.Contains(device.Key)) fallback = device;
        }
        return fallback;
    }

    /// <summary>音箱按鍵不會推送任何事件，只能輪詢。回傳下一次間隔（秒）。</summary>
    private async Task<double> PollOnce(int tick, bool forceSample)
    {
        var active = PollTarget();
        if (active != null && !Busy)
        {
            if (forceSample || tick % 2 == 0)
            {
                // 電腦換了 IP（換網路 / 重連 Wi-Fi）就更新，後面的 heal 會按新位址重推
                var ip = _platform.CurrentLanIP(active);
                if (ip != null && ip != LocalIP) LocalIP = ip;

                var info = await Soap.GetPositionInfo(active);
                if (!Busy)
                {
                    if (info != null)
                    {
                        RefreshOwnership(info);
                        if (!ExternalSource && HasSession && _platform.Uptime() - _castSettledAt >= QueueSettle
                            && (info.PositionSec > 0 || info.DurationSec > 0))
                        {
                            PositionSec = info.PositionSec;
                            if (info.DurationSec > 0) DurationSec = info.DurationSec;
                        }
                        SyncQueueTrack(info);
                    }
                    await SyncTransportState(active);
                    var status = StatusOf(active.Key);
                    if (status is DeviceStatus.Playing or DeviceStatus.Paused) MirrorSatelliteStatus(status);
                    if (tick % 10 == 0) await AuditQueue(active);
                    if (forceSample || tick % 8 == 0) await SyncVolume(active);
                    NotifyNowPlaying();
                }
            }
            else if (!ExternalSource && !ConnectionLost && StatusOf(active.Key) == DeviceStatus.Playing)
            {
                // 兩次取樣之間本地插值；只在 PLAYING 時做，否則暫停時進度會抖動
                var next = PositionSec + 1;
                if (DurationSec <= 0 || next < DurationSec) PositionSec = next;
            }
        }
        if (ConnectionLost) return 30;
        if (active == null) return 15;
        if (_deviceStatus.Values.Contains(DeviceStatus.Playing) || Busy) return 1;
        return 5;
    }

    /// <summary>音箱被別的來源接手（Sonos App、AirPlay、電視）時交還控制權，不搶。</summary>
    private void RefreshOwnership(PositionInfo info)
    {
        var uri = info.TrackUri;
        if (uri.Length == 0) return;   // 切流中讀不到，下一輪再說
        var ours = uri.Contains("/stream/");
        if (!ours && !ExternalSource && HasSession)
        {
            LogBus.I("音箱已被其他來源佔用（Sonos App 等），ZONOZ 交還控制權");
            ExternalSource = true;
            NativeQueueActive = false;
            _lastQueueTrack = 0;
            _pausedAtSec = PositionSec;
        }
        else if (ours && ExternalSource)
        {
            LogBus.I("音箱已回到 ZONOZ 的串流");
            ExternalSource = false;
        }
        if (ours && HasSession) HealStaleStreamHost(uri);
    }

    /// <summary>電腦 IP 變了：音箱佇列裡的 URL 還指著舊位址 → 按新位址重推（15 秒內最多一次）。</summary>
    private void HealStaleStreamHost(string uri)
    {
        var ip = LocalIP;
        var host = DeviceDescription.HostOf(uri);
        if (ip == null || string.IsNullOrEmpty(host) || host == ip) return;
        var now = _platform.Uptime();
        if (now - _lastUrlHealAt < 15) return;
        _lastUrlHealAt = now;
        LogBus.W($"串流位址已過期：音箱裡是 {host}，本機現在是 {ip} → 按新位址重推");
        _sonosQueueSignature = "";
        CastCurrent(PositionSec, _deviceStatus.Values.Contains(DeviceStatus.Playing));
    }

    private void MirrorSatelliteStatus(DeviceStatus status)
    {
        var mirrored = status == DeviceStatus.Idle ? DeviceStatus.Idle : DeviceStatus.Following;
        var changed = false;
        foreach (var satellite in _devices.Where(d => d.IsSatellite))
        {
            var hasMaster = _devices.Any(d => !d.IsSatellite && StatusOf(d.Key) == status);
            if ((hasMaster || status == DeviceStatus.Idle) && StatusOf(satellite.Key) != mirrored)
            {
                _deviceStatus[satellite.Key] = mirrored;
                changed = true;
            }
        }
        if (changed) Raise("DeviceStatus");
    }

    private async Task SyncTransportState(SonosDevice device)
    {
        var state = await Soap.GetTransportState(device);
        if (state == null)
        {
            if (++_soapFailStreak >= 3) MarkDisconnected();
            return;
        }
        if (_soapFailStreak > 0 || ConnectionLost)
        {
            _soapFailStreak = 0;
            await MarkReconnected();
        }
        if (Busy) return;
        if (ExternalSource)
        {
            if (StatusOf(device.Key) == DeviceStatus.Playing) SetStatus(device.Key, DeviceStatus.Paused);
            return;
        }
        var current = StatusOf(device.Key);
        switch (state)
        {
            case "PAUSED_PLAYBACK":
                if (current is DeviceStatus.Playing or DeviceStatus.Pushing)
                {
                    LogBus.I("音箱已暫停（機身按鍵 / Sonos App），同步介面狀態");
                    SetStatus(device.Key, DeviceStatus.Paused);
                    _pausedAtSec = PositionSec;
                }
                break;
            case "PLAYING":
                // 只接手「正在放我們串流」的音箱；閒置音箱在放別的東西不關我們的事
                if (current is DeviceStatus.Paused or DeviceStatus.Pushing)
                {
                    LogBus.I("音箱已開始播放，同步介面狀態");
                    SetStatus(device.Key, DeviceStatus.Playing);
                }
                break;
            case "STOPPED":
                if (_lastTransportState == "PLAYING" && current is DeviceStatus.Playing or DeviceStatus.Paused)
                {
                    if (NativeQueueActive)
                    {
                        LogBus.I("音箱佇列播放結束");
                        SetStatus(device.Key, DeviceStatus.Idle);
                        MirrorSatelliteStatus(DeviceStatus.Idle);
                    }
                    else HandleEarlyStop(device);
                }
                break;
        }
        _lastTransportState = state;
    }

    /// <summary>
    /// 逐首推送模式下 PLAYING → STOPPED 有兩種含義，必須區分：
    /// 已播時長 &lt; 總時長 − 20s 判為異常停止 → 先 Play 續上（最多 2 次），不要切歌；
    /// 否則才是真的播完 → 按播放模式續下一首。
    /// </summary>
    private void HandleEarlyStop(SonosDevice device)
    {
        if (ExternalSource) return;
        var now = _platform.Uptime();
        var sinceAdvance = now - _lastAdvanceAt;
        if (sinceAdvance < AutoAdvanceDebounce)
        {
            LogBus.D($"剛切過歌（{(int)sinceAdvance}s），忽略這次 STOPPED");
            return;
        }
        var played = _castAt > 0 ? now - _castAt : double.MaxValue;
        var expected = _castDurationMs > 0 ? _castDurationMs / 1000.0 : DurationSec;
        var tooEarly = expected > 0 && played < expected - EarlyStopTolerance;
        if (tooEarly && _earlyStopRetries < MaxEarlyStopRetries)
        {
            _earlyStopRetries++;
            LogBus.W($"音箱提前停止（已播 {(int)played}s / 共 {(int)expected}s），嘗試續播而不是跳歌（第 {_earlyStopRetries} 次）");
            Run(async () =>
            {
                await Soap.Play(device);
                _lastTransportState = "PLAYING";
            });
        }
        else
        {
            LogBus.I("播放結束 → 續下一首");
            PlayRelative(1);
        }
    }

    /// <summary>
    /// 機身切歌靠 Track 序號變化發現；再用 TrackURI 裡的 fileId 按「內容」校正，
    /// 避免清單與音箱佇列錯位時永久偏一位。
    /// </summary>
    private void SyncQueueTrack(PositionInfo info)
    {
        if (ExternalSource || _queue.Count == 0) return;
        if (_platform.Uptime() - _castSettledAt < QueueSettle) return;
        if (info.TrackNumber is not { } trackNo || trackNo <= 0) return;
        var playingId = MediaRegistry.FileIdFromStreamUri(info.TrackUri);
        if (playingId == null) return;

        var indexByNumber = Math.Clamp(trackNo - 1, 0, _queue.Count - 1);
        var indexByContent = -1;
        for (var i = 0; i < _queue.Count; i++)
            if (_queue[i].Id == playingId) { indexByContent = i; break; }
        var index = indexByContent >= 0 ? indexByContent : indexByNumber;
        if (trackNo == _lastQueueTrack && index == _queueIndex) return;

        if (indexByContent < 0)
        {
            // 音箱放的是我們的串流，但不在目前清單裡（例如清單剛換過）→ 不亂改介面
            LogBus.W($"音箱放的不是清單裡的曲目（{playingId}），略過同步");
            _lastQueueTrack = trackNo;
            return;
        }
        if (index != indexByNumber && NativeQueueActive && _sonosQueueSignature.Length > 0)
            LogBus.W($"清單與音箱佇列錯位（音箱第 {trackNo} 首 = 清單第 {index + 1} 首），已按內容校正");
        _lastQueueTrack = trackNo;
        if (index != _queueIndex)
        {
            LogBus.I($"音箱切到了佇列第 {trackNo} 首 →「{_queue[index].Title}」");
            QueueIndex = index;
            PositionSec = info.PositionSec;
            DurationSec = info.DurationSec > 0 ? info.DurationSec : _queue[index].DurationMs / 1000;
            _castAt = _platform.Uptime() - info.PositionSec;
            _castDurationMs = _queue[index].DurationMs;
            _earlyStopRetries = 0;
        }
    }

    private async Task SyncVolume(SonosDevice device)
    {
        if (_platform.Uptime() - _lastVolumeSetAt < VolumeSyncGuard) return;
        var value = await Soap.GetVolume(device);
        if (value == null || _platform.Uptime() - _lastVolumeSetAt < VolumeSyncGuard) return;
        if (value.Value != Volume) Volume = value.Value;
    }

    /// <summary>佇列長度自檢：音箱裡的首數和清單對不上就重建（60 秒內最多一次）。</summary>
    private async Task AuditQueue(SonosDevice device)
    {
        if (ExternalSource || !NativeQueueActive || !ShouldUseQueue() || Busy) return;
        if (_sonosQueueSignature.Length == 0 || StatusOf(device.Key) != DeviceStatus.Playing) return;
        var expected = _queue.Count;
        var actual = await Soap.GetQueueSize(device);
        if (actual == null || actual == expected) return;
        if (Busy || _queue.Count != expected) return;
        var now = _platform.Uptime();
        if (now - _lastAuditRebuildAt < AuditRebuildCooldown) return;
        _lastAuditRebuildAt = now;
        LogBus.W($"佇列自檢失敗：音箱 {actual} 首 / 清單 {expected} 首 → 重建佇列");
        _sonosQueueSignature = "";
        RecastIfQueueActive("佇列自檢");
    }

    private void MarkDisconnected()
    {
        if (ConnectionLost) return;
        LogBus.W("與音箱失去聯繫（網路斷開或音箱離線），介面轉為暫停");
        ConnectionLost = true;
        if (HasSession) Hint = new Hint(HintKind.ConnectionLost);
        NotifyNowPlaying();
    }

    private async Task MarkReconnected()
    {
        if (!ConnectionLost) return;
        LogBus.I("與音箱恢復聯繫");
        ConnectionLost = false;
        if (Hint?.Kind == HintKind.ConnectionLost) Hint = null;
        await PrepareServer(true);
    }
}
