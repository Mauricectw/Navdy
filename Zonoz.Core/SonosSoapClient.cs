using System.Text;

namespace Zonoz.Core;

public sealed class SoapResult
{
    public bool IsSuccess { get; private init; }
    public string Body { get; private init; } = "";
    public int HttpStatus { get; private init; }
    public int? FaultCode { get; private init; }
    public string Description { get; private init; } = "";
    public bool IsTransportError { get; private init; }

    public static SoapResult Success(string body) => new() { IsSuccess = true, Body = body, HttpStatus = 200 };
    public static SoapResult Fault(int http, int? code, string description, string raw) =>
        new() { HttpStatus = http, FaultCode = code, Description = description, Body = raw };
    public static SoapResult TransportError(string message) => new() { IsTransportError = true, Description = message };

    public string FailureText => IsSuccess ? "OK" : IsTransportError ? Description : $"UPnP {FaultCode?.ToString() ?? "-"} {Description}";
}

/// <summary>音箱目前的狀態快照 —— 重新開 App 時主動問音箱，而不是依賴本地可能已遺失的狀態。</summary>
public sealed record TransportSnapshot(string State, string Uri, string Title, int PositionSec, int DurationSec, int TrackNumber)
{
    public bool IsPlaying => State is "PLAYING" or "TRANSITIONING";
    public bool IsPaused => State == "PAUSED_PLAYBACK";
}

/// <summary>GetPositionInfo 一次能拿到的全部欄位。</summary>
public sealed record PositionInfo(int? TrackNumber, string TrackUri, int PositionSec, int DurationSec);

/// <summary>Sonos 的 UPnP 控制客戶端：拼 SOAP 信封、POST 到 1400 埠、把 UPnP Fault 翻成錯誤碼。</summary>
public sealed class SonosSoapClient
{
    private static readonly HashSet<string> QuietActions = new() { "GetPositionInfo", "GetTransportInfo", "GetVolume", "GetMediaInfo" };
    private const string ZoneGroupTopologyPath = "/ZoneGroupTopology/Control";

    private readonly HttpClient _http;

    public SonosSoapClient()
    {
        // 區網直連：不走系統 Proxy（公司環境的 Proxy 會把 192.168.x.x 的請求送錯地方）
        var handler = new SocketsHttpHandler { UseProxy = false, ConnectTimeout = TimeSpan.FromSeconds(5) };
        _http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
    }

    // ---- AVTransport ----

    public Task<SoapResult> SetAVTransportURI(SonosDevice d, string uri, string metadata)
    {
        LogBus.Log(LogLevel.Tx, $"SetAVTransportURI → {d.DisplayName}({d.Ip}) CurrentURI={uri}");
        return AvTransport(d, "SetAVTransportURI", ("InstanceID", "0"), ("CurrentURI", uri), ("CurrentURIMetaData", metadata));
    }

    public Task<SoapResult> Play(SonosDevice d) => AvTransport(d, "Play", ("InstanceID", "0"), ("Speed", "1"));
    public Task<SoapResult> Pause(SonosDevice d) => AvTransport(d, "Pause", ("InstanceID", "0"));
    public Task<SoapResult> Stop(SonosDevice d) => AvTransport(d, "Stop", ("InstanceID", "0"));

    public Task<SoapResult> Seek(SonosDevice d, int seconds) =>
        AvTransport(d, "Seek", ("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", SoapXml.TimeString(seconds)));

    // ---- 原生佇列 ----

    public Task<SoapResult> RemoveAllTracksFromQueue(SonosDevice d) => AvTransport(d, "RemoveAllTracksFromQueue", ("InstanceID", "0"));

