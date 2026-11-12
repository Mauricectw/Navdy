using System.Text;

namespace Zonoz.Core;

/// <summary>
/// SOAP / DIDL-Lite 報文構造與極簡 XML 取值。
/// CurrentURIMetaData 本身是一段 XML，以 SOAP 參數的「文字內容」出現，所以整段 DIDL 要被轉義一層；
/// 少轉一層是 402 Invalid Args 的常見原因。
/// </summary>
public static class SoapXml
{
    public const string ServiceAVTransport = "urn:schemas-upnp-org:service:AVTransport:1";
    public const string ServiceRenderingControl = "urn:schemas-upnp-org:service:RenderingControl:1";
    public const string ServiceZoneGroupTopology = "urn:schemas-upnp-org:service:ZoneGroupTopology:1";

    public static string Envelope(string serviceType, string action, IEnumerable<(string Key, string Value)> args)
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
        sb.Append("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" ");
        sb.Append("s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">");
        sb.Append("<s:Body>");
        sb.Append($"<u:{action} xmlns:u=\"{serviceType}\">");
        foreach (var (key, value) in args) sb.Append($"<{key}>{Escape(value)}</{key}>");
        sb.Append($"</u:{action}>");
        sb.Append("</s:Body></s:Envelope>");
        return sb.ToString();
    }

    /// <summary>
    /// 最小可用的 DIDL-Lite。protocolInfo 的 MIME 必須與 HTTP 回應的 Content-Type 完全一致，否則 714。
    /// 刻意不寫 duration —— 填錯比不填更容易出問題。
    /// </summary>
    public static string DidlLite(string title, string url, string mimeType, string id = "1")
    {
        var sb = new StringBuilder();
        sb.Append("<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" ");
        sb.Append("xmlns:dc=\"http://purl.org/dc/elements/1.1/\" ");
        sb.Append("xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">");
        sb.Append($"<item id=\"{Escape(id)}\" parentID=\"0\" restricted=\"1\">");
        sb.Append($"<dc:title>{Escape(title)}</dc:title>");
        sb.Append("<upnp:class>object.item.audioItem.musicTrack</upnp:class>");
        sb.Append($"<res protocolInfo=\"http-get:*:{mimeType}:*\">{Escape(url)}</res>");
        sb.Append("</item></DIDL-Lite>");
        return sb.ToString();
    }

    /// <summary>讓傳輸層指向「音箱自己的佇列」時用的容器 DIDL（不能傳空，否則 200 但不切換）。</summary>
    public static string QueueContainerDidl(string queueUri)
    {
        var sb = new StringBuilder();
        sb.Append("<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" ");
        sb.Append("xmlns:dc=\"http://purl.org/dc/elements/1.1/\" ");
        sb.Append("xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">");
        sb.Append("<item id=\"-1\" parentID=\"-1\" restricted=\"1\">");
        sb.Append("<upnp:class>object.container.playlistContainer</upnp:class>");
        sb.Append("<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnet:1/service/DeviceProperties\">");
        sb.Append(Escape(queueUri));
        sb.Append("</desc></item></DIDL-Lite>");
        return sb.ToString();
    }

    public static string Escape(string value)
    {
        var sb = new StringBuilder(value.Length + 16);
        foreach (var ch in value)
        {
            switch (ch)
            {
                case '&': sb.Append("&amp;"); break;
                case '<': sb.Append("&lt;"); break;
                case '>': sb.Append("&gt;"); break;
                case '"': sb.Append("&quot;"); break;
                case '\'': sb.Append("&apos;"); break;
                default: sb.Append(ch); break;
            }
        }
        return sb.ToString();
    }

    /// <summary>解一層 XML 轉義（&amp;amp; 必須最後處理）。</summary>
    public static string Unescape(string value)
    {
        if (!value.Contains('&')) return value;
        return value.Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"")
            .Replace("&apos;", "'").Replace("&amp;", "&");
    }

    /// <summary>秒數 → Seek 需要的 HH:MM:SS</summary>
    public static string TimeString(int totalSeconds)
    {
        var s = Math.Max(0, totalSeconds);
        return $"{s / 3600:00}:{s % 3600 / 60:00}:{s % 60:00}";
    }

    /// <summary>"0:01:23" / "1:23" / "0:03:25.000" 都可能出現；NOT_IMPLEMENTED 之類回 0。</summary>
    public static int ParseTime(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return 0;
        var total = 0;
        foreach (var part in raw.Trim().Split(':'))
        {
            var whole = part.Split('.')[0].Trim();
            total = total * 60 + (int.TryParse(whole, out var n) ? n : 0);
        }
        return total;
    }

    /// <summary>取第一個 &lt;tag&gt;文字&lt;/tag&gt; 的文字。找不到回 null。</summary>
    public static string? TagText(string xml, string tag)
    {
        var open = $"<{tag}>";
        var close = $"</{tag}>";
        var start = xml.IndexOf(open, StringComparison.Ordinal);
        if (start < 0) return null;
        start += open.Length;
        var end = xml.IndexOf(close, start, StringComparison.Ordinal);
        if (end < 0) return null;
        return xml.Substring(start, end - start);
    }

    public static int? TagInt(string xml, string tag)
    {
        var text = TagText(xml, tag);
        return text != null && int.TryParse(text.Trim(), out var n) ? n : null;
    }

    /// <summary>從一個開始標籤的原始文字裡取屬性值。</summary>
    public static string? Attribute(string tagSource, string name)
    {
        foreach (var quote in new[] { '"', '\'' })
        {
            var needle = $"{name}={quote}";
            var from = 0;
            while (true)
            {
                var at = tagSource.IndexOf(needle, from, StringComparison.Ordinal);
                if (at < 0) break;
                // 前面必須是空白，避免 "UUID" 命中 "XUUID"
                if (at == 0 || char.IsWhiteSpace(tagSource[at - 1]))
                {
                    var valueStart = at + needle.Length;
                    var valueEnd = tagSource.IndexOf(quote, valueStart);
                    if (valueEnd < 0) return null;
                    return Unescape(tagSource.Substring(valueStart, valueEnd - valueStart));
                }
                from = at + needle.Length;
            }
        }
        return null;
    }

    /// <summary>依序取出所有 &lt;name ...&gt; 開始標籤的原始文字（含自閉合）。</summary>
    public static List<string> OpenTags(string xml, string name)
    {
        var result = new List<string>();
        var needle = "<" + name;
        var from = 0;
        while (true)
        {
            var at = xml.IndexOf(needle, from, StringComparison.Ordinal);
            if (at < 0) break;
            var after = at + needle.Length;
            if (after >= xml.Length) break;
            var next = xml[after];
            // 緊接的字元必須是空白、> 或 /，否則是別的標籤（ZoneGroup vs ZoneGroupMember）
            if (!(char.IsWhiteSpace(next) || next == '>' || next == '/'))
            {
                from = after;
                continue;
            }
            var close = xml.IndexOf('>', after);
            if (close < 0) break;
            result.Add(xml.Substring(at, close - at + 1));
            from = close + 1;
        }
        return result;
    }
}
