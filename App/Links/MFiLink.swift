import ExternalAccessory
import Foundation

/// Helpers around the External Accessory framework (Apple MFi Bluetooth accessories,
/// e.g. vLinker FS/MC+ "for iOS"). The protocol strings an app may talk to must be
/// listed in Info.plist → UISupportedExternalAccessoryProtocols.
enum MFiSupport {
    static var declaredProtocols: [String] {
        Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols") as? [String] ?? []
    }

    /// All accessories iOS reports to this app (normally only those matching a declared protocol).
    static var connectedAccessories: [EAAccessory] {
        EAAccessoryManager.shared().connectedAccessories
    }

    static func compatibleAccessories() -> [EAAccessory] {
        let declared = Set(declaredProtocols)
        return connectedAccessories.filter { !Set($0.protocolStrings).isDisjoint(with: declared) }
    }

    static func showPairingPicker(completion: @escaping (String?) -> Void) {
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { error in
            DispatchQueue.main.async {
                guard let error else { completion(nil); return }
                if let pickerError = error as? EABluetoothAccessoryPickerError,
                   pickerError.code == .alreadyConnected || pickerError.code == .resultCancelled {
                    completion(nil)
                } else {
                    completion(error.localizedDescription)
                }
            }
        }
    }
}

/// ELM327 over an MFi External Accessory session (iAP2 over Bluetooth Classic).
final class MFiLink: NSObject, ElmLink, StreamDelegate {
    private(set) var displayName = "MFi accessory"
    var onReceive: ((Data) -> Void)?
    var onClosed: ((Error?) -> Void)?

    private let preferredSerial: String?
    private var session: EASession?
    private var accessory: EAAccessory?
    private var thread: Thread?
    private let lock = NSLock()
    private var pending = Data()
    private var stopped = false
    private var observer: NSObjectProtocol?

    init(preferredSerial: String?) {
        self.preferredSerial = preferredSerial
        super.init()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func open(completion: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            let candidates = MFiSupport.compatibleAccessories()
            guard let acc = candidates.first(where: { $0.serialNumber == self.preferredSerial && self.preferredSerial != nil })
                    ?? candidates.first else {
                completion(ElmLinkError("No connected MFi accessory supports a declared protocol (\(MFiSupport.declaredProtocols.joined(separator: ", ")))"))
                return
            }
            let declared = MFiSupport.declaredProtocols
            guard let proto = acc.protocolStrings.first(where: { declared.contains($0) }),
                  let session = EASession(accessory: acc, forProtocol: proto) else {
                completion(ElmLinkError("Could not open an EASession with \(acc.name)"))
                return
            }
            self.accessory = acc
            self.session = session
            self.displayName = "\(acc.name) [\(proto)]"
            self.observer = NotificationCenter.default.addObserver(forName: .EAAccessoryDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let gone = note.userInfo?[EAAccessoryKey] as? EAAccessory,
                      gone.connectionID == self.accessory?.connectionID else { return }
                self.shutdown(notify: ElmLinkError("Accessory disconnected"))
            }
            let t = Thread { [weak self] in self?.streamLoop(session) }
            t.name = "MFiStreams"
            t.qualityOfService = .userInitiated
            self.thread = t
            t.start()
            completion(nil)
        }
    }

    func close() { shutdown(notify: nil) }

    private func shutdown(notify error: Error?) {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        if !wasStopped, let error { onClosed?(error) }
    }

    func send(_ data: Data) {
        lock.lock()
        pending.append(data)
        lock.unlock()
        if let t = thread { perform(#selector(flushOnStreamThread), on: t, with: nil, waitUntilDone: false) }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func streamLoop(_ session: EASession) {
        guard let input = session.inputStream, let output = session.outputStream else {
            shutdown(notify: ElmLinkError("Accessory streams unavailable"))
            return
        }
        input.delegate = self
        output.delegate = self
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()
        while !isStopped {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        input.close()
        output.close()
        input.remove(from: .current, forMode: .default)
        output.remove(from: .current, forMode: .default)
        DispatchQueue.main.async { self.session = nil }
    }

    @objc private func flushOnStreamThread() {
        guard let output = session?.outputStream else { return }
        flush(output)
    }

    private func flush(_ output: OutputStream) {
        lock.lock(); defer { lock.unlock() }
        while !pending.isEmpty && output.hasSpaceAvailable {
            let written = pending.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
                output.write(buf.bindMemory(to: UInt8.self).baseAddress!, maxLength: buf.count)
            }
            if written <= 0 { break }
            pending.removeFirst(written)
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while input.hasBytesAvailable {
                let n = input.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                onReceive?(Data(buffer[0..<n]))
            }
        case .hasSpaceAvailable:
            if let output = aStream as? OutputStream { flush(output) }
        case .errorOccurred:
            shutdown(notify: aStream.streamError ?? ElmLinkError("Accessory stream error"))
        case .endEncountered:
            shutdown(notify: ElmLinkError("Accessory stream closed"))
        default:
            break
        }
    }
}
