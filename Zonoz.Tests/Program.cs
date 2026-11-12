using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Zonoz.Core;

// 離線測試：純邏輯 + 真的 HTTP 伺服器 + 對著 Tests/fake_sonos.py 跑播放引擎。
// 用法：dotnet run --project Zonoz.Tests -- core | http | queue | fallback

static class T
{
    public static int Checks, Failures;

    public static void Check(bool condition, string label, [System.Runtime.CompilerServices.CallerLineNumber] int line = 0)
    {
        Checks++;
        if (condition) Console.WriteLine($"  ok   {label}");
        else
        {
            Failures++;
            Console.WriteLine($"  FAIL {label}  (line {line})");
        }
    }
}

/// <summary>單執行緒的訊息幫浦：模擬 UI 執行緒，讓引擎的 await 都回到同一條執行緒。</summary>
sealed class PumpContext : SynchronizationContext
{
    private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> _queue = new();
    public override void Post(SendOrPostCallback d, object? state) => _queue.Add((d, state));
    public override void Send(SendOrPostCallback d, object? state) => d(state);

    public void RunUntil(Task task)
    {
        while (!task.IsCompleted)
            if (_queue.TryTake(out var work, 20)) work.Callback(work.State);
    }
}

sealed class TestPlatform : DesktopPlatform
{
    public bool SessionActive;
    public HashSet<string> BlockedIds = new();
    public override string? CurrentLanIP(SonosDevice? toward) => "127.0.0.1";
    public override Task<List<SonosDevice>> DiscoverAsync() => Task.FromResult(new List<SonosDevice>());
    public override AudioProbe.Format? ProbeFormat(Track track) =>
        BlockedIds.Contains(track.Id) ? new AudioProbe.Format("FLAC", 96000, 24) : null;
    public override void PlaybackSessionChanged(bool active) => SessionActive = active;
}

sealed class FakeFetch
{
    public string uri { get; set; } = "";
    public string range { get; set; } = "";
    public int status { get; set; }
    public string? type { get; set; }
    public string? content_range { get; set; }
    public int length { get; set; }
    public int declared { get; set; }
}

sealed class FakeState
{
    public List<string> queue { get; set; } = new();
    public string transport_uri { get; set; } = "";
    public int track { get; set; }
    public string state { get; set; } = "";
    public string mode { get; set; } = "";
    public int volume { get; set; }
    public double pos { get; set; }
    public List<string> calls { get; set; } = new();
    public string current_uri { get; set; } = "";
    public List<FakeFetch> fetches { get; set; } = new();
}

static class Program
{
    private static readonly HttpClient Http = new(new SocketsHttpHandler { UseProxy = false });
    private const int FileSize = 5000;

    private static async Task<FakeState> Fake() =>
        JsonSerializer.Deserialize<FakeState>(await Http.GetStringAsync("http://127.0.0.1:1400/__state"))!;

    private static Task Hardware(string command, string body = "") =>
        Http.PostAsync($"http://127.0.0.1:1400/__hw/{command}", new StringContent(body));

    private static async Task<bool> WaitUntil(Func<bool> condition, double timeout = 12)
    {
        var deadline = DateTime.UtcNow.AddSeconds(timeout);
        while (DateTime.UtcNow < deadline)
        {
            if (condition()) return true;
            await Task.Delay(100);
        }
        return condition();
    }

    private static List<Track> MakeLibrary(int count, string dir)
    {
        var list = new List<Track>();
        for (var i = 0; i < count; i++)
        {
            var path = Path.Combine(dir, $"{i:00} It's (A&B).m4a");
            var bytes = new byte[FileSize];
            for (var b = 0; b < bytes.Length; b++) bytes[b] = (byte)((b + i) % 251);
            File.WriteAllBytes(path, bytes);
            list.Add(new Track
            {
                Id = Track.FileIdFor(path), Path = path, Title = $"Song {i} It's <A&B>", Artist = "X", Album = "Y",
                DurationMs = 200_000, SizeBytes = FileSize, MimeType = "audio/mp4",
            });
        }
        return list;
    }

    private static string Url(Track t, int port) => $"http://127.0.0.1:{port}/stream/{t.Id}.m4a";

