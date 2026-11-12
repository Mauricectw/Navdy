namespace Zonoz.Core;

public enum DiscoverySource { Ssdp, Subnet, Manual }

/// <summary>
/// 一台 Sonos 音箱（ZonePlayer）在控制面所需的全部資訊。
/// S1 / S2 韌體的 UPnP 服務路徑完全一致。
/// </summary>
public sealed record SonosDevice
{
    public const int Port = 1400;
    public const string DefaultAVTransportPath = "/MediaRenderer/AVTransport/Control";
    public const string DefaultRenderingControlPath = "/MediaRenderer/RenderingControl/Control";
    public const string DeviceDescriptionPath = "/xml/device_description.xml";

    public string Uuid { get; init; } = "";
    public string Ip { get; init; } = "";
    public string FriendlyName { get; init; } = "";
    public string RoomName { get; init; } = "";
    public string ModelName { get; init; } = "";
    public string Location { get; init; } = "";
    public string AVTransportControlUrl { get; init; } = DefaultAVTransportPath;
    public string RenderingControlUrl { get; init; } = DefaultRenderingControlPath;
    public bool IsSonos { get; init; } = true;
    public DiscoverySource Source { get; init; } = DiscoverySource.Ssdp;
    /// <summary>立體聲配對 / 家庭劇院裡的從設備：對它發 SetAVTransportURI 會回 1023，只推主箱即可。</summary>
    public bool IsSatellite { get; init; }
    /// <summary>配對中的聲道角色：LF / RF / 空</summary>
    public string ChannelRole { get; init; } = "";
    /// <summary>韌體代次：S1 = 1，S2 = 2，0 表示沒讀到</summary>
    public int SwGen { get; init; }
    public string SoftwareVersion { get; init; } = "";

    public string DisplayName => RoomName.Length > 0 ? RoomName : FriendlyName.Length > 0 ? FriendlyName : Ip;
    /// <summary>UI 選擇集合用的穩定 key</summary>
    public string Key => Uuid.Length > 0 ? Uuid : Ip;
    public bool IsLegacyS1 => SwGen == 1;
    public string GenerationLabel => SwGen switch { 1 => "S1", 2 => "S2", _ => "" };

    public static string DescriptionLocation(string ip) => $"http://{ip}:{Port}{DeviceDescriptionPath}";
}

/// <summary>解析 http://&lt;ip&gt;:1400/xml/device_description.xml</summary>
public static class DeviceDescription
{
    public static SonosDevice? Parse(string location, string xml, DiscoverySource source)
    {
        var ip = HostOf(location);
        if (string.IsNullOrEmpty(ip)) return null;

        var friendlyName = Text(xml, "friendlyName");
        var roomName = Text(xml, "roomName");
        var modelName = Text(xml, "modelName");
        var manufacturer = Text(xml, "manufacturer");
        var udn = Text(xml, "UDN");
        int.TryParse(Text(xml, "swGen"), out var swGen);
        var softwareVersion = Text(xml, "softwareVersion");

        var avTransport = "";
        var rendering = "";
        var from = 0;
        while (true)
        {
            var open = xml.IndexOf("<service>", from, StringComparison.Ordinal);
            if (open < 0) break;
            var close = xml.IndexOf("</service>", open, StringComparison.Ordinal);
            if (close < 0) break;
            var block = xml.Substring(open, close - open);
            var type = Text(block, "serviceType");
            var control = Text(block, "controlURL");
            if (type.Contains(":service:AVTransport:") && avTransport.Length == 0) avTransport = control;
            else if (type.Contains(":service:RenderingControl:") && rendering.Length == 0) rendering = control;
            from = close + 10;
        }

        var isSonos = manufacturer.Contains("sonos", StringComparison.OrdinalIgnoreCase)
            || location.Contains($":{SonosDevice.Port}/")
            || modelName.Contains("sonos", StringComparison.OrdinalIgnoreCase)
            || udn.Contains("RINCON");

        var uuid = udn.StartsWith("uuid:") ? udn.Substring(5) : udn;
        if (uuid.Length == 0) uuid = $"RINCON_{ip}";

        return new SonosDevice
        {
            Uuid = uuid,
            Ip = ip,
            FriendlyName = friendlyName,
            RoomName = roomName,
            ModelName = modelName.Length == 0 ? "Sonos" : modelName,
            Location = location,
            AVTransportControlUrl = ToPath(avTransport, SonosDevice.DefaultAVTransportPath),
            RenderingControlUrl = ToPath(rendering, SonosDevice.DefaultRenderingControlPath),
            IsSonos = isSonos,
            Source = source,
            SwGen = swGen,
            SoftwareVersion = softwareVersion,
        };
    }

    private static string Text(string xml, string tag)
    {
        var raw = SoapXml.TagText(xml, tag);
        return raw == null ? "" : SoapXml.Unescape(raw).Trim();
    }

    /// <summary>從 http://192.168.1.5:1400/xml/... 取出主機部分。</summary>
    public static string? HostOf(string location)
    {
        var scheme = location.IndexOf("://", StringComparison.Ordinal);
        if (scheme < 0) return null;
        var rest = location.Substring(scheme + 3);
        var hostPort = rest.Split('/')[0];
        return hostPort.Split(':')[0];
    }

    public static string ToPath(string raw, string fallback)
    {
        if (raw.Length == 0) return fallback;
        if (raw.StartsWith("http", StringComparison.OrdinalIgnoreCase))
        {
            var scheme = raw.IndexOf("://", StringComparison.Ordinal);
            if (scheme < 0) return fallback;
            var slash = raw.IndexOf('/', scheme + 3);
            return slash < 0 ? fallback : raw.Substring(slash);
        }
        return raw.StartsWith('/') ? raw : "/" + raw;
    }
}
