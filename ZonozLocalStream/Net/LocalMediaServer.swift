import Foundation
import Network

/// 區域網路媒體伺服器（對應 Android 版的 NanoHTTPD 實作）。
///
/// 為什麼必須自己把 Range 做對：Sonos 播放前會先發 `Range: bytes=0-` 探測，
/// 拖進度時再發 `bytes=N-`。忽略 Range 直接回 200 全量，音箱通常「能播但不能拖」，
/// 大檔還會反覆重新拉流。這些標頭同樣重要：
/// - `Accept-Ranges: bytes`               讓音箱知道可以 seek
/// - `Content-Range: bytes s-e/total`     206 時必須精確
/// - `Content-Length`                     是本次分片的長度，不是檔案總長
/// - `Content-Type`                       必須與 DIDL 的 protocolInfo 一致，否則 714
final class LocalMediaServer {

    static let defaultPort = 8080
    private static let chunkSize = 256 * 1024

    private let queue = DispatchQueue(label: "zonoz.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private(set) var port = 0
    private var ready = false

    /// fileId → 檔案。在伺服器佇列上呼叫，必須是執行緒安全的。
    var resolver: (String) -> ServedFile? = { MediaRegistry.shared.get($0) }
    /// 首頁顯示用
    var infoProvider: () -> (ip: String, tracks: Int) = { ("", 0) }

    var isRunning: Bool {
        return queue.sync { ready && listener != nil }
    }

    var currentPort: Int {
        return queue.sync { ready ? port : 0 }
    }

    /// 從 `preferred` 開始找一個能用的埠。回傳實際監聽的埠，全部失敗回 nil。
    func start(preferred: Int) async -> Int? {
        stop()
        for candidate in preferred..<(preferred + 10) {
            if await listen(on: candidate) { return candidate }
        }
        return nil
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            ready = false
            port = 0
            for connection in connections.values { connection.close() }
            connections.removeAll()
        }
    }

    private final class Once: @unchecked Sendable {
        var done = false
    }

