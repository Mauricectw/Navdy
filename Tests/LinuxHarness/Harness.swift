import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 離線測試：純邏輯單元測試 + 對著 fake_sonos.py 跑播放引擎。
// 執行方式見 Tests/run_linux_tests.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String, line: Int = #line) {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)  (line \(line))")
    }
}

@MainActor
final class FakePlatform: EnginePlatform {
    var port = 8080
    var sessionActive = false
    var nowPlayingUpdates = 0
    var blockedIds: Set<String> = []
    func currentLanIP() -> String? { "127.0.0.1" }
    func ensureServer(force: Bool) async -> Int? { port }
    func restartServerOnNewPort() async -> Int? { port += 1; return port }
    func discover(localIP: String?) async -> [SonosDevice] { [] }
    func probeFormat(of track: Track) -> AudioProbe.Format? {
        blockedIds.contains(track.id) ? AudioProbe.Format(codec: "FLAC", sampleRate: 96000, bits: 24) : nil
    }
    func playbackSessionChanged(active: Bool) { sessionActive = active }
    func nowPlayingChanged() { nowPlayingUpdates += 1 }
    func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
}

struct FakeState: Decodable {
    var queue: [String]
    var transport_uri: String
    var track: Int
    var state: String
    var mode: String
    var volume: Int
    var pos: Double
    var calls: [String]
    var current_uri: String
}

func fakeState() async -> FakeState {
    let request = URLRequest(url: URL(string: "http://127.0.0.1:1400/__state")!)
    if case .response(_, let data) = await HTTP.perform(URLSession.shared, request),
       let state = try? JSONDecoder().decode(FakeState.self, from: data) {
        return state
    }
    fatalError("fake_sonos.py 沒在跑")
}

func hardware(_ command: String, body: String = "") async {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:1400/__hw/\(command)")!)
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    _ = await HTTP.perform(URLSession.shared, request)
}

func sleep(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
func waitUntil(_ timeout: Double = 12, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        await sleep(0.1)
    }
    return condition()
}

func makeLibrary(_ count: Int) -> [Track] {
    return (0..<count).map { i in
        let id = String(format: "%012x", 0xabc000 + i)
        return Track(id: id, relPath: "Album/\(i) It's <A&B>.m4a", title: "Song \(i) It's <A&B>", artist: "X", album: "Y",
                     durationMs: 200_000, sizeBytes: 1000, mimeType: "audio/mp4", modified: 0)
    }
}

func expectedUrl(_ t: Track, port: Int = 8080) -> String {
    return "http://127.0.0.1:\(port)/stream/\(t.id).m4a"
}

// MARK: - 純邏輯