    // ---------------- 純邏輯 ----------------

    private static void CoreTests()
    {
        Console.WriteLine("== SoapXml");
        T.Check(SoapXml.Escape("a<b>&\"'") == "a&lt;b&gt;&amp;&quot;&apos;", "escape");
        T.Check(SoapXml.Unescape("You&amp;apos;re &lt;b&gt;") == "You&apos;re <b>", "unescape 一層");
        T.Check(SoapXml.TimeString(3725) == "01:02:05", "timeString");
        T.Check(SoapXml.ParseTime("0:01:23") == 83 && SoapXml.ParseTime("1:23") == 83, "parseTime");
        T.Check(SoapXml.ParseTime("0:03:25.000") == 205 && SoapXml.ParseTime("NOT_IMPLEMENTED") == 0, "parseTime 邊界");
        var didl = SoapXml.DidlLite("A&B", "http://1.2.3.4:8080/stream/x.mp3", "audio/mpeg", "7");
        T.Check(didl.Contains("<dc:title>A&amp;B</dc:title>") && didl.Contains("protocolInfo=\"http-get:*:audio/mpeg:*\""), "didl");
        var env = SoapXml.Envelope(SoapXml.ServiceAVTransport, "SetAVTransportURI", new[] { ("CurrentURIMetaData", didl) });
        T.Check(env.Contains("&lt;DIDL-Lite") && env.Contains("A&amp;amp;B") && !env.Contains("<DIDL-Lite"), "DIDL 作為參數時被整段轉義");
        var info = SonosSoapClient.ParsePositionInfo(
            "<Track>12</Track><TrackDuration>0:04:05</TrackDuration><TrackURI>http://h:1/stream/abc.flac</TrackURI><RelTime>0:00:09</RelTime>");
        T.Check(info.TrackNumber == 12 && info.DurationSec == 245 && info.PositionSec == 9 && info.TrackUri.EndsWith("abc.flac"), "parsePositionInfo");
        T.Check(MediaRegistry.FileIdFromStreamUri(info.TrackUri) == "abc", "fileId 從 TrackURI 取回");
        T.Check(MediaRegistry.FileIdFromStreamUri("x-sonos-spotify:abc") == null, "外部來源沒有 fileId");

        Console.WriteLine("== DeviceDescription / ZoneTopology / SSDP");
        var desc = """
            <root><device><friendlyName>192.168.1.4 - Sonos Arc</friendlyName><manufacturer>Sonos, Inc.</manufacturer>
            <modelName>Sonos Arc</modelName><swGen>2</swGen><roomName>客廳 &amp; TV</roomName><UDN>uuid:RINCON_AAA01400</UDN>
            <serviceList><service><serviceType>urn:schemas-upnp-org:service:AlarmClock:1</serviceType><controlURL>/AlarmClock/Control</controlURL></service></serviceList>
            <deviceList><device><serviceList>
            <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/MediaRenderer/RenderingControl/Control</controlURL></service>
            <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/MediaRenderer/AVTransport/Control</controlURL></service>
            </serviceList></device></deviceList></device></root>
            """;
        var dev = DeviceDescription.Parse("http://192.168.1.4:1400/xml/device_description.xml", desc, DiscoverySource.Ssdp);
        T.Check(dev is { Uuid: "RINCON_AAA01400", Ip: "192.168.1.4", RoomName: "客廳 & TV", SwGen: 2 }, "裝置描述");
        T.Check(dev?.AVTransportControlUrl == "/MediaRenderer/AVTransport/Control" && dev.IsSonos, "控制路徑");
        var topo = """
            <ZoneGroupState><ZoneGroups><ZoneGroup Coordinator="RINCON_AAA01400" ID="RINCON_AAA01400:1">
            <ZoneGroupMember UUID="RINCON_AAA01400" ZoneName="客廳" SWGen="2" ChannelMapSet="RINCON_AAA01400:RF,RF;RINCON_BBB01400:LF,LF"/>
            <ZoneGroupMember UUID="RINCON_BBB01400" ZoneName="客廳" Invisible="1" ChannelMapSet="RINCON_AAA01400:RF,RF;RINCON_BBB01400:LF,LF"/>
            </ZoneGroup><ZoneGroup Coordinator="RINCON_CCC01400" ID="RINCON_CCC01400:2">
            <ZoneGroupMember UUID="RINCON_CCC01400" ZoneName="臥室"><Satellite UUID="RINCON_DDD01400" Invisible="1" HTSatChanMapSet="RINCON_CCC01400:LF,RF;RINCON_DDD01400:SW"/></ZoneGroupMember>
            </ZoneGroup></ZoneGroups></ZoneGroupState>
            """;
        var nodes = ZoneTopology.Parse($"<s:Body><ZoneGroupState>{SoapXml.Escape(topo)}</ZoneGroupState></s:Body>");
        var byId = nodes.ToDictionary(n => n.Uuid);
        T.Check(nodes.Count == 4, $"拓撲節點數 = 4（實際 {nodes.Count}）");
        T.Check(!byId["RINCON_AAA01400"].IsSatellite && byId["RINCON_AAA01400"].Channel == "RF", "主箱");
        T.Check(byId["RINCON_BBB01400"].IsSatellite && byId["RINCON_BBB01400"].Channel == "LF", "配對從箱");
        T.Check(!byId["RINCON_CCC01400"].IsSatellite && byId["RINCON_DDD01400"].IsSatellite, "家庭劇院衛星");
        T.Check(SsdpDiscovery.ParseLocation("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age = 1800\r\nLocation: http://192.168.1.4:1400/xml/device_description.xml\r\nST: x\r\n\r\n")
                == "http://192.168.1.4:1400/xml/device_description.xml", "SSDP LOCATION");

        Console.WriteLine("== HTTP 解析");
        var head = HttpRequestHead.Parse("GET /stream/0a1b2c3d4e5f.flac HTTP/1.1\r\nHost: 192.168.1.9:8080\r\nRange: bytes=100-\r\nUser-Agent: Sonos");
        T.Check(head is { Method: "GET" } && head.StreamFileId() == "0a1b2c3d4e5f" && head.Headers["range"] == "bytes=100-", "請求頭");
        T.Check(HttpRequestHead.Parse("HEAD /stream?fileId=zz HTTP/1.0")?.StreamFileId() == "zz", "query fileId");
        T.Check(ByteRange.Parse("bytes=0-", 1000) == new ByteRange(0, 999), "bytes=0-");
        T.Check(ByteRange.Parse("bytes=100-199", 1000)?.Length == 100, "bytes=100-199");
        T.Check(ByteRange.Parse("bytes=-500", 1000) == new ByteRange(500, 999), "bytes=-500");
        T.Check(ByteRange.Parse("bytes=900-5000", 1000) == new ByteRange(900, 999), "end 夾到檔尾");
        T.Check(ByteRange.Parse(null, 1000) == null, "無 Range → 200");
        var threw = false;
        try { ByteRange.Parse("bytes=1000-", 1000); } catch (RangeNotSatisfiableException) { threw = true; }
        T.Check(threw, "越界 → 416");

        Console.WriteLine("== AudioProbe / Dolby / Mime");
        var flac = new byte[64];
        Encoding.ASCII.GetBytes("fLaC").CopyTo(flac, 0);
        flac[18] = 0x17; flac[19] = 0x70; flac[20] = 0x03; flac[21] = 0x70;   // 96000 Hz, 2ch, 24 bit
        var f = AudioProbe.Probe(flac);
        T.Check(f == new AudioProbe.Format("FLAC", 96000, 24) && AudioProbe.IsUnsupported(f), "FLAC 96k/24 → 擋下");
        T.Check(AudioProbe.Describe(new AudioProbe.Format("FLAC", 44100, 16)) == "FLAC 44.1 kHz / 16 bit", "describe");
        var wav = new byte[64];
        Encoding.ASCII.GetBytes("RIFF").CopyTo(wav, 0); Encoding.ASCII.GetBytes("WAVE").CopyTo(wav, 8);
        Encoding.ASCII.GetBytes("fmt ").CopyTo(wav, 12); wav[16] = 16; wav[24] = 0x80; wav[25] = 0xBB; wav[34] = 24;
        var w = AudioProbe.Probe(wav);
        T.Check(w == new AudioProbe.Format("WAV", 48000, 24) && AudioProbe.IsUnsupported(w), "WAV 48k/24 → 擋下");
        byte[] joc = { 0x18, 0x00, 0x20, 0x0F, 0x00, 0x01, 0x10 };
        T.Check(Dolby.ParseDec3(joc) == new Dolby.Ec3Info(true, 16), "dec3 JOC");
        T.Check(Dolby.ParseDec3(joc[..5]) == new Dolby.Ec3Info(false, 0), "dec3 無 JOC");
        var moov = new List<byte>();
        moov.AddRange(new byte[] { 0, 0, 0, 36 }); moov.AddRange(Encoding.ASCII.GetBytes("stsd")); moov.AddRange(new byte[8]);
        moov.AddRange(new byte[] { 0, 0, 0, 20 }); moov.AddRange(Encoding.ASCII.GetBytes("ec-3")); moov.AddRange(new byte[12]);
        moov.AddRange(new byte[] { 0, 0, 0, 15 }); moov.AddRange(Encoding.ASCII.GetBytes("dec3")); moov.AddRange(joc);
        T.Check(Mp4Info.FromMoov(moov.ToArray()) == new Mp4Info.Result("ec-3", true), "moov：ec-3 + JOC → Atmos");
        T.Check(MimeTypes.Resolve("a.b.FLAC") == "audio/flac" && MimeTypes.UrlSuffix("audio/mp4") == ".m4a" && MimeTypes.IsAudioExtension(".M4A"), "mime");
        T.Check(NetUtils.SubnetHosts("192.168.1.37").Count == 253 && NetUtils.IsValidIPv4("10.0.0.5") && !NetUtils.IsValidIPv4("10.0.0.256"), "網段");
        T.Check(Track.FileIdFor(@"C:\Music\A.mp3") == Track.FileIdFor(@"c:\music\a.MP3") && Track.FileIdFor("x").Length == 12, "fileId 不分大小寫、12 位");
    }

