using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Zonoz.Core;

/// <summary>
/// 區域網路媒體伺服器（對應 Android 版的 NanoHTTPD 實作）。
/// 用 TcpListener 自己寫而不用 HttpListener：後者監聽非 localhost 位址需要系統管理員權限或 netsh urlacl。
///
/// Sonos 播放前會先發 Range: bytes=0- 探測，拖進度時再發 bytes=N-。必須把這些做對：
/// Accept-Ranges、206 的 Content-Range、Content-Length（本次分片長度）、Content-Type（與 DIDL 一致，否則 714）。
/// </summary>
public sealed class LocalMediaServer
{
    public const int DefaultPort = 8080;
    private const int ChunkSize = 256 * 1024;

    private TcpListener? _listener;
    private CancellationTokenSource? _cts;

    public int Port { get; private set; }
    public bool IsRunning => _listener != null && Port > 0;

    /// <summary>fileId → 檔案。會在背景執行緒呼叫，必須執行緒安全。</summary>
    public Func<string, ServedFile?> Resolver { get; set; } = id => MediaRegistry.Shared.Get(id);
    public Func<(string Ip, int Tracks)> InfoProvider { get; set; } = () => ("", 0);
    /// <summary>有音箱來抓串流時觸發（UI 可用來顯示活動）</summary>
    public event Action<string, string>? StreamRequested;

    /// <summary>從 preferred 開始找一個能用的埠。回傳實際監聽的埠，全部失敗回 null。</summary>
    public int? Start(int preferred)
    {
        Stop();
        for (var candidate = preferred; candidate < preferred + 10; candidate++)
        {
            try
            {
                var listener = new TcpListener(IPAddress.Any, candidate);
                listener.Start(64);
                _listener = listener;
                _cts = new CancellationTokenSource();
                Port = candidate;
                _ = AcceptLoop(listener, _cts.Token);
                LogBus.I($"HTTP 伺服器已在埠 {candidate} 就緒");
                return candidate;
            }
            catch (SocketException ex)
            {
                LogBus.W($"HTTP 伺服器無法使用埠 {candidate}：{ex.SocketErrorCode}");
            }
        }
        return null;
    }