    private func listen(on candidate: Int) async -> Bool {
        guard candidate > 0, candidate < 65536, let nwPort = NWEndpoint.Port(rawValue: UInt16(candidate)) else {
            return false
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.prohibitedInterfaceTypes = [.cellular]
            let newListener: NWListener
            do {
                newListener = try NWListener(using: parameters, on: nwPort)
            } catch {
                LogBus.w("HTTP 伺服器無法使用埠 \(candidate)：\(error.localizedDescription)")
                continuation.resume(returning: false)
                return
            }
            let once = Once()
            newListener.newConnectionHandler = { [weak self] nwConnection in
                self?.accept(nwConnection)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.listener = newListener
                    self.port = candidate
                    self.ready = true
                    if !once.done {
                        once.done = true
                        LogBus.i("HTTP 伺服器已在埠 \(candidate) 就緒")
                        continuation.resume(returning: true)
                    }
                case .failed(let error), .waiting(let error):
                    // waiting 多半是沒有可用的網路介面；一併當失敗處理，交給上層提示
                    LogBus.w("HTTP 伺服器（埠 \(candidate)）失敗：\(error.localizedDescription)")
                    newListener.cancel()
                    if self.listener === newListener {
                        self.listener = nil
                        self.ready = false
                        self.port = 0
                    }
                    if !once.done {
                        once.done = true
                        continuation.resume(returning: false)
                    }
                case .cancelled:
                    if self.listener === newListener {
                        self.listener = nil
                        self.ready = false
                        self.port = 0
                    }
                    if !once.done {
                        once.done = true
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            newListener.start(queue: self.queue)
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = Connection(nwConnection, server: self)
        connections[ObjectIdentifier(connection)] = connection
        connection.start(on: queue)
    }

    fileprivate func finished(_ connection: Connection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    // MARK: - 單一連線

    fileprivate final class Connection {
        private let nw: NWConnection
        private weak var server: LocalMediaServer?
        private var buffer = Data()
        private var handle: FileHandle?
        private var closed = false
        private let remote: String

        init(_ nw: NWConnection, server: LocalMediaServer) {
            self.nw = nw
            self.server = server
            if case .hostPort(let host, _) = nw.endpoint {
                remote = "\(host)"
            } else {
                remote = "?"
            }
        }

        func start(on queue: DispatchQueue) {
            nw.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.cleanup()
                default:
                    break
                }
            }
            nw.start(queue: queue)
            readHead()
        }

        func close() {
            if closed { return }
            nw.cancel()
            cleanup()
        }

        private func cleanup() {
            if closed { return }
            closed = true
            try? handle?.close()
            handle = nil
            server?.finished(self)
        }

        private func readHead() {
            nw.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
                guard let self = self, !self.closed else { return }
                if let data = data { self.buffer.append(data) }
                if let terminator = self.buffer.range(of: Data([13, 10, 13, 10])) {
                    let headData = self.buffer.subdata(in: self.buffer.startIndex..<terminator.lowerBound)
                    self.buffer.removeAll()
                    self.handleRequest(String(decoding: headData, as: UTF8.self))
                } else if error != nil || isComplete || self.buffer.count > 32 * 1024 {
                    self.close()
                } else {
                    self.readHead()
                }
            }
        }

        private func handleRequest(_ raw: String) {
            guard let request = HTTPRequestHead.parse(raw) else {
                respond(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", text: "bad request", headOnly: false)
                return
            }
            let isHead = request.method == "HEAD"
            guard request.method == "GET" || isHead else {
                respond(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", text: "method not allowed", headOnly: false)
                return
            }
            if request.path == "/health" {
                respond(status: "200 OK", contentType: "text/plain; charset=utf-8", text: "OK", headOnly: isHead)
            } else if request.path == "/" || request.path == "/index.html" {
                respond(status: "200 OK", contentType: "text/html; charset=utf-8", text: indexPage(), headOnly: isHead)
            } else if request.path.hasPrefix("/stream") {
                serveStream(request, isHead: isHead)
            } else {
                respond(status: "404 Not Found", contentType: "text/plain; charset=utf-8", text: "404 Not Found", headOnly: isHead)
            }
        }

        private func serveStream(_ request: HTTPRequestHead, isHead: Bool) {
            guard let fileId = request.streamFileId(), let file = server?.resolver(fileId) else {
                LogBus.w("HTTP 404 · \(remote) \(request.method) \(request.path)（未知 fileId）")
                respond(status: "404 Not Found", contentType: "text/plain; charset=utf-8", text: "unknown fileId", headOnly: isHead)
                return
            }
            // 以磁碟上的實際大小為準（曲庫快取可能過期）
            var total = file.sizeBytes
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path),
               let size = attributes[.size] as? NSNumber {
                total = size.int64Value
            }
            guard total > 0 else {
                LogBus.e("檔案不存在或為空：\(file.displayName)")
                respond(status: "404 Not Found", contentType: "text/plain; charset=utf-8", text: "file missing", headOnly: isHead)
                return
            }
            let rangeHeader = request.headers["range"]
            LogBus.i("HTTP \(request.method) · \(remote) · \(file.displayName) · Range=\(rangeHeader ?? "(無)")")

            let range: ByteRange?
            do {
                range = try ByteRange.parse(header: rangeHeader, total: total)
            } catch {
                LogBus.w("HTTP 416 · \(remote) · Range 超出檔案長度 \(total)")
                respond(
                    status: "416 Range Not Satisfiable", contentType: "text/plain; charset=utf-8",
                    text: "range not satisfiable", headOnly: isHead,
                    extraHeaders: ["Content-Range: bytes */\(total)"]
                )
                return
            }
            let start = range?.start ?? 0
            let end = range?.end ?? (total - 1)
            let length = range?.length ?? total

            var lines = [
                range != nil ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK",
                "Content-Type: \(file.mimeType)",
                "Content-Length: \(length)",
                "Accept-Ranges: bytes",
                "Cache-Control: no-store",
                "Connection: close"
            ]
            if range != nil { lines.append("Content-Range: bytes \(start)-\(end)/\(total)") }
            let header = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

            if isHead {
                sendAndFinish(header)
                return
            }
            do {
                let fileHandle = try FileHandle(forReadingFrom: file.url)
                if start > 0 { try fileHandle.seek(toOffset: UInt64(start)) }
                handle = fileHandle
            } catch {
                LogBus.e("開檔失敗：\(file.displayName) · \(error.localizedDescription)")
                respond(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", text: "cannot open file", headOnly: false)
                return
            }
            nw.send(content: header, completion: .contentProcessed { [weak self] error in
                guard let self = self, !self.closed else { return }
                if error != nil {
                    self.close()
                } else {
                    self.sendBody(remaining: length)
                }
            })
        }

        /// 一塊送完才讀下一塊：靠 contentProcessed 回呼做背壓，不會把整個檔案讀進記憶體。
        private func sendBody(remaining: Int64) {
            guard let fileHandle = handle, remaining > 0 else {
                finish()
                return
            }
            let want = Int(min(remaining, Int64(LocalMediaServer.chunkSize)))
            var chunk = Data()
            do {
                chunk = try fileHandle.read(upToCount: want) ?? Data()
            } catch {
                close()
                return
            }
            if chunk.isEmpty {
                // 檔案比宣告的短（被截斷）：無法補齊 Content-Length，只能直接斷線
                close()
                return
            }
            let sent = Int64(chunk.count)
            nw.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self = self, !self.closed else { return }
                if error != nil {
                    // 音箱 seek / 切歌時會主動斷線，屬正常現象
                    self.close()
                } else {
                    self.sendBody(remaining: remaining - sent)
                }
            })
        }

        private func respond(status: String, contentType: String, text: String, headOnly: Bool, extraHeaders: [String] = []) {
            let body = Data(text.utf8)
            var lines = [
                "HTTP/1.1 \(status)",
                "Content-Type: \(contentType)",
                "Content-Length: \(body.count)",
                "Connection: close"
            ]
            lines.append(contentsOf: extraHeaders)
            var payload = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            if !headOnly { payload.append(body) }
            sendAndFinish(payload)
        }

        private func sendAndFinish(_ data: Data) {
            nw.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
        }

        /// 送出 FIN 後再關閉，確保最後一塊資料送達。
        private func finish() {
            if closed { return }
            try? handle?.close()
            handle = nil
            nw.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }

        private func indexPage() -> String {
            let info = server?.infoProvider() ?? ("", 0)
            let port = server?.port ?? 0
            return """
            <!doctype html>
            <html lang="zh-Hant"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>ZONOZ Local Stream</title>
            <style>
            :root{color-scheme:light dark}
            body{font-family:system-ui,-apple-system,sans-serif;margin:0;padding:24px;line-height:1.6}
            h1{font-size:20px;margin:0 0 4px}.sub{opacity:.65;font-size:13px;margin-bottom:20px}
            .card{border:1px solid rgba(128,128,128,.35);border-radius:14px;padding:16px;margin-bottom:14px}
            .k{font-size:12px;opacity:.6;letter-spacing:.06em}.v{font-size:14px;word-break:break-all;margin-top:2px}
            code{background:rgba(128,128,128,.15);padding:2px 6px;border-radius:6px}
            </style></head><body>
            <h1>ZONOZ Local Stream · iOS</h1>
            <div class="sub">如果你能在另一台裝置上打開這個頁面，代表 iPhone 的區網入站連線是通的。</div>
            <div class="card"><div class="k">服務位址</div><div class="v"><code>http://\(info.0):\(port)</code></div></div>
            <div class="card"><div class="k">曲庫</div><div class="v">\(info.1) 首</div></div>
            <div class="card"><div class="k">自檢</div><div class="v"><code>/health</code> 應回 OK；<code>/stream/&lt;fileId&gt;</code> 支援 Range (206)</div></div>
            </body></html>
            """
        }
    }
}