    /// <summary>
    /// 一次把多首塞進音箱佇列。firstTrackNumber 是這一批第一首應排在佇列第幾位（1 起）——
    /// 分批入隊時必須逐批遞增，否則每批都會擠到隊首，順序被打亂。
    /// </summary>
    public Task<SoapResult> AddMultipleURIsToQueue(SonosDevice d, IReadOnlyList<(string Url, string Metadata)> entries,
        int firstTrackNumber = 1, bool enqueueAsNext = false)
    {
        if (entries.Count == 0) return Task.FromResult(SoapResult.Success(""));
        return AvTransport(d, "AddMultipleURIsToQueue",
            ("InstanceID", "0"),
            ("UpdateID", "0"),
            ("NumberOfURIs", entries.Count.ToString()),
            ("EnqueuedURIs", string.Join(" ", entries.Select(e => e.Url))),
            ("EnqueuedURIsMetaData", string.Join(" ", entries.Select(e => e.Metadata))),
            ("ContainerURI", ""),
            ("ContainerMetaData", ""),
            ("DesiredFirstTrackNumberEnqueued", Math.Max(1, firstTrackNumber).ToString()),
            ("EnqueueAsNext", enqueueAsNext ? "1" : "0"));
    }

    /// <summary>讓傳輸層指向「音箱自己的佇列」</summary>
    public Task<SoapResult> SetQueueTransport(SonosDevice d)
    {
        var queueUri = $"x-rincon-queue:{d.Uuid}#0";
        return SetAVTransportURI(d, queueUri, SoapXml.QueueContainerDidl(queueUri));
    }

    /// <summary>NORMAL / REPEAT_ALL / REPEAT_ONE / SHUFFLE / SHUFFLE_NOREPEAT</summary>
    public Task<SoapResult> SetPlayMode(SonosDevice d, string mode) =>
        AvTransport(d, "SetPlayMode", ("InstanceID", "0"), ("NewPlayMode", mode));

    /// <summary>跳到佇列裡第 trackNumber 首（1 起）</summary>
    public Task<SoapResult> SeekToTrack(SonosDevice d, int trackNumber) =>
        AvTransport(d, "Seek", ("InstanceID", "0"), ("Unit", "TRACK_NR"), ("Target", Math.Max(1, trackNumber).ToString()));

    public Task<SoapResult> NextTrack(SonosDevice d) => AvTransport(d, "Next", ("InstanceID", "0"));
    public Task<SoapResult> PreviousTrack(SonosDevice d) => AvTransport(d, "Previous", ("InstanceID", "0"));

    public async Task<PositionInfo?> GetPositionInfo(SonosDevice d)
    {
        var result = await AvTransport(d, "GetPositionInfo", ("InstanceID", "0"));
        return result.IsSuccess ? ParsePositionInfo(result.Body) : null;
    }

    public static PositionInfo ParsePositionInfo(string body) => new(
        SoapXml.TagInt(body, "Track"),
        SoapXml.Unescape(SoapXml.TagText(body, "TrackURI") ?? "").Trim(),
        SoapXml.ParseTime(SoapXml.TagText(body, "RelTime")),
        SoapXml.ParseTime(SoapXml.TagText(body, "TrackDuration")));

    public async Task<int?> GetQueueTrackNumber(SonosDevice d) => (await GetPositionInfo(d))?.TrackNumber;
    public async Task<string?> GetPlaybackTrackUri(SonosDevice d) => (await GetPositionInfo(d))?.TrackUri;

    /// <summary>GetMediaInfo 的 NrTracks：報的是「目前 transport」的曲目數，必須在切到 x-rincon-queue 之後才讀。</summary>
    public async Task<int?> GetQueueSize(SonosDevice d)
    {
        var result = await AvTransport(d, "GetMediaInfo", ("InstanceID", "0"));
        return result.IsSuccess ? SoapXml.TagInt(result.Body, "NrTracks") : null;
    }

    /// <summary>目前 transport 的 CurrentURI（x-rincon-queue:… 代表在佇列模式）</summary>
    public async Task<string?> GetMediaUri(SonosDevice d)
    {
        var result = await AvTransport(d, "GetMediaInfo", ("InstanceID", "0"));
        return result.IsSuccess ? SoapXml.Unescape(SoapXml.TagText(result.Body, "CurrentURI") ?? "") : null;
    }

    /// <summary>PLAYING / PAUSED_PLAYBACK / STOPPED / TRANSITIONING</summary>
    public async Task<string?> GetTransportState(SonosDevice d)
    {
        var result = await AvTransport(d, "GetTransportInfo", ("InstanceID", "0"));
        return result.IsSuccess ? SoapXml.TagText(result.Body, "CurrentTransportState") : null;
    }

