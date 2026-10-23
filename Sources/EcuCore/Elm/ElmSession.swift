import Foundation

public enum ElmState: Int {
    case none = 0, connecting = 1, connected = 2, disconnected = 3
}

public enum ElmEvent {
    case state(ElmState)
    /// A processed queue entry: the request as queued and the decoded reply
    /// (hex payload, raw ELM text for AT commands, or "ERROR : …").
    case response(request: String, reply: String)
    case queue(remaining: Int)
    case log(String)
    case deviceName(String)
}

/// Port of org.quark.dr.canapp.ElmBase: command queue, worker thread,
/// ELM327 initialisation and CAN / KWP2000 / ISO8 transport over any `ElmLink`.
public final class ElmSession: @unchecked Sendable {

    public static let ecuErrorCodes: [String: String] = {
        let src = "10:General Reject,11:Service Not Supported,12:SubFunction Not Supported,"
            + "13:Incorrect Message Length Or Invalid Format,21:Busy Repeat Request,"
            + "22:Conditions Not Correct Or Request Sequence Error,23:Routine Not Complete,"
            + "24:Request Sequence Error,31:Request Out Of Range,"
            + "33:Security Access Denied- Security Access Requested,35:Invalid Key,"
            + "36:Exceed Number Of Attempts,37:Required Time Delay Not Expired,"
            + "40:Download not accepted,41:Improper download type,42:Can not download to specified address,"
            + "43:Can not download number of bytes requested,50:Upload not accepted,51:Improper upload type,"
            + "52:Can not upload from specified address,53:Can not upload number of bytes requested,"
            + "70:Upload Download NotAccepted,71:Transfer Data Suspended,72:General Programming Failure,"
            + "73:Wrong Block Sequence Counter,74:Illegal Address In Block Transfer,"
            + "75:Illegal Byte Count In Block Transfer,76:Illegal Block Transfer Type,"
            + "77:Block Transfer Data Checksum Error,78:Request Correctly Received-Response Pending,"
            + "79:Incorrect ByteCount During Block Transfer,7E:SubFunction Not Supported In Active Session,"
            + "7F:Service Not Supported In Active Session,80:Service Not Supported In Active Diagnostic Mode,"
            + "81:Rpm Too High,82:Rpm Too Low,83:Engine Is Running,84:Engine Is Not Running,"
            + "85:Engine RunTime TooLow,86:Temperature Too High,87:Temperature Too Low,"
            + "88:Vehicle Speed Too High,89:Vehicle Speed Too Low,8A:Throttle/Pedal Too High,"
            + "8B:Throttle/Pedal Too Low,8C:Transmission Range In Neutral,8D:Transmission Range In Gear,"
            + "8F:Brake Switch(es) Not Closed (brake pedal not pressed or not applied),"
            + "90:Shifter Lever Not In Park,91:Torque Converter Clutch Locked,92:Voltage Too High,93:Voltage Too Low"
        var map = [String: String]()
        for entry in src.split(separator: ",") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { map[String(parts[0])] = String(parts[1]) }
        }
        return map
    }()

    public static func ecuErrorCode(_ hex: String) -> String? { ecuErrorCodes[hex.uppercased()] }

    // MARK: State

    private let stateLock = NSLock()
    private var _state: ElmState = .none
    public var state: ElmState { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    public var isConnected: Bool { state == .connected }
    public var isConnecting: Bool { state == .connecting }

    private var handler: ((ElmEvent) -> Void)?
    private var handlerGeneration = 0
    private let callbackQueue: DispatchQueue

    private let queueCond = NSCondition()
    private var messages: [String] = []
    private var running = false

    private let rxCond = NSCondition()
    private var rxBuffer = Data()
    private var rxActivity = Date()

    private let linkLock = NSLock()
    private var _link: ElmLink?
    private var link: ElmLink? {
        get { linkLock.lock(); defer { linkLock.unlock() }; return _link }
        set { linkLock.lock(); _link = newValue; linkLock.unlock() }
    }
    private var worker: Thread?
    private var linkGeneration = 0

    /// Protocol currently in effect for the worker thread ("CAN", "KWP2000", "ISO8").
    private var workerProtocol = "UNDEFINED"
    private var rxa = -1
    private var txa = -1
    private var sessionActiveFlag = false
    private var softFlowControl = false
    private var consecutiveTimeouts = 0

    /// Idle timeout while waiting for the ELM '>' prompt (Java Wi-Fi used SoTimeout 4000 ms).
    public var idleTimeout: TimeInterval = 4.0

    private let logLock = NSLock()
    private var logHandle: FileHandle?
    public let logURL: URL?

    public init(callbackQueue: DispatchQueue = .main, logURL: URL? = nil) {
        self.callbackQueue = callbackQueue
        self.logURL = logURL
        openLogFile()
    }

    deinit {
        try? logHandle?.close()
    }

    // MARK: - Handler (ElmBase.changeHandler)

    /// Switches the receiver of events. Pending events for the previous handler are dropped.
    /// Must be called on the callback queue.
    public func changeHandler(_ newHandler: ((ElmEvent) -> Void)?) {
        handlerGeneration += 1
        handler = newHandler
        setSessionActive(false)
        if newHandler == nil {
            clearMessages()
        } else {
            let s = state
            emit(.state(s == .connecting ? .connecting : (s == .connected ? .connected : .disconnected)))
        }
    }

    private func emit(_ event: ElmEvent) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.handler?(event)
        }
    }

    /// Emit that is dropped if the handler changed in the meantime (Java removeCallbacksAndMessages).
    private func emitCurrent(_ event: ElmEvent) {
        let gen = handlerGeneration
        callbackQueue.async { [weak self] in
            guard let self, self.handlerGeneration == gen else { return }
            self.handler?(event)
        }
    }

    private func setState(_ s: ElmState) {
        stateLock.lock(); _state = s; stateLock.unlock()
        emit(.state(s))
    }

    public func logInfo(_ text: String) {
        emit(.log(text))
        writeLog("INFO: " + timestamp() + text)
    }

    // MARK: - Connection

    public var deviceName: String? { link?.displayName }

    public func connect(link newLink: ElmLink) {
        disconnect()
        linkGeneration += 1
        let gen = linkGeneration
        link = newLink
        setState(.connecting)
        newLink.onReceive = { [weak self] data in self?.received(data) }
        newLink.onClosed = { [weak self] error in
            guard let self, self.linkGeneration == gen else { return }
            self.connectionLost(error?.localizedDescription ?? "link closed")
        }
        newLink.open { [weak self] error in
            guard let self, self.linkGeneration == gen else { return }
            if let error {
                self.logInfo("Connection failed: \(error.localizedDescription)")
                self.link = nil
                self.setState(.none)
                return
            }
            self.clearMessages()
            self.startWorker()
            self.emit(.deviceName(newLink.displayName))
            self.logInfo("Connected to \(newLink.displayName)")
            self.setState(.connected)
        }
    }

    public func disconnect() {
        linkGeneration += 1
        stopWorker()
        link?.onReceive = nil
        link?.onClosed = nil
        link?.close()
        link = nil
        clearMessages()
        if state != .none { setState(.none) }
    }

    private func connectionLost(_ reason: String) {
        logInfo("Device connection was lost : \(reason)")
        linkGeneration += 1
        queueCond.lock(); running = false; queueCond.broadcast(); queueCond.unlock()
        rxCond.lock(); rxCond.broadcast(); rxCond.unlock()
        link?.onReceive = nil
        link?.onClosed = nil
        link?.close()
        link = nil
        setState(.disconnected)
    }

    private func received(_ data: Data) {
        rxCond.lock()
        rxBuffer.append(data)
        rxActivity = Date()
        rxCond.broadcast()
        rxCond.unlock()
    }

    // MARK: - Queue

    public func write(_ message: String) {
        queueCond.lock()
        messages.append(message)
        queueCond.signal()
        queueCond.unlock()
    }

    public func clearMessages() {
        queueCond.lock()
        messages.removeAll()
        queueCond.unlock()
    }

    /// Drops queued diagnostic requests but keeps ELM/bus setup commands
    /// (PROTO:/AT/ST), so a screen change never loses a pending bus initialisation.
    public func clearRequests() {
        queueCond.lock()
        messages.removeAll { m in
            let u = m.uppercased()
            return !(u.hasPrefix("PROTO:") || u.hasPrefix("AT") || u.hasPrefix("ST"))
        }
        queueCond.unlock()
    }

    public var queueLength: Int {
        queueCond.lock(); defer { queueCond.unlock() }
        return messages.count
    }

    public func setSessionActive(_ active: Bool) {
        queueCond.lock(); sessionActiveFlag = active; queueCond.unlock()
    }

    public func setSoftFlowControl(_ on: Bool) {
        queueCond.lock(); softFlowControl = on; queueCond.unlock()
    }

    // MARK: - ELM initialisation (queued, like the Java version)

    public func initElm() {
        write("PROTO:UNDEFINED")
        logInfo("Re-intializing ELM...")
        write("AT Z")
    }

    /// ElmBase.initCan. `canline`: -1/1 = 500k, 2 = 250k, 0 = auto from `brp`.
    public func initCan(rxa rxaIn: String, txa txaIn: String, canline canlineIn: Int = 0, brp: Bool = false) {
        logInfo("Intializing CAN protocol...")
        let canline = canlineIn == -1 ? 1 : canlineIn
        let rxaHex = rxaIn.uppercased(), txaHex = txaIn.uppercased()
        let rx = Int(rxaHex, radix: 16) ?? -1
        let tx = Int(txaHex, radix: 16) ?? -1
        write("PROTO:CAN:\(rx):\(tx)")
        write("AT WS")
        write("AT E1")
        write("AT S0")
        write("AT H0")
        write("AT L0")
        write("AT AL")
        write("AT CAF0")
        queueCond.lock(); let cfc0 = softFlowControl; queueCond.unlock()
        if cfc0 { write("AT CFC0") }
        let extended = rxaHex.count == 8
        if extended && txaHex.count >= 3 {
            write("AT CP " + String(txaHex.prefix(2)))
            write("AT SH " + String(txaHex.dropFirst(2)))
        } else {
            write("AT SH " + txaHex)
        }
        write("AT CRA " + rxaHex)
        write("AT FC SH " + txaHex)
        write("AT FC SD 30 00 00")
        write("AT FC SM 1")
        switch canline {
        case 0:
            write(brp ? (extended ? "AT SP 9" : "AT SP 8") : (extended ? "AT SP 7" : "AT SP 6"))
        case 1:
            write(extended ? "AT SP 7" : "AT SP 6")
        case 2:
            write(extended ? "AT SP 9" : "AT SP 8")
        default:
            write("STP 53")
            if canline == 3 { write("STPBR 500000") }
            else if canline == 4 { write("STPBR 250000") }
            else if canline == 5 { write("STPBR 125000") }
        }
        // As in DDT4All: some ELM327 clones (vLinker FS among them) reset CAF/S/AL
        // to their defaults when the protocol changes, so re-apply them after AT SP.
        write("AT CAF0")
        write("AT S0")
        write("AT AL")
    }

    private func initIso() {
        write("AT WS")
        write("AT E1")
        write("AT L0")
        write("AT D1")
        write("AT H0")
        write("AT AL")
        write("AT KW0")
    }

    public func initKwp(address addr: String, fastInit: Bool) {
        logInfo("Intializing KPW2000 protocol...")
        let a = Int(addr, radix: 16) ?? -1
        write("PROTO:KWP2000:\(0xF1):\(a)")
        initIso()
        write("AT SH 81 \(addr) F1")
        write("AT SW 96")
        write("AT WM 81 \(addr) F1 3E")
        write("AT IB10")
        write("AT ST FF")
        write("AT AT 0")
        if !fastInit {
            write("AT SP 4")
            write("AT IIA \(addr)")
            write("AT SI")
        } else {
            write("AT SP 5")
            write("AT FI")
        }
        write("AT AT 1")
    }

    public func initIso8(address addr: String) {
        logInfo("Intializing ISO8 protocol...")
        let a = Int(addr, radix: 16) ?? -1
        write("PROTO:ISO8:\(0xF1):\(a)")
        initIso()
        write("AT SH 81 \(addr) F1")
        write("AT SW 96")
        write("AT WM 81 \(addr) F1 3E")
        write("AT IB10")
        write("AT ST FF")
        write("AT SP 3")
        write("AT AT 0")
        write("AT SI")
        write("AT AT 1")
    }

    /// ElmBase.setTimeOut — `AT ST` in 4 ms units, max FF.
    public func setTimeOut(_ timeOutMs: Int) {
        let t = min(timeOutMs / 4, 255)
        write("AT ST " + String(t, radix: 16))
    }

    public func setEcuName(_ name: String) {
        writeLog("New session with ECU \(name)")
    }

    // MARK: - Worker thread (connectedThreadMainLoop)

    private func startWorker() {
        queueCond.lock()
        running = true
        queueCond.unlock()
        consecutiveTimeouts = 0
        let t = Thread { [weak self] in self?.mainLoop() }
        t.name = "ElmWorker"
        t.qualityOfService = .userInitiated
        worker = t
        t.start()
    }

    private func stopWorker() {
        queueCond.lock()
        running = false
        queueCond.broadcast()
        queueCond.unlock()
        rxCond.lock(); rxCond.broadcast(); rxCond.unlock()
        worker = nil
    }

    private var isRunning: Bool {
        queueCond.lock(); defer { queueCond.unlock() }
        return running
    }

    private func mainLoop() {
        var timer = Date()
        while true {
            queueCond.lock()
            if !running { queueCond.unlock(); break }
            if messages.isEmpty { _ = queueCond.wait(until: Date().addingTimeInterval(0.01)) }
            if !running { queueCond.unlock(); break }
            var message: String?
            var remaining = 0
            if !messages.isEmpty {
                message = messages.removeFirst()
                remaining = messages.count
            }
            let sessionActive = sessionActiveFlag
            let cfc0 = softFlowControl
            queueCond.unlock()

            if let message {
                let upper = message.uppercased()
                if upper.hasPrefix("PROTO:") {
                    let parts = message.split(separator: ":").map(String.init)
                    workerProtocol = parts.count > 1 ? parts[1] : "UNDEFINED"
                    if parts.count > 3 {
                        rxa = Int(parts[2]) ?? -1
                        txa = Int(parts[3]) ?? -1
                    }
                } else if message.count > 6 && upper.hasPrefix("DELAY:") {
                    let ms = Int(message.dropFirst(6)) ?? 0
                    if ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000.0) }
                } else if message.count > 2 && (upper.hasPrefix("AT") || upper.hasPrefix("ST")) {
                    let result = writeRaw(message)
                    emitCurrent(.response(request: message, reply: result))
                    emitCurrent(.queue(remaining: remaining))
                } else {
                    if workerProtocol == "CAN" {
                        if cfc0 { sendCanCFC0(message) } else { sendCan(message) }
                    } else {
                        sendISO(message)
                    }
                    emitCurrent(.queue(remaining: remaining))
                    timer = Date()
                }
            }

            // Keep session alive (tester present)
            if workerProtocol == "CAN" && sessionActive && Date().timeIntervalSince(timer) > 1.5 && rxa > 0 {
                timer = Date()
                _ = writeRaw("013E")
            }
        }
    }

    // MARK: - Raw I/O

    /// Sends one line to the ELM and returns everything up to the '>' prompt,
    /// with CR converted to LF (as both Java transports did).
    func writeRaw(_ command: String) -> String {
        guard let link, isRunning else { return "ERROR : DISCONNECTED" }
        rxCond.lock()
        rxBuffer.removeAll(keepingCapacity: true)
        rxActivity = Date()
        rxCond.unlock()

        link.send(Data((command + "\r").utf8))

        rxCond.lock()
        var promptIndex = rxBuffer.firstIndex(of: 0x3E)
        while promptIndex == nil && isRunningUnlockedCheck() {
            let deadline = rxActivity.addingTimeInterval(idleTimeout)
            if Date() >= deadline { break }
            _ = rxCond.wait(until: deadline)
            promptIndex = rxBuffer.firstIndex(of: 0x3E)
        }
        let raw: Data
        if let idx = promptIndex {
            raw = rxBuffer.subdata(in: rxBuffer.startIndex..<idx)
            rxBuffer.removeSubrange(rxBuffer.startIndex...idx)
        } else {
            raw = rxBuffer
            rxBuffer.removeAll()
        }
        rxCond.unlock()

        var bytes = [UInt8]()
        bytes.reserveCapacity(raw.count)
        for b in raw where b != 0 { bytes.append(b == 0x0D ? 0x0A : b) }
        let text = String(decoding: bytes, as: UTF8.self)

        if promptIndex == nil {
            if !isRunning { return "ERROR : DISCONNECTED" }
            consecutiveTimeouts += 1
            logInfo("ELM timeout on '\(command)'")
            if consecutiveTimeouts >= 3 {
                connectionLost("ELM not responding")
                return "ERROR : DISCONNECTED"
            }
            return text.isEmpty ? "ERROR : TIMEOUT" : text
        }
        consecutiveTimeouts = 0
        return text
    }

    private func isRunningUnlockedCheck() -> Bool {
        // queueCond and rxCond are distinct locks, safe to nest in this order only.
        queueCond.lock(); defer { queueCond.unlock() }
        return running
    }

    // MARK: - ISO (KWP2000 / ISO8)

    func sendISO(_ message: String) {
        let messageResult = writeRaw(message)
        var resultMess = ""
        for s in JavaCompat.split(messageResult, "\n") {
            let cleaned = s.replacingOccurrences(of: " ", with: "")
            if cleaned == message { continue }   // echo cancellation
            resultMess += cleaned
        }
        writeLog("ISO SENT: " + timestamp() + message)
        writeLog("ISO RECV: " + timestamp() + resultMess)
        emitCurrent(.response(request: message, reply: resultMess))
    }

    // MARK: - CAN

    func sendCan(_ message: String) {
        let rawCommand = IsoTP.encode(message)
        var responses = [String]()
        var error = false
        var errorMsg = ""

        for (index, frame) in rawCommand.enumerated() {
            let frsp = writeRaw(frame)
            let isLast = index == rawCommand.count - 1
            for line in JavaCompat.split(frsp, "\n") {
                var s = line.replacingOccurrences(of: "\n", with: "")
                if s == frame { continue }   // echo cancellation
                s = s.replacingOccurrences(of: " ", with: "")
                if s.isEmpty { continue }
                // Fix: an intermediate consecutive frame gets no ECU answer, so the ELM
                // prints NO DATA; the original treated that as an error.
                if !isLast && s == "NODATA" { continue }
                if JavaCompat.isHexadecimal(s) {
                    if s.first == "3" { continue }   // flow control frame
                    responses.append(s)
                } else {
                    errorMsg += frsp
                    error = true
                }
            }
        }

        let result = error ? "ERROR : " + errorMsg.trimmingCharacters(in: .whitespacesAndNewlines) : IsoTP.decode(responses)
        writeLog("CAN SENT: " + timestamp() + message)
        writeLog("CAN RECV: " + timestamp() + result)
        emitCurrent(.response(request: message, reply: result))
    }

    /// ElmBase.sendCanCFC0 — software flow control (AT CFC0).
    func sendCanCFC0(_ message: String) {
        guard JavaCompat.isHexadecimal(message) else { return }
        let rawCommand = IsoTP.encode(message)
        var responses = [String]()
        var noErrors = true
        var errorMsg = ""
        var atr1 = true

        var bs = 1      // burst size
        var st = 0      // frame interval (ms)
        var fc = 0      // current frame
        let fn = rawCommand.count

        if fn > 1 && rawCommand[0].count > 15 { _ = writeRaw("ATST4B") }

        func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

        while fc < fn {
            if !atr1 { _ = writeRaw("ATR1"); atr1 = true }
            var tb = nowMs()
            if fn > 1 && fc == fn - 1 {
                _ = writeRaw("ATSTFF")
                _ = writeRaw("ATAT1")
            }
            let current = rawCommand[fc]
            let frsp: String
            if fc == 0 || (fc == fn - 1 && current.count < 16) {
                frsp = writeRaw(current + "1")   // expect a single frame back
            } else {
                frsp = writeRaw(current)
            }
            fc += 1

            var s0 = [String]()
            let sent = rawCommand[fc - 1]
            for line in JavaCompat.split(frsp, "\n") {
                let subs = line.count > sent.count ? String(line.prefix(sent.count)) : line
                if subs == sent { continue }   // echo cancellation
                let s = line.replacingOccurrences(of: " ", with: "")
                if s.isEmpty { continue }
                if JavaCompat.isHexadecimal(s) { s0.append(s) }
            }

            for s in s0 {
                if s.first == "3" {
                    // flow control frame: burst size and separation time
                    let bsHex = s.count >= 4 ? JavaCompat.substringClamped(s, 2, 4) : "03"
                    bs = Int(bsHex, radix: 16) ?? 3
                    let fi = s.count >= 6 ? JavaCompat.substringClamped(s, 4, 6) : "EF"
                    if fi.uppercased().first == "F" {
                        st = (Int(JavaCompat.substringClamped(fi, 1, 2), radix: 16) ?? 0) * 100
                    } else {
                        st = Int(fi, radix: 16) ?? 0
                    }
                    break
                } else if s.hasPrefix("037F") && JavaCompat.substringClamped(s, 6, 8) == "78" {
                    if s == s0.last {
                        noErrors = false
                        errorMsg = "Cannot handle 037F78 yet !"
                        break
                    }
                    continue
                } else {
                    responses.append(s)
                }
            }

            var cf = min(bs - 1, (fn - fc) - 1)
            if cf > 0 { _ = writeRaw("ATR0"); atr1 = false }
            while cf > 0 {
                cf -= 1
                let tc = nowMs()
                if tc - tb < Int64(st) { Thread.sleep(forTimeInterval: Double(Int64(st) - (tc - tb)) / 1000.0) }
                tb = tc
                _ = writeRaw(rawCommand[fc])
                fc += 1
            }
        }

        var result = ""
        if responses.count != 1 {
            noErrors = false
            if errorMsg.isEmpty { errorMsg = "Cannot send CAN frame with software flow control" }
        } else {
            let r0 = responses[0]
            if r0.first == "0" {
                // single frame — decoded by IsoTP below
            } else if r0.first == "1" {
                var nbytes = Int(JavaCompat.substringClamped(r0, 1, 4), radix: 16) ?? 0
                nbytes -= 6
                let nframes = 1 + nbytes / 7 + (nbytes % 7 > 0 ? 1 : 0)
                var cframe = 1
                while cframe < nframes {
                    let sBS = String(min(nframes - responses.count, 0xF), radix: 16)
                    let flowControl = "300" + sBS + "00" + sBS
                    let frsp = writeRaw(flowControl)
                    var noData = false
                    var progressed = false
                    for line in JavaCompat.split(frsp, "\n") {
                        if fc > 0 && line.hasPrefix(rawCommand[fc - 1]) { continue }
                        // Fix: also cancel the echo of the flow-control frame itself
                        if line.replacingOccurrences(of: " ", with: "") == flowControl { continue }
                        if line.contains("NO DATA") { noData = true; break }
                        let s = line.replacingOccurrences(of: " ", with: "")
                        if s.isEmpty { continue }
                        if JavaCompat.isHexadecimal(s) {
                            responses.append(s)
                            if s.first == "2" {
                                let seq = Int(JavaCompat.substringClamped(s, 1, 2), radix: 16) ?? -1
                                if seq != cframe % 16 {
                                    noErrors = false
                                    errorMsg = "Multiline software flow control lost frame"
                                    continue
                                }
                                cframe += 1
                                progressed = true
                            }
                        }
                    }
                    // Fix: the original looped forever on NO DATA / no progress.
                    if noData || !progressed {
                        if noErrors { noErrors = false; errorMsg = "Multiline software flow control: no data" }
                        break
                    }
                }
            } else {
                noErrors = false
                errorMsg = "CFC0 first frame omitted"
            }
        }

        // Fix: the original replaced the *request* with the error text.
        result = noErrors ? IsoTP.decode(responses) : "ERROR : " + errorMsg
        writeLog("CAN CFC SENT: " + timestamp() + message)
        writeLog("CAN CFC RECV: " + timestamp() + result)
        emitCurrent(.response(request: message, reply: result))
    }

    // MARK: - Log file

    private func openLogFile() {
        guard let url = logURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = fm.createFile(atPath: url.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: url)
        _ = try? logHandle?.seekToEnd()
        writeLog(timestamp() + "Log file created")
    }

    public func resetLogFile() {
        logLock.lock()
        try? logHandle?.close()
        logHandle = nil
        logLock.unlock()
        if let url = logURL { try? FileManager.default.removeItem(at: url) }
        openLogFile()
    }

    /// The log file is rotated at this size (one previous file, log.old.txt, is kept).
    public var maxLogFileSize: UInt64 = 5_000_000

    private func writeLog(_ line: String) {
        logLock.lock(); defer { logLock.unlock() }
        guard let h = logHandle else { return }
        try? h.write(contentsOf: Data((line + "\n").utf8))
        if let size = try? h.offset(), size > maxLogFileSize, let url = logURL {
            try? h.close()
            logHandle = nil
            let old = url.deletingPathExtension().appendingPathExtension("old.txt")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
        }
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func timestamp() -> String { "[" + Self.tsFormatter.string(from: Date()) + "] " }
}