    // ---------------- 真的 HTTP 伺服器 ----------------

    private static async Task HttpTests()
    {
        Console.WriteLine("== LocalMediaServer");
        var dir = Directory.CreateTempSubdirectory("zonoz-http").FullName;
        var library = MakeLibrary(1, dir);
        var track = library[0];
        var expected = File.ReadAllBytes(track.Path);
        MediaRegistry.Shared.ReplaceAll(library);
        var server = new LocalMediaServer();
        var port = server.Start(18080);
        T.Check(port != null && server.IsRunning, $"伺服器啟動（埠 {port}）");
        var second = new LocalMediaServer();
        var port2 = second.Start(port!.Value);
        T.Check(port2 != null && port2 != port, $"埠被佔用時自動換下一個（{port2}）");
        second.Stop();
        var url = Url(track, port.Value);

        var full = await Http.GetAsync(url);
        var body = await full.Content.ReadAsByteArrayAsync();
        T.Check((int)full.StatusCode == 200 && body.SequenceEqual(expected), "GET 全檔 200，內容一致");
        T.Check(full.Content.Headers.ContentType?.MediaType == "audio/mp4" && full.Headers.AcceptRanges.Contains("bytes"), "Content-Type / Accept-Ranges");

        async Task<HttpResponseMessage> Ranged(string range, HttpMethod? method = null)
        {
            var request = new HttpRequestMessage(method ?? HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation("Range", range);
            return await Http.SendAsync(request);
        }

        var probe = await Ranged("bytes=0-");
        T.Check((int)probe.StatusCode == 206 && probe.Content.Headers.ContentRange?.ToString() == $"bytes 0-{FileSize - 1}/{FileSize}"
                && (await probe.Content.ReadAsByteArrayAsync()).Length == FileSize, "Range bytes=0- → 206 全長");
        var mid = await Ranged("bytes=100-199");
        var midBody = await mid.Content.ReadAsByteArrayAsync();
        T.Check((int)mid.StatusCode == 206 && mid.Content.Headers.ContentLength == 100 && midBody.SequenceEqual(expected[100..200]), "bytes=100-199 內容正確");
        var tail = await Ranged("bytes=-500");
        T.Check((int)tail.StatusCode == 206 && (await tail.Content.ReadAsByteArrayAsync()).SequenceEqual(expected[^500..]), "bytes=-500 內容正確");
        var seek = await Ranged("bytes=4000-");
        T.Check((int)seek.StatusCode == 206 && (await seek.Content.ReadAsByteArrayAsync()).SequenceEqual(expected[4000..]), "bytes=4000-（拖進度）內容正確");
        var beyond = await Ranged($"bytes={FileSize}-");
        T.Check((int)beyond.StatusCode == 416 && beyond.Content.Headers.ContentRange?.ToString() == $"bytes */{FileSize}", "越界 → 416");
        var headResponse = await Ranged("bytes=0-", HttpMethod.Head);
        T.Check((int)headResponse.StatusCode == 206 && headResponse.Content.Headers.ContentLength == FileSize, "HEAD 帶 Range");
        T.Check((int)(await Http.GetAsync($"http://127.0.0.1:{port}/stream/ffffffffffff.m4a")).StatusCode == 404, "未知 fileId → 404");
        T.Check(await Http.GetStringAsync($"http://127.0.0.1:{port}/health") == "OK", "/health");
        T.Check((await Http.GetStringAsync($"http://127.0.0.1:{port}/")).Contains("ZONOZ"), "首頁");
        T.Check((int)(await Http.PostAsync(url, new StringContent("x"))).StatusCode == 405, "POST → 405");

        // 併發：音箱常同時開好幾條連線
        var parallel = await Task.WhenAll(Enumerable.Range(0, 16).Select(_ => Http.GetByteArrayAsync(url)));
        T.Check(parallel.All(p => p.SequenceEqual(expected)), "16 條併發連線內容都正確");

        Console.WriteLine("== MusicLibrary");
        var lib = new MusicLibrary(null, Path.Combine(dir, "cache.json"));
        Directory.CreateDirectory(Path.Combine(dir, "sub"));
        File.WriteAllBytes(Path.Combine(dir, "sub", "b song.flac"), new byte[10]);
        File.WriteAllText(Path.Combine(dir, "notes.txt"), "x");
        var scanned = await lib.ScanAsync(new[] { dir, dir }, LibrarySort.Title);
        T.Check(scanned.Count == 2 && scanned.Any(t => t.MimeType == "audio/flac" && t.Title == "b song"), "遞迴掃描、只收音檔、重複資料夾不重複計");
        var again = await lib.ScanAsync(new[] { dir }, LibrarySort.Title);
        T.Check(again.Select(t => t.Id).SequenceEqual(scanned.Select(t => t.Id)), "第二次掃描（走快取）結果一致");
        T.Check(MusicLibrary.Filter(scanned, "B SONG").Count == 1, "搜尋不分大小寫");
        server.Stop();
        Directory.Delete(dir, true);
    }

    // ---------------- 引擎整合（需要 fake_sonos.py --fetch） ----------------

    private static async Task EngineTests(string mode)
    {
        var dir = Directory.CreateTempSubdirectory("zonoz-engine").FullName;
        var library = MakeLibrary(30, dir);
        MediaRegistry.Shared.ReplaceAll(library);
        var settings = AppSettings.Load(Path.Combine(dir, "settings.json"));
        var platform = new TestPlatform();
        var engine = new CastEngine(platform, settings);
        engine.LibraryChanged(library);
        engine.Start();
        await Task.Delay(500);
        engine.AddManualDevice("127.0.0.1");
        T.Check(await WaitUntil(() => engine.SelectedDevices().Count == 1), "手動加入音箱並自動選取");
        T.Check(engine.Devices.FirstOrDefault() is { RoomName: "Fake Room", SwGen: 2 }, "讀到房間名 / S2");
        T.Check(engine.ServerPort > 0, $"HTTP 伺服器已啟動（埠 {engine.ServerPort}）");
        var port = engine.ServerPort;
        string Expect(Track t) => Url(t, port);

        if (mode == "fallback")
        {
            Console.WriteLine("== 佇列被拒 → 退回逐首推送");
            engine.Play(library[3], library);
            T.Check(await WaitUntil(() => !engine.Busy && engine.IsPlaying), "仍然開始播放");
            var s = await Fake();
            T.Check(!engine.NativeQueueActive && s.transport_uri == Expect(library[3]) && s.state == "PLAYING", "逐首推送的 URL 正確");
            T.Check(platform.SessionActive, "已要求阻止睡眠");
            await Task.Delay(11_000);   // 超過切歌防抖時間
            await Hardware("end");
            for (var i = 0; i < 80; i++)
            {
                s = await Fake();
                if (s.state == "PLAYING") break;
                await Task.Delay(100);
            }
            T.Check(s.state == "PLAYING" && s.transport_uri == Expect(library[3]) && engine.CurrentTrack?.Id == library[3].Id, "提前 STOPPED → 續播同一首而不是跳歌");
            engine.Next();
            T.Check(await WaitUntil(() => !engine.Busy && engine.CurrentTrack?.Id == library[4].Id), "下一首");
            await Task.Delay(500);
            s = await Fake();
            T.Check(s.transport_uri == Expect(library[4]) && s.state == "PLAYING", "下一首以逐首推送送出");
            T.Check(s.fetches.Count >= 2 && s.fetches.All(x => x.status == 206 && x.type == "audio/mp4" && x.length == x.declared), "假音箱抓串流：206、MIME 與長度正確");
            await engine.StopAsync();
            return;
        }

        Console.WriteLine("== 原生佇列");
        engine.Play(library[7], library);
        T.Check(await WaitUntil(() => !engine.Busy && engine.NativeQueueActive), "佇列建立完成");
        var st = await Fake();
        T.Check(st.queue.SequenceEqual(library.Select(Expect)), $"音箱佇列順序與清單一致（{st.queue.Count} 首）");
        T.Check(st.transport_uri.StartsWith("x-rincon-queue:RINCON_FAKE") && st.track == 8 && st.state == "PLAYING", "切到佇列傳輸、定位第 8 首、播放中");
        T.Check(st.mode == "REPEAT_ALL" && engine.QueueIndex == 7 && engine.IsPlaying, "播放模式 / 介面狀態");
        T.Check(st.calls.Count(c => c == "AddMultipleURIsToQueue") >= 3, $"分批入隊（{st.calls.Count(c => c == "AddMultipleURIsToQueue")} 次）");
        await Task.Delay(600);
        st = await Fake();
        var first = st.fetches.FirstOrDefault(x => x.range == "bytes=0-");
        var seekFetch = st.fetches.FirstOrDefault(x => x.range == "bytes=1000-1999");
        T.Check(first is { status: 206, type: "audio/mp4", length: FileSize } && first.content_range == $"bytes 0-{FileSize - 1}/{FileSize}", "假音箱抓串流：Range 探測 206、長度正確");
        T.Check(seekFetch is { status: 206, length: 1000 } && seekFetch.content_range == $"bytes 1000-1999/{FileSize}", "假音箱續抓中段：206、Content-Range 正確");
        T.Check(first != null && first.uri == Expect(library[7]), "抓的是第 8 首的網址");

        engine.Next();
        await Task.Delay(1000);
        st = await Fake();
        T.Check(st.track == 9 && engine.CurrentTrack?.Id == library[8].Id, "App 下一首 → 音箱 Next");

        await Task.Delay(1500);
        await Hardware("next");
        T.Check(await WaitUntil(() => engine.CurrentTrack?.Id == library[9].Id), "機身下一首 → 介面跟上");

        await Hardware("pause");
        T.Check(await WaitUntil(() => !engine.IsPlaying && engine.HasSession), "機身暫停 → 介面暫停");
        engine.Resume();
        T.Check(await WaitUntil(() => engine.IsPlaying), "繼續播放");
        T.Check((await Fake()).state == "PLAYING", "音箱恢復播放");

        await Hardware("volume", "41");
        T.Check(await WaitUntil(() => engine.Volume == 41, 15), "音量從音箱同步回來");
        engine.SetVolume(17);
        await Task.Delay(600);
        T.Check((await Fake()).volume == 17, "設定音量");

        Console.WriteLine("== 下一首播放 / 隨機 / 循環");
        var currentId = engine.CurrentTrack!.Id;
        engine.InsertNext(library[25]);
        await Task.Delay(1000);
        st = await Fake();
        T.Check(st.queue[st.track] == Expect(library[25]) && st.current_uri == Expect(engine.CurrentTrack!), "插在目前這首後面，目前曲不變");
        T.Check(st.queue.SequenceEqual(engine.Queue.Select(Expect)), "音箱佇列 = App 清單");

        engine.Seek(60);
        await Task.Delay(2500);
        engine.ToggleShuffle();
        T.Check(await WaitUntil(() => !engine.Busy && engine.Shuffle), "切到隨機");
        await Task.Delay(500);
        st = await Fake();
        T.Check(engine.CurrentTrack?.Id == currentId && engine.QueueIndex == 0, "隨機後目前曲排第一");
        T.Check(st.queue.SequenceEqual(engine.Queue.Select(Expect)) && st.current_uri == Expect(engine.CurrentTrack!), "音箱佇列按新順序重建，目前曲不變");
        T.Check(st.pos >= 55 && st.state == "PLAYING", $"重建後回到原本的秒數（{(int)st.pos}s）而不是從頭播");

        engine.CycleRepeat();
        T.Check(await WaitUntil(() => !engine.Busy && engine.RepeatMode == RepeatMode.One && !engine.Shuffle), "切到單曲循環");
        await Task.Delay(1000);
        T.Check((await Fake()).mode == "REPEAT_ONE", "音箱播放模式 REPEAT_ONE");
        var reloaded = AppSettings.Load(settings.FilePath);
        T.Check(reloaded.RepeatMode == "one" && !reloaded.Shuffle && reloaded.SelectedKeys.Count == 1 && reloaded.KnownIPs.Contains("127.0.0.1"), "設定已寫入磁碟");

        Console.WriteLine("== 不支援的格式 / 外部來源 / 停止");
        platform.BlockedIds = new HashSet<string> { library[2].Id };
        engine.Play(library[2], library);
        T.Check(await WaitUntil(() => !engine.Busy && engine.Hint?.Kind == HintKind.UnsupportedFormat), "96k FLAC 被擋下並提示");
        platform.BlockedIds = new HashSet<string>();

        engine.Play(library[5], library);
        T.Check(await WaitUntil(() => !engine.Busy && engine.IsPlaying && engine.CurrentTrack?.Id == library[5].Id), "重新點歌");
        await Task.Delay(2000);
        await Hardware("external");
        T.Check(await WaitUntil(() => engine.ExternalSource), "偵測到音箱被其他來源接手");
        var callsBefore = (await Fake()).calls.Count;
        await engine.StopAsync();
        st = await Fake();
        T.Check(!st.calls.Skip(callsBefore).Contains("Stop") && !engine.HasSession && !platform.SessionActive, "不去停別人的播放，只放掉本地狀態");

        engine.Play(library[1], library);
        T.Check(await WaitUntil(() => !engine.Busy && engine.IsPlaying), "再次播放");
        await engine.StopAsync();
        T.Check((await Fake()).state == "STOPPED" && !engine.HasSession, "關閉前停止：音箱收到 Stop");
        engine.Shutdown();
        try { Directory.Delete(dir, true); } catch { }
    }

    private static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        var mode = args.Length > 0 ? args[0] : "core";
        var context = new PumpContext();
        SynchronizationContext.SetSynchronizationContext(context);
        Task task = mode switch
        {
            "core" => Task.Run(CoreTests),
            "http" => HttpTests(),
            _ => EngineTests(mode),
        };
        context.RunUntil(task);
        if (task.IsFaulted)
        {
            Console.WriteLine($"  FAIL 測試本身丟出例外：{task.Exception?.GetBaseException()}");
            T.Failures++;
        }
        Console.WriteLine($"\n{T.Checks - T.Failures}/{T.Checks} 通過");
        return T.Failures == 0 ? 0 : 1;
    }
}