    public void Stop()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Stop(); } catch { }
        _listener = null;
        _cts = null;
        Port = 0;
    }

    private async Task AcceptLoop(TcpListener listener, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(token).ConfigureAwait(false); }
            catch { break; }
            _ = Task.Run(() => Handle(client, token));
        }
    }

    private async Task Handle(TcpClient client, CancellationToken token)
    {
        var remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? "?";
        try
        {
            using (client)
            {
                client.NoDelay = true;
                client.SendTimeout = 30_000;
                var stream = client.GetStream();
                var head = await ReadHead(stream, token).ConfigureAwait(false);
                if (head == null) return;
                var request = HttpRequestHead.Parse(head);
                if (request == null)
                {
                    await Respond(stream, "400 Bad Request", "text/plain; charset=utf-8", "bad request", false, token).ConfigureAwait(false);
                    return;
                }
                var isHead = request.Method == "HEAD";
                if (request.Method != "GET" && !isHead)
                    await Respond(stream, "405 Method Not Allowed", "text/plain; charset=utf-8", "method not allowed", false, token).ConfigureAwait(false);
                else if (request.Path == "/health")
                    await Respond(stream, "200 OK", "text/plain; charset=utf-8", "OK", isHead, token).ConfigureAwait(false);
                else if (request.Path is "/" or "/index.html")
                    await Respond(stream, "200 OK", "text/html; charset=utf-8", IndexPage(), isHead, token).ConfigureAwait(false);
                else if (request.Path.StartsWith("/stream"))
                    await ServeStream(stream, request, isHead, remote, token).ConfigureAwait(false);
                else
                    await Respond(stream, "404 Not Found", "text/plain; charset=utf-8", "404 Not Found", isHead, token).ConfigureAwait(false);
            }
        }
        catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException or ObjectDisposedException)
        {
            // 音箱 seek / 切歌時會主動斷線，屬正常現象
        }
        catch (Exception ex)
        {
            LogBus.W($"HTTP 連線處理失敗（{remote}）：{ex.Message}");
        }
    }

    private static async Task<string?> ReadHead(NetworkStream stream, CancellationToken token)
    {
        var buffer = new byte[16 * 1024];
        var length = 0;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        while (length < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(length, buffer.Length - length), timeout.Token).ConfigureAwait(false);
            if (read <= 0) return null;
            length += read;
            for (var i = Math.Max(0, length - read - 3); i + 3 < length; i++)
            {
                if (buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10)
                    return Encoding.UTF8.GetString(buffer, 0, i);
            }
        }
        return null;
    }

    private async Task ServeStream(NetworkStream stream, HttpRequestHead request, bool isHead, string remote, CancellationToken token)
    {
        var fileId = request.StreamFileId();
        var file = fileId == null ? null : Resolver(fileId);
        if (file == null)
        {
            LogBus.W($"HTTP 404 · {remote} {request.Method} {request.Path}（未知 fileId）");
            await Respond(stream, "404 Not Found", "text/plain; charset=utf-8", "unknown fileId", isHead, token).ConfigureAwait(false);
            return;
        }
        // 以磁碟上的實際大小為準（曲庫快取可能過期）
        long total;
        try { total = new FileInfo(file.Path).Length; }
        catch { total = 0; }
        if (total <= 0)
        {
            LogBus.E($"檔案不存在或為空：{file.Path}");
            await Respond(stream, "404 Not Found", "text/plain; charset=utf-8", "file missing", isHead, token).ConfigureAwait(false);
            return;
        }
        request.Headers.TryGetValue("range", out var rangeHeader);
        LogBus.I($"HTTP {request.Method} · {remote} · {file.DisplayName} · Range={rangeHeader ?? "(無)"}");
        StreamRequested?.Invoke(remote, file.FileId);

        ByteRange? range;
        try { range = ByteRange.Parse(rangeHeader, total); }
        catch (RangeNotSatisfiableException)
        {
            LogBus.W($"HTTP 416 · {remote} · Range 超出檔案長度 {total}");
            await Respond(stream, "416 Range Not Satisfiable", "text/plain; charset=utf-8", "range not satisfiable", isHead, token,
                $"Content-Range: bytes */{total}").ConfigureAwait(false);
            return;
        }
        var start = range?.Start ?? 0;
        var end = range?.End ?? total - 1;
        var length = range?.Length ?? total;

        var sb = new StringBuilder();
        sb.Append(range != null ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n");
        sb.Append($"Content-Type: {file.MimeType}\r\n");
        sb.Append($"Content-Length: {length}\r\n");
        sb.Append("Accept-Ranges: bytes\r\n");
        sb.Append("Cache-Control: no-store\r\n");
        sb.Append("Connection: close\r\n");
        if (range != null) sb.Append($"Content-Range: bytes {start}-{end}/{total}\r\n");
        sb.Append("\r\n");
        await stream.WriteAsync(Encoding.ASCII.GetBytes(sb.ToString()), token).ConfigureAwait(false);
        if (isHead) return;

        await using var input = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
            ChunkSize, FileOptions.Asynchronous | FileOptions.SequentialScan);
        input.Position = start;
        var buffer = new byte[ChunkSize];
        var remaining = length;
        while (remaining > 0)
        {
            var read = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(remaining, buffer.Length)), token).ConfigureAwait(false);
            if (read <= 0) break;   // 檔案比宣告的短：無法補齊 Content-Length，直接斷線
            await stream.WriteAsync(buffer.AsMemory(0, read), token).ConfigureAwait(false);
            remaining -= read;
        }
        await stream.FlushAsync(token).ConfigureAwait(false);
    }

    private static async Task Respond(NetworkStream stream, string status, string contentType, string text, bool headOnly,
        CancellationToken token, string? extraHeader = null)
    {
        var body = Encoding.UTF8.GetBytes(text);
        var header = $"HTTP/1.1 {status}\r\nContent-Type: {contentType}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n"
                     + (extraHeader != null ? extraHeader + "\r\n" : "") + "\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(header), token).ConfigureAwait(false);
        if (!headOnly) await stream.WriteAsync(body, token).ConfigureAwait(false);
        await stream.FlushAsync(token).ConfigureAwait(false);
    }

    private string IndexPage()
    {
        var (ip, tracks) = InfoProvider();
        return $$"""
            <!doctype html>
            <html lang="zh-Hant"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>ZONOZ Local Stream</title>
            <style>
            :root{color-scheme:light dark}
            body{font-family:system-ui,"Segoe UI",sans-serif;margin:0;padding:24px;line-height:1.6}
            h1{font-size:20px;margin:0 0 4px}.sub{opacity:.65;font-size:13px;margin-bottom:20px}
            .card{border:1px solid rgba(128,128,128,.35);border-radius:14px;padding:16px;margin-bottom:14px}
            .k{font-size:12px;opacity:.6;letter-spacing:.06em}.v{font-size:14px;word-break:break-all;margin-top:2px}
            code{background:rgba(128,128,128,.15);padding:2px 6px;border-radius:6px}
            </style></head><body>
            <h1>ZONOZ Local Stream · Windows</h1>
            <div class="sub">如果你能在另一台裝置上打開這個頁面，代表這台電腦的區網入站連線（防火牆）是通的。</div>
            <div class="card"><div class="k">服務位址</div><div class="v"><code>http://{{ip}}:{{Port}}</code></div></div>
            <div class="card"><div class="k">曲庫</div><div class="v">{{tracks}} 首</div></div>
            <div class="card"><div class="k">自檢</div><div class="v"><code>/health</code> 應回 OK；<code>/stream/&lt;fileId&gt;</code> 支援 Range (206)</div></div>
            </body></html>
            """;
    }
}