func coreTests() {
    print("== SoapXml")
    check(SoapXml.escape("a<b>&\"'") == "a&lt;b&gt;&amp;&quot;&apos;", "escape")
    check(SoapXml.unescape("You&amp;apos;re &lt;b&gt;") == "You&apos;re <b>", "unescape 一層")
    check(SoapXml.timeString(3725) == "01:02:05", "timeString")
    check(SoapXml.parseTime("0:01:23") == 83 && SoapXml.parseTime("1:23") == 83, "parseTime")
    check(SoapXml.parseTime("0:03:25.000") == 205 && SoapXml.parseTime("NOT_IMPLEMENTED") == 0, "parseTime 邊界")
    let didl = SoapXml.didlLite(title: "A&B", url: "http://1.2.3.4:8080/stream/x.mp3", mimeType: "audio/mpeg", id: "7")
    check(didl.contains("<dc:title>A&amp;B</dc:title>") && didl.contains("protocolInfo=\"http-get:*:audio/mpeg:*\""), "didl")
    let env = SoapXml.envelope(serviceType: SoapXml.serviceAVTransport, action: "SetAVTransportURI",
                               args: [("CurrentURIMetaData", didl)])
    check(env.contains("&lt;DIDL-Lite") && env.contains("A&amp;amp;B") && !env.contains("<DIDL-Lite"), "DIDL 作為參數時被整段轉義")
    let body = "<Track>12</Track><TrackDuration>0:04:05</TrackDuration><TrackURI>http://h:1/stream/abc.flac</TrackURI><RelTime>0:00:09</RelTime>"
    let info = SonosSoapClient.parsePositionInfo(body)
    check(info.trackNumber == 12 && info.durationSec == 245 && info.positionSec == 9 && info.trackUri.hasSuffix("abc.flac"), "parsePositionInfo")
    check(MediaRegistry.fileId(fromStreamUri: info.trackUri) == "abc", "fileId 從 TrackURI 取回")
    check(MediaRegistry.fileId(fromStreamUri: "x-sonos-spotify:abc") == nil, "外部來源沒有 fileId")

    print("== DeviceDescription / ZoneTopology")
    let desc = """
    <root><device><friendlyName>192.168.1.4 - Sonos Arc</friendlyName><manufacturer>Sonos, Inc.</manufacturer>
    <modelName>Sonos Arc</modelName><swGen>2</swGen><roomName>客廳 &amp; TV</roomName><UDN>uuid:RINCON_AAA01400</UDN>
    <serviceList><service><serviceType>urn:schemas-upnp-org:service:AlarmClock:1</serviceType><controlURL>/AlarmClock/Control</controlURL></service></serviceList>
    <deviceList><device><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/MediaRenderer/RenderingControl/Control</controlURL></service>
    <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/MediaRenderer/AVTransport/Control</controlURL></service>
    </serviceList></device></deviceList></device></root>
    """
    let dev = DeviceDescription.parse(location: "http://192.168.1.4:1400/xml/device_description.xml", xml: desc, source: .subnet)
    check(dev?.uuid == "RINCON_AAA01400" && dev?.ip == "192.168.1.4" && dev?.roomName == "客廳 & TV" && dev?.swGen == 2, "裝置描述")
    check(dev?.avTransportControlUrl == "/MediaRenderer/AVTransport/Control" && dev?.isSonos == true, "控制路徑")
    let topo = """
    <ZoneGroupState><ZoneGroups><ZoneGroup Coordinator="RINCON_AAA01400" ID="RINCON_AAA01400:1">
    <ZoneGroupMember UUID="RINCON_AAA01400" ZoneName="客廳" SWGen="2" ChannelMapSet="RINCON_AAA01400:RF,RF;RINCON_BBB01400:LF,LF"/>
    <ZoneGroupMember UUID="RINCON_BBB01400" ZoneName="客廳" Invisible="1" ChannelMapSet="RINCON_AAA01400:RF,RF;RINCON_BBB01400:LF,LF"/>
    </ZoneGroup><ZoneGroup Coordinator="RINCON_CCC01400" ID="RINCON_CCC01400:2">
    <ZoneGroupMember UUID="RINCON_CCC01400" ZoneName="臥室"><Satellite UUID="RINCON_DDD01400" Invisible="1" HTSatChanMapSet="RINCON_CCC01400:LF,RF;RINCON_DDD01400:SW"/></ZoneGroupMember>
    </ZoneGroup></ZoneGroups></ZoneGroupState>
    """
    let soapBody = "<s:Body><u:GetZoneGroupStateResponse><ZoneGroupState>\(SoapXml.escape(topo))</ZoneGroupState></u:GetZoneGroupStateResponse></s:Body>"
    let nodes = ZoneTopology.parse(soapBody: soapBody)
    let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.uuid, $0) })
    check(nodes.count == 4, "拓撲節點數 = 4（實際 \(nodes.count)）")
    check(byId["RINCON_AAA01400"]?.isSatellite == false && byId["RINCON_AAA01400"]?.channel == "RF", "主箱")
    check(byId["RINCON_BBB01400"]?.isSatellite == true && byId["RINCON_BBB01400"]?.channel == "LF", "配對從箱")
    check(byId["RINCON_CCC01400"]?.isSatellite == false && byId["RINCON_DDD01400"]?.isSatellite == true, "家庭劇院衛星")

    print("== HTTP")
    let head = HTTPRequestHead.parse("GET /stream/0a1b2c3d4e5f.flac HTTP/1.1\r\nHost: 192.168.1.9:8080\r\nRange: bytes=100-\r\nUser-Agent: Linux UPnP/1.0 Sonos/86")
    check(head?.method == "GET" && head?.streamFileId() == "0a1b2c3d4e5f" && head?.headers["range"] == "bytes=100-", "請求頭")
    check(HTTPRequestHead.parse("HEAD /stream?fileId=zz HTTP/1.0")?.streamFileId() == "zz", "query fileId")
    check((try? ByteRange.parse(header: "bytes=0-", total: 1000)) == ByteRange(start: 0, end: 999), "bytes=0-")
    check((try? ByteRange.parse(header: "bytes=100-199", total: 1000))??.length == 100, "bytes=100-199")
    check((try? ByteRange.parse(header: "bytes=-500", total: 1000)) == ByteRange(start: 500, end: 999), "bytes=-500")
    check((try? ByteRange.parse(header: "bytes=900-5000", total: 1000)) == ByteRange(start: 900, end: 999), "end 夾到檔尾")
    check((try? ByteRange.parse(header: nil, total: 1000)) == .some(nil), "無 Range → 200")
    var threw = false
    do { _ = try ByteRange.parse(header: "bytes=1000-", total: 1000) } catch { threw = true }
    check(threw, "越界 → 416")

    print("== AudioProbe / Dolby / Mime")
    var flac = [UInt8](repeating: 0, count: 64)
    flac.replaceSubrange(0..<4, with: Array("fLaC".utf8))
    // 96000 Hz = 0x17700, 2ch, 24bit：位元組 18..21 = 17 70 03 70
    flac[18] = 0x17; flac[19] = 0x70; flac[20] = 0x03; flac[21] = 0x70
    let f = AudioProbe.probe(header: flac)
    check(f == AudioProbe.Format(codec: "FLAC", sampleRate: 96000, bits: 24) && AudioProbe.isUnsupported(f), "FLAC 96k/24 → 擋下")
    check(AudioProbe.describe(AudioProbe.Format(codec: "FLAC", sampleRate: 44100, bits: 16)) == "FLAC 44.1 kHz / 16 bit", "describe")
    var wav = [UInt8](repeating: 0, count: 64)
    wav.replaceSubrange(0..<4, with: Array("RIFF".utf8)); wav.replaceSubrange(8..<12, with: Array("WAVE".utf8))
    wav.replaceSubrange(12..<16, with: Array("fmt ".utf8)); wav[16] = 16
    wav[24] = 0x80; wav[25] = 0xBB   // 48000
    wav[34] = 24
    let w = AudioProbe.probe(header: wav)
    check(w == AudioProbe.Format(codec: "WAV", sampleRate: 48000, bits: 24) && AudioProbe.isUnsupported(w), "WAV 48k/24 → 擋下")
    // dec3：data_rate=768, 1 個獨立子串流, 5.1, 無相依子串流 + JOC 旗標, complexity 16
    let joc: [UInt8] = [0x18, 0x00, 0x20, 0x0F, 0x00, 0x01, 0x10]
    check(Dolby.parseDec3(payload: joc) == Dolby.Ec3Info(isJOC: true, complexityIndex: 16), "dec3 JOC")
    check(Dolby.parseDec3(payload: Array(joc[0..<5])) == Dolby.Ec3Info(isJOC: false, complexityIndex: 0), "dec3 無 JOC")
    let moov: [UInt8] = [0, 0, 0, 8] + Array("free".utf8) + [0, 0, 0, 15] + Array("dec3".utf8) + joc
    check(Dolby.findDec3(inMoov: moov).map { Dolby.parseDec3(payload: $0)?.isJOC } == .some(true), "在 moov 裡找到 dec3")
    check(MimeTypes.resolve(fileName: "a.b.FLAC") == "audio/flac" && MimeTypes.urlSuffix("audio/mp4") == ".m4a", "mime")
    check(DeviceProber.subnetHosts(localIP: "192.168.1.37").count == 253 && DeviceProber.isValidIPv4("10.0.0.5") && !DeviceProber.isValidIPv4("10.0.0.256"), "網段")
}

