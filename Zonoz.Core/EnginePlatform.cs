using System.Diagnostics;

namespace Zonoz.Core;

/// <summary>CastEngine 需要、但屬於作業系統 / 網路層的能力。抽成介面讓引擎能對著假音箱做整合測試。</summary>
public interface IEnginePlatform
{
    /// <summary>這台電腦在區網上的 IPv4；toward 有值時回傳「通往那台音箱」的那個位址</summary>
    string? CurrentLanIP(SonosDevice? toward);
    /// <summary>確保本地 HTTP 伺服器在跑，回傳監聽埠；失敗回 null</summary>
    Task<int?> EnsureServerAsync(bool force);
    /// <summary>換一個埠重建伺服器（701 時用）</summary>
    Task<int?> RestartServerOnNewPortAsync();
    Task<List<SonosDevice>> DiscoverAsync();
    AudioProbe.Format? ProbeFormat(Track track);
    /// <summary>有 / 沒有進行中的播放工作階段（用來阻止電腦睡眠）</summary>
    void PlaybackSessionChanged(bool active);
    void NowPlayingChanged();
    /// <summary>單調時鐘（秒）</summary>
    double Uptime();
}

/// <summary>桌面平台的預設實作：真的 HTTP 伺服器 + SSDP / 網段掃描。不含任何 UI。</summary>
public class DesktopPlatform : IEnginePlatform
{
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly DeviceProber _prober = new(1.5);
    public LocalMediaServer Server { get; } = new();

    public DesktopPlatform()
    {
        Server.InfoProvider = () => (CurrentLanIP(null) ?? "-", MediaRegistry.Shared.Count);
    }

    public virtual string? CurrentLanIP(SonosDevice? toward)
    {
        if (toward != null)
        {
            var routed = NetUtils.LocalAddressToward(toward.Ip);
            if (routed != null && routed != "0.0.0.0") return routed;
        }
        return NetUtils.LocalIPv4Addresses().FirstOrDefault();
    }

    public virtual Task<int?> EnsureServerAsync(bool force)
    {
        if (!force && Server.IsRunning) return Task.FromResult<int?>(Server.Port);
        return Task.FromResult(Server.Start(LocalMediaServer.DefaultPort));
    }

    public virtual Task<int?> RestartServerOnNewPortAsync()
    {
        var preferred = Server.Port > 0 ? Server.Port + 1 : LocalMediaServer.DefaultPort;
        if (preferred > LocalMediaServer.DefaultPort + 40) preferred = LocalMediaServer.DefaultPort;
        return Task.FromResult(Server.Start(preferred));
    }

    public virtual async Task<List<SonosDevice>> DiscoverAsync()
    {
        var byKey = new Dictionary<string, SonosDevice>();
        var locations = await SsdpDiscovery.SearchLocations(3.0);
        var fetched = await Task.WhenAll(locations.Select(l => _prober.FetchDescription(l, DiscoverySource.Ssdp)));
        foreach (var device in fetched)
            if (device != null) byKey[device.Key] = device;
        LogBus.D($"SSDP 找到 {byKey.Count} 台");

        if (byKey.Count == 0)
        {
            // SSDP 落空（被防火牆擋、交換器不轉組播…）→ 改掃同網段的 1400 埠
            foreach (var ip in NetUtils.LocalIPv4Addresses().Take(3))
            {
                var found = await _prober.ScanSubnet(ip);
                foreach (var device in found) byKey[device.Key] = device;
                LogBus.D($"網段掃描（{ip}/24）找到 {found.Count} 台");
                if (byKey.Count > 0) break;
            }
        }
        return byKey.Values.ToList();
    }

    public virtual AudioProbe.Format? ProbeFormat(Track track) => AudioProbe.ProbeFile(track.Path);
    public virtual void PlaybackSessionChanged(bool active) { }
    public virtual void NowPlayingChanged() { }
    public double Uptime() => _clock.Elapsed.TotalSeconds;
}
