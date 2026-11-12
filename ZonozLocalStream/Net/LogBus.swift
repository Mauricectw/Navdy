import Foundation
#if canImport(Combine)
import Combine
#endif

enum LogLevel: String {
    case debug = "D"
    case info = "I"
    case warn = "W"
    case error = "E"
    case tx = "→"
    case rx = "←"
}

struct LogEntry: Identifiable {
    let id: Int
    let time: Date
    let level: LogLevel
    let message: String
}

/// App 內的診斷日誌（設定頁可檢視 / 複製）。只在主執行緒上改動。
final class LogBus: ObservableObject {
    static let shared = LogBus()
    static let capacity = 600

    @Published private(set) var entries: [LogEntry] = []
    private var nextId = 0

    private init() {}

    private func append(_ level: LogLevel, _ message: String) {
        nextId += 1
        entries.append(LogEntry(id: nextId, time: Date(), level: level, message: message))
        if entries.count > LogBus.capacity {
            entries.removeFirst(entries.count - LogBus.capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }

    static func log(_ level: LogLevel, _ message: String) {
        #if DEBUG
        print("[\(level.rawValue)] \(message)")
        #endif
        if Thread.isMainThread {
            shared.append(level, message)
        } else {
            DispatchQueue.main.async { shared.append(level, message) }
        }
    }

    static func d(_ m: String) { log(.debug, m) }
    static func i(_ m: String) { log(.info, m) }
    static func w(_ m: String) { log(.warn, m) }
    static func e(_ m: String) { log(.error, m) }

    func exportText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(f.string(from: $0.time)) \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
    }
}
