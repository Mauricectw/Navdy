namespace Zonoz.Core;

/// <summary>HTTP 請求頭解析 —— 純邏輯，方便測試。</summary>
public sealed class HttpRequestHead
{
    public string Method { get; private init; } = "";
    public string Path { get; private init; } = "";
    public Dictionary<string, string> Query { get; } = new();
    /// <summary>鍵一律小寫</summary>
    public Dictionary<string, string> Headers { get; } = new();

    public static HttpRequestHead? Parse(string raw)
    {
        var lines = raw.Split("\r\n");
        var parts = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return null;
        var target = parts[1];
        var path = target;
        var query = new Dictionary<string, string>();
        var q = target.IndexOf('?');
        if (q >= 0)
        {
            path = target.Substring(0, q);
            foreach (var pair in target.Substring(q + 1).Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var kv = pair.Split('=', 2);
                query[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1]) : "";
            }
        }
        // 絕對 URI 形式（GET http://host/path）也接受
        if (path.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
        {
            var slash = path.IndexOf('/', 7);
            path = slash < 0 ? "/" : path.Substring(slash);
        }
        path = Uri.UnescapeDataString(path);

        var head = new HttpRequestHead { Method = parts[0].ToUpperInvariant(), Path = path };
        foreach (var (k, v) in query) head.Query[k] = v;
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            var key = line.Substring(0, colon).Trim().ToLowerInvariant();
            if (key.Length > 0 && !head.Headers.ContainsKey(key)) head.Headers[key] = line.Substring(colon + 1).Trim();
        }
        return head;
    }

    /// <summary>/stream/1a2b3c4d5e6f.mp3 → 1a2b3c4d5e6f；也接受 ?fileId=</summary>
    public string? StreamFileId()
    {
        if (Query.TryGetValue("fileId", out var q) && q.Length > 0) return q;
        if (!Path.StartsWith("/stream")) return null;
        var segment = Path.Substring("/stream".Length).TrimStart('/').Split('/')[0];
        if (segment.Length == 0) return null;
        var dot = segment.LastIndexOf('.');
        return dot > 0 ? segment.Substring(0, dot) : segment;
    }
}

public sealed class RangeNotSatisfiableException : Exception { }

public readonly record struct ByteRange(long Start, long End)
{
    public long Length => End - Start + 1;

    /// <summary>
    /// 解析 Range: bytes=...。回 null 表示「沒有 Range 或無法理解」→ 回 200；
    /// 丟出 RangeNotSatisfiableException 表示語法正確但越界 → 回 416。
    /// </summary>
    public static ByteRange? Parse(string? header, long total)
    {
        if (string.IsNullOrEmpty(header) || total <= 0) return null;
        if (!header.StartsWith("bytes=", StringComparison.OrdinalIgnoreCase)) return null;
        var spec = header.Substring(6).Split(',')[0].Trim();
        var dash = spec.IndexOf('-');
        if (spec.Length == 0 || dash < 0) return null;
        var startPart = spec.Substring(0, dash).Trim();
        var endPart = spec.Substring(dash + 1).Trim();

        if (startPart.Length == 0)
        {
            // bytes=-500：最後 500 位元組
            if (!long.TryParse(endPart, out var suffix)) return null;
            if (suffix <= 0) throw new RangeNotSatisfiableException();
            return new ByteRange(Math.Max(0, total - suffix), total - 1);
        }
        if (!long.TryParse(startPart, out var start)) return null;
        if (start >= total) throw new RangeNotSatisfiableException();
        var end = total - 1;
        if (endPart.Length > 0)
        {
            if (!long.TryParse(endPart, out var parsed)) return null;
            end = Math.Min(parsed, total - 1);
        }
        if (end < start) throw new RangeNotSatisfiableException();
        return new ByteRange(start, end);
    }
}
