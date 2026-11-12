namespace Zonoz.Core;

/// <summary>
/// Sonos 區域組拓撲解析。GetZoneGroupState 回應裡 ZoneGroupState 的文字內容是一整段被轉義過的 XML。
/// 判定從設備：Invisible="1"，或 UUID != Coordinator。
/// </summary>
public static class ZoneTopology
{
    public sealed record Node(string Uuid, string Coordinator, bool Invisible, string ChannelMap, int SwGen, string SoftwareVersion)
    {
        public bool IsSatellite => Invisible || (Coordinator.Length > 0 && Coordinator != Uuid);
        public string Channel => ChannelOf(ChannelMap, Uuid);
    }

    /// <summary>解析不出來回空清單 —— 呼叫方應把「空」當「不知道」，靠 1023 兜底。</summary>
    public static List<Node> Parse(string soapBody)
    {
        var escaped = SoapXml.TagText(soapBody, "ZoneGroupState");
        return escaped == null ? new List<Node>() : ParseMembers(SoapXml.Unescape(escaped));
    }

    public static List<Node> ParseMembers(string xml)
    {
        var segments = new List<(string Coordinator, string Body)>();
        string? pendingCoordinator = null;
        var pendingStart = 0;
        var cursor = 0;
        while (true)
        {
            var at = xml.IndexOf("<ZoneGroup", cursor, StringComparison.Ordinal);
            if (at < 0) break;
            var after = at + "<ZoneGroup".Length;
            cursor = after;
            if (after >= xml.Length) break;
            var next = xml[after];
            // 只認 <ZoneGroup␠ / <ZoneGroup>，跳過 <ZoneGroupMember、<ZoneGroups、<ZoneGroupState
            if (!(char.IsWhiteSpace(next) || next == '>')) continue;
            var close = xml.IndexOf('>', after);
            if (close < 0) break;
            if (pendingCoordinator != null) segments.Add((pendingCoordinator, xml.Substring(pendingStart, at - pendingStart)));
            pendingCoordinator = SoapXml.Attribute(xml.Substring(at, close - at + 1), "Coordinator") ?? "";
            pendingStart = close + 1;
            cursor = close + 1;
        }
        if (pendingCoordinator != null) segments.Add((pendingCoordinator, xml.Substring(pendingStart)));
        if (segments.Count == 0) segments.Add(("", xml));

        var result = new List<Node>();
        foreach (var (segmentCoordinator, body) in segments)
        {
            // 家庭劇院的 Satellite 也是從設備，一併納入
            foreach (var tagName in new[] { "ZoneGroupMember", "Satellite" })
            {
                foreach (var tag in SoapXml.OpenTags(body, tagName))
                {
                    var uuid = SoapXml.Attribute(tag, "UUID");
                    if (string.IsNullOrEmpty(uuid)) continue;
                    var coordinator = segmentCoordinator.Length > 0 ? segmentCoordinator : SoapXml.Attribute(tag, "Coordinator") ?? "";
                    var invisible = SoapXml.Attribute(tag, "Invisible") == "1" || tagName == "Satellite";
                    var channelMap = SoapXml.Attribute(tag, "ChannelMapSet") ?? SoapXml.Attribute(tag, "HTSatChanMapSet") ?? "";
                    int.TryParse(SoapXml.Attribute(tag, "SWGen"), out var swGen);
                    result.Add(new Node(uuid, coordinator, invisible, channelMap, swGen, SoapXml.Attribute(tag, "SoftwareVersion") ?? ""));
                }
            }
        }
        return result;
    }

    /// <summary>從 RINCON_AAA:RF,RF;RINCON_BBB:LF,LF 取指定設備自己的聲道。</summary>
    public static string ChannelOf(string channelMap, string uuid)
    {
        if (channelMap.Length == 0 || uuid.Length == 0) return "";
        foreach (var entry in channelMap.Split(';'))
        {
            if (!entry.StartsWith(uuid + ":")) continue;
            return entry.Substring(uuid.Length + 1).Split(',')[0].Trim();
        }
        return "";
    }
}