    public async Task<TransportSnapshot?> GetTransportSnapshot(SonosDevice d)
    {
        var infoResult = await AvTransport(d, "GetPositionInfo", ("InstanceID", "0"));
        if (!infoResult.IsSuccess) return null;
        var info = ParsePositionInfo(infoResult.Body);
        var state = await GetTransportState(d) ?? "STOPPED";
        // TrackMetaData 是兩層轉義的 DIDL：解一層拿到 DIDL，標題裡仍帶 &apos; 要再解一次
        var didl = SoapXml.Unescape(SoapXml.TagText(infoResult.Body, "TrackMetaData") ?? "");
        var title = SoapXml.Unescape(SoapXml.TagText(didl, "dc:title") ?? "");
        return new TransportSnapshot(state, info.TrackUri, title, info.PositionSec, info.DurationSec, info.TrackNumber ?? 0);
    }

    // ---- RenderingControl ----

    public Task<SoapResult> SetVolume(SonosDevice d, int volume) =>
        Call(d, SoapXml.ServiceRenderingControl, d.RenderingControlUrl, "SetVolume",
            ("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", Math.Clamp(volume, 0, 100).ToString()));

    public async Task<int?> GetVolume(SonosDevice d)
    {
        var result = await Call(d, SoapXml.ServiceRenderingControl, d.RenderingControlUrl, "GetVolume",
            ("InstanceID", "0"), ("Channel", "Master"));
        return result.IsSuccess ? SoapXml.TagInt(result.Body, "CurrentVolume") : null;
    }

    // ---- ZoneGroupTopology ----

    /// <summary>任一台在線音箱都能回答，回傳的是全域拓撲。</summary>
    public async Task<string?> GetZoneGroupState(SonosDevice d)
    {
        var result = await Call(d, SoapXml.ServiceZoneGroupTopology, ZoneGroupTopologyPath, "GetZoneGroupState");
        return result.IsSuccess ? result.Body : null;
    }

    // ---- 底層 ----

    private Task<SoapResult> AvTransport(SonosDevice d, string action, params (string, string)[] args) =>
        Call(d, SoapXml.ServiceAVTransport, d.AVTransportControlUrl, action, args);

    private async Task<SoapResult> Call(SonosDevice d, string serviceType, string controlPath, string action, params (string, string)[] args)
    {
        var url = $"http://{d.Ip}:{SonosDevice.Port}{controlPath}";
        var quiet = QuietActions.Contains(action);
        if (!quiet) LogBus.Log(LogLevel.Tx, $"POST {url} · {action}");
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, url);
            request.Content = new ByteArrayContent(Encoding.UTF8.GetBytes(SoapXml.Envelope(serviceType, action, args)));
            request.Content.Headers.TryAddWithoutValidation("Content-Type", "text/xml; charset=utf-8");
            request.Headers.TryAddWithoutValidation("SOAPACTION", $"\"{serviceType}#{action}\"");
            using var response = await _http.SendAsync(request);
            var status = (int)response.StatusCode;
            var body = await response.Content.ReadAsStringAsync();
            var errorCode = SoapXml.TagInt(body, "errorCode");
            var errorDescription = (SoapXml.TagText(body, "errorDescription") ?? "").Trim();
            if (status is >= 200 and < 300 && errorCode == null)
            {
                if (!quiet) LogBus.Log(LogLevel.Rx, $"{action} ← HTTP {status} OK");
                return SoapResult.Success(body);
            }
            var description = errorDescription.Length > 0 ? errorDescription
                : errorCode != null ? UpnpErrors.Describe(errorCode) : $"HTTP {status}";
            LogBus.Log(LogLevel.Rx, $"{action} ← HTTP {status} · UPnP {errorCode?.ToString() ?? "-"} {description}");
            return SoapResult.Fault(status, errorCode, description, body);
        }
        catch (Exception ex)
        {
            var message = ex is TaskCanceledException ? "timeout" : ex.Message;
            LogBus.E($"{action} 網路異常：{message}");
            return SoapResult.TransportError(message);
        }
    }
}
