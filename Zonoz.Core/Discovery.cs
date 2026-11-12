using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace Zonoz.Core;

public static class NetUtils
{
    /// <summary>所有啟用中、非 loopback 的 IPv4 位址（有預設閘道的排前面）。</summary>
    public static List<string> LocalIPv4Addresses()
    {
        var withGateway = new List<string>();
        var others = new List<string>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
                var props = nic.GetIPProperties();
                var hasGateway = props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork
                                                                 && !g.Address.Equals(IPAddress.Any));
                foreach (var unicast in props.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var ip = unicast.Address.ToString();
                    if (ip.StartsWith("169.254.") || ip.StartsWith("127.")) continue;
                    (hasGateway ? withGateway : others).Add(ip);
                }
            }
        }
        catch (Exception ex)
        {
            LogBus.W($"列舉網路介面失敗：{ex.Message}");
        }
        withGateway.AddRange(others);
        return withGateway;
    }

    /// <summary>
    /// 這台電腦「通往某台音箱」時會用的本機位址。多網卡 / VPN / 虛擬網卡的環境下，
    /// 只有照路由表問出來的位址才是音箱連得回來的那一個。
    /// </summary>
    public static string? LocalAddressToward(string remoteIp)
    {
        try
        {
            using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            socket.Connect(remoteIp, SonosDevice.Port);   // UDP connect 不送封包，只做路由查詢
            return (socket.LocalEndPoint as IPEndPoint)?.Address.ToString();
        }
        catch
        {
            return null;
        }
    }

    public static bool IsValidIPv4(string text)
    {
        var parts = text.Split('.');
        return parts.Length == 4 && parts.All(p => int.TryParse(p, out var n) && n is >= 0 and <= 255 && n.ToString() == p);
    }

    /// <summary>192.168.1.37 → 192.168.1.1 … 192.168.1.254（不含自己）</summary>
    public static List<string> SubnetHosts(string localIp)
    {
        var parts = localIp.Split('.');
        if (parts.Length != 4 || !parts.All(p => int.TryParse(p, out _))) return new List<string>();
        var prefix = string.Join('.', parts.Take(3));
        var own = int.Parse(parts[3]);
        return Enumerable.Range(1, 254).Where(n => n != own).Select(n => $"{prefix}.{n}").ToList();
    }
}

/// <summary>以單播 HTTP 抓裝置描述。</summary>
public sealed class DeviceProber
{
    private readonly HttpClient _http;

    public DeviceProber(double timeoutSeconds = 2.5)
    {
        var handler = new SocketsHttpHandler { UseProxy = false, ConnectTimeout = TimeSpan.FromSeconds(timeoutSeconds) };
        _http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(timeoutSeconds + 1) };
    }

    public async Task<SonosDevice?> FetchDescription(string location, DiscoverySource source)
    {
        try
        {
            var xml = await _http.GetStringAsync(location);
            if (!xml.Contains("<device>") && !xml.Contains("<UDN>")) return null;
            var device = DeviceDescription.Parse(location, xml, source);
            return device is { IsSonos: true } ? device : null;
        }
        catch
        {
            return null;
        }
    }

    public Task<SonosDevice?> Probe(string ip, DiscoverySource source) =>
        FetchDescription(SonosDevice.DescriptionLocation(ip), source);

    /// <summary>掃描 localIp 所在的 /24 網段。</summary>
    public async Task<List<SonosDevice>> ScanSubnet(string localIp, int concurrency = 48)
    {
        using var gate = new SemaphoreSlim(concurrency);
        var tasks = NetUtils.SubnetHosts(localIp).Select(async ip =>
        {
            await gate.WaitAsync();
            try { return await Probe(ip, DiscoverySource.Subnet); }
            finally { gate.Release(); }
        }).ToList();
        var results = await Task.WhenAll(tasks);
        return results.Where(d => d != null).Select(d => d!).ToList();
    }
}

/// <summary>
/// SSDP：對 239.255.255.250:1900 發 M-SEARCH，音箱以單播回覆 LOCATION。
/// 每張網卡各綁一個 socket 發送 —— 只用預設介面的話，多網卡 / 有 VPN 的電腦常常找不到。
/// </summary>
public static class SsdpDiscovery
{
    private const string SearchTarget = "urn:schemas-upnp-org:device:ZonePlayer:1";

    public static async Task<List<string>> SearchLocations(double seconds = 3.0)
    {
        var message = Encoding.ASCII.GetBytes(
            "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 2\r\n" +
            $"ST: {SearchTarget}\r\n\r\n");
        var target = new IPEndPoint(IPAddress.Parse("239.255.255.250"), 1900);
        var locations = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var gate = new object();

        var tasks = NetUtils.LocalIPv4Addresses().Select(async localIp =>
        {
            try
            {
                using var udp = new UdpClient(new IPEndPoint(IPAddress.Parse(localIp), 0));
                udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 2);
                for (var i = 0; i < 2; i++)
                {
                    await udp.SendAsync(message, message.Length, target);
                    await Task.Delay(120);
                }
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
                while (!cts.IsCancellationRequested)
                {
                    UdpReceiveResult received;
                    try { received = await udp.ReceiveAsync(cts.Token); }
                    catch (OperationCanceledException) { break; }
                    var location = ParseLocation(Encoding.UTF8.GetString(received.Buffer));
                    if (location == null) continue;
                    lock (gate) locations.Add(location);
                }
            }
            catch (Exception ex)
            {
                LogBus.D($"SSDP（{localIp}）失敗：{ex.Message}");
            }
        }).ToList();
        await Task.WhenAll(tasks);
        return locations.ToList();
    }

    public static string? ParseLocation(string response)
    {
        foreach (var line in response.Split("\r\n"))
        {
            if (!line.StartsWith("LOCATION:", StringComparison.OrdinalIgnoreCase)) continue;
            var value = line.Substring(9).Trim();
            return value.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? value : null;
        }
        return null;
    }
}
