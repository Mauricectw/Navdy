import ExternalAccessory
import Foundation
import NavdyWire

/// Byte transport to the HUD over iAP2 / External Accessory.
///
/// The HUD firmware (com.navdy.hud.mfi.iAPProcessor) identifies itself as an MFi accessory that
/// supports two EA protocols:
///   - "com.navdy.hud.api.v1"   : framed NavdyEvent protobuf stream (this class)
///   - "com.navdy.hud.proxy.v1" : network proxy (not implemented yet)
/// Both strings must be listed in Info.plist under UISupportedExternalAccessoryProtocols.
///
/// Everything here runs on the main thread: streams are scheduled on the main run loop and the
/// traffic is a few small messages per second.
final class HUDLink: NSObject, StreamDelegate {
    static let apiProtocol = "com.navdy.hud.api.v1"

    enum State: Equatable {
        case waitingForAccessory
        case opening(String)
        case open(String)
    }

    var onStateChange: ((State) -> Void)?
    var onEvent: ((Data) -> Void)?
    var log: ((String) -> Void)?

    private(set) var state: State = .waitingForAccessory {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private var session: EASession?
    private var inputOpen = false
    private var outputOpen = false
    private var pendingOut = Data()
    private var deframer = Deframer()

    func start() {
        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(accessoryDidConnect(_:)),
                       name: .EAAccessoryDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(accessoryDidDisconnect(_:)),
                       name: .EAAccessoryDidDisconnect, object: nil)
        scanConnectedAccessories()
    }

    /// Shows iOS's picker for unpaired MFi Bluetooth accessories (first-time pairing).
    func showPairingPicker() {
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { [weak self] error in
            if let pickerError = error as? EABluetoothAccessoryPickerError, pickerError.code == .alreadyConnected {
                self?.log?("配件已連線")
            } else if let error {
                self?.log?("配對視窗：\(error.localizedDescription)")
            }
            self?.scanConnectedAccessories()
        }
    }

    func scanConnectedAccessories() {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        log?("已連線配件：\(accessories.map { "\($0.name) \($0.protocolStrings)" })")
        if session == nil, let hud = accessories.first(where: { $0.protocolStrings.contains(Self.apiProtocol) }) {
            open(hud)
        }
    }

    func send(_ eventBytes: Data) {
        pendingOut.append(Framing.frame(eventBytes))
        flush()
    }

    func close() {
        guard let session else { return }
        for stream in [session.inputStream as Stream?, session.outputStream as Stream?].compactMap({ $0 }) {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .main, forMode: .default)
        }
        self.session = nil
        inputOpen = false; outputOpen = false
        pendingOut.removeAll()
        deframer.reset()
        state = .waitingForAccessory
    }

    // MARK: - Accessory notifications

    @objc private func accessoryDidConnect(_ note: Notification) {
        guard let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        log?("配件連線：\(acc.name) \(acc.manufacturer) \(acc.modelNumber) 協定=\(acc.protocolStrings)")
        if session == nil, acc.protocolStrings.contains(Self.apiProtocol) { open(acc) }
    }

    @objc private func accessoryDidDisconnect(_ note: Notification) {
        guard let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        log?("配件斷線：\(acc.name)")
        if session?.accessory?.connectionID == acc.connectionID { close() }
    }

    // MARK: - Session

    private func open(_ accessory: EAAccessory) {
        state = .opening(accessory.name)
        guard let s = EASession(accessory: accessory, forProtocol: Self.apiProtocol) else {
            log?("無法開啟 EASession（Info.plist 是否宣告了 \(Self.apiProtocol)？）")
            state = .waitingForAccessory
            return
        }
        session = s
        for stream in [s.inputStream as Stream?, s.outputStream as Stream?].compactMap({ $0 }) {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        log?("EASession 已建立：\(accessory.name)")
    }

    private func flush() {
        guard outputOpen, let out = session?.outputStream, out.hasSpaceAvailable, !pendingOut.isEmpty else { return }
        let written = pendingOut.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return out.write(base, maxLength: pendingOut.count)
        }
        if written > 0 {
            pendingOut.removeFirst(written)
        } else if written < 0 {
            log?("寫入失敗：\(out.streamError?.localizedDescription ?? "unknown")")
        }
    }

    private func readAvailable(_ input: InputStream) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let n = input.read(&buf, maxLength: buf.count)
            guard n > 0 else { break }
            do {
                for event in try deframer.append(Data(buf[0..<n])) { onEvent?(event) }
            } catch {
                log?("訊框錯誤：\(error)，重設緩衝")
            }
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if aStream === session?.inputStream { inputOpen = true }
            if aStream === session?.outputStream { outputOpen = true }
            if inputOpen && outputOpen, let name = session?.accessory?.name {
                state = .open(name)
            }
        case .hasBytesAvailable:
            if let input = aStream as? InputStream { readAvailable(input) }
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred:
            log?("串流錯誤：\(aStream.streamError?.localizedDescription ?? "unknown")")
            close()
        case .endEncountered:
            log?("串流結束")
            close()
        default:
            break
        }
    }
}