// MARK: - 引擎整合（需要 fake_sonos.py）

@MainActor
func engineTests(mode: String) async {
    let suite = "zonoz-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let platform = FakePlatform()
    let engine = CastEngine(platform: platform, defaults: defaults)
    let library = makeLibrary(30)
    engine.libraryChanged(library)
    engine.start()
    await sleep(0.5)
    engine.addManualDevice(ip: "127.0.0.1")
    check(await waitUntil { engine.selectedDevices().count == 1 }, "手動加入音箱並自動選取")
    check(engine.devices.first?.roomName == "Fake Room" && engine.devices.first?.swGen == 2, "讀到房間名 / S2")

    if mode == "fallback" {
        print("== 佇列被拒 → 退回逐首推送")
        engine.play(library[3], in: library)
        check(await waitUntil { !engine.busy && engine.deviceStatus.values.contains(.playing) }, "仍然開始播放")
        var s = await fakeState()
        check(!engine.nativeQueueActive && s.transport_uri == expectedUrl(library[3]) && s.state == "PLAYING", "逐首推送的 URL 正確")
        check(platform.sessionActive, "背景保活已要求開啟")
        await sleep(11)   // 超過切歌防抖時間
        await hardware("end")
        s = await fakeState()
        check(s.state == "STOPPED", "假音箱提前停止")
        for _ in 0..<80 {   // 等引擎的輪詢發現並處理
            s = await fakeState()
            if s.state == "PLAYING" { break }
            await sleep(0.1)
        }
        check(s.state == "PLAYING" && s.transport_uri == expectedUrl(library[3]) && engine.currentTrack?.id == library[3].id,
              "提前 STOPPED → 續播同一首而不是跳歌")
        engine.next()
        check(await waitUntil { !engine.busy && engine.currentTrack?.id == library[4].id }, "下一首")
        await sleep(0.5)
        s = await fakeState()
        check(s.transport_uri == expectedUrl(library[4]) && s.state == "PLAYING", "下一首以逐首推送送出")
        return
    }

    print("== 原生佇列")
    engine.play(library[7], in: library)
    check(await waitUntil { !engine.busy && engine.nativeQueueActive }, "佇列建立完成")
    var s = await fakeState()
    check(s.queue == library.map { expectedUrl($0) }, "音箱佇列順序與清單一致（\(s.queue.count) 首）")
    check(s.transport_uri.hasPrefix("x-rincon-queue:RINCON_FAKE") && s.track == 8 && s.state == "PLAYING", "切到佇列傳輸、定位第 8 首、播放中")
    check(s.mode == "REPEAT_ALL" && engine.queueIndex == 7 && engine.isPlaying, "播放模式 / 介面狀態")
    check(s.calls.filter { $0 == "AddMultipleURIsToQueue" }.count >= 3, "分批入隊（\(s.calls.filter { $0 == "AddMultipleURIsToQueue" }.count) 次）")

    engine.next()
    await sleep(1.0)
    s = await fakeState()
    check(s.track == 9 && engine.currentTrack?.id == library[8].id, "App 下一首 → 音箱 Next")

    await sleep(1.5)
    await hardware("next")
    check(await waitUntil { engine.currentTrack?.id == library[9].id }, "機身下一首 → 介面跟上")

    await hardware("pause")
    check(await waitUntil { !engine.isPlaying && engine.hasSession }, "機身暫停 → 介面暫停")
    engine.resume()
    check(await waitUntil { engine.isPlaying }, "繼續播放")
    s = await fakeState()
    check(s.state == "PLAYING", "音箱恢復播放")

    await hardware("volume", body: "41")
    check(await waitUntil(15) { engine.volume == 41 }, "音量從音箱同步回來")
    engine.setVolume(17)
    await sleep(0.6)
    s = await fakeState()
    check(s.volume == 17, "設定音量")

    print("== 下一首播放 / 隨機 / 循環")
    let currentId = engine.currentTrack!.id
    engine.insertNext(library[25])
    await sleep(1.0)
    s = await fakeState()
    check(s.queue.count == 31 || s.queue.count == 30, "插隊後佇列長度 \(s.queue.count)")
    check(s.queue[s.track] == expectedUrl(library[25]) && s.current_uri == expectedUrl(engine.currentTrack!), "插在目前這首後面，目前曲不變")
    check(s.queue == engine.queue.map { expectedUrl($0) }, "音箱佇列 = App 清單")

    engine.seek(to: 60)
    await sleep(2.5)
    engine.toggleShuffle()
    check(await waitUntil { !engine.busy && engine.shuffle }, "切到隨機")
    await sleep(0.5)
    s = await fakeState()
    check(engine.currentTrack?.id == currentId && engine.queueIndex == 0, "隨機後目前曲排第一")
    check(s.queue == engine.queue.map { expectedUrl($0) } && s.current_uri == expectedUrl(engine.currentTrack!), "音箱佇列按新順序重建，目前曲不變")
    check(s.pos >= 55 && s.state == "PLAYING", "重建後回到原本的秒數（\(Int(s.pos))s）而不是從頭播")

    engine.cycleRepeat()
    check(await waitUntil { !engine.busy && engine.repeatMode == .one && !engine.shuffle }, "切到單曲循環")
    await sleep(1.0)
    s = await fakeState()
    check(s.mode == "REPEAT_ONE", "音箱播放模式 REPEAT_ONE")

    print("== 不支援的格式 / 外部來源 / 停止")
    platform.blockedIds = [library[2].id]
    engine.play(library[2], in: library)
    check(await waitUntil { !engine.busy && engine.hint?.kind == .unsupportedFormat }, "96k FLAC 被擋下並提示")
    platform.blockedIds = []

    engine.play(library[5], in: library)
    check(await waitUntil { !engine.busy && engine.isPlaying && engine.currentTrack?.id == library[5].id }, "重新點歌")
    await sleep(2.0)
    await hardware("external")
    check(await waitUntil { engine.externalSource }, "偵測到音箱被其他來源接手")
    let callsBefore = (await fakeState()).calls.count
    engine.stop()
    await sleep(0.8)
    s = await fakeState()
    check(!s.calls[callsBefore...].contains("Stop") && !engine.hasSession && !platform.sessionActive, "不去停別人的播放，只放掉本地狀態")
    defaults.removePersistentDomain(forName: suite)
}

@main
struct Runner {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "core"
        if mode == "core" {
            coreTests()
        } else {
            await engineTests(mode: mode)
        }
        print("\n\(checks - failures)/\(checks) 通過")
        exit(failures == 0 ? 0 : 1)
    }
}
