import XCTest
@testable import EcuCore

/// A small ELM327 + ECU simulator: raw CAN frames (AT CAF0), echo, automatic or
/// software flow control, response-count digit, KWP passthrough.
final class MockElm: ElmLink {
    var displayName = "MockELM"
    var onReceive: ((Data) -> Void)?
    var onClosed: ((Error?) -> Void)?

    private let q = DispatchQueue(label: "mock.elm")
    private let lock = NSLock()
    private var echo = true
    private var autoFlowControl = true
    private var pendingCF: [String] = []
    private var rxTotal = 0
    private var rxData = ""
    private var _log: [String] = []
    var mute = false
    var kwpMode = false
    /// request payload (hex) → response payload (hex)
    var ecu: [String: String] = [:]

    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }

    func open(completion: @escaping (Error?) -> Void) { q.async { completion(nil) } }
    func close() {}

    func send(_ data: Data) {
        let s = String(decoding: data, as: UTF8.self)
        q.async { self.handle(s) }
    }

    private func reply(_ cmd: String, _ lines: [String]) {
        var out = echo ? cmd + "\r" : ""
        for l in lines { out += l + "\r" }
        out += "\r>"
        // deliver in two chunks, like a BLE notification stream would
        let bytes = Array(out.utf8)
        let half = bytes.count / 2
        onReceive?(Data(bytes[0..<half]))
        onReceive?(Data(bytes[half...]))
    }

    private func handle(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); _log.append(cmd); lock.unlock()
        if mute { return }
        let up = cmd.uppercased().replacingOccurrences(of: " ", with: "")
        if up.hasPrefix("AT") || up.hasPrefix("ST") {
            switch up {
            case "ATZ": echo = true; autoFlowControl = true; reply(cmd, ["", "ELM327 v1.5"]); return
            case "ATE0": echo = false
            case "ATE1": echo = true
            case "ATCFC0": autoFlowControl = false
            case "ATCFC1": autoFlowControl = true
            default: break
            }
            reply(cmd, ["OK"])
            return
        }
        if kwpMode {
            reply(cmd, [ecu[up].map(spaced) ?? "NO DATA"])
            return
        }
        var hex = up
        var count: Int?
        if hex.count % 2 == 1 { count = Int(String(hex.removeLast()), radix: 16) }
        let c = Array(hex)
        guard let pci = c.first else { reply(cmd, ["?"]); return }
        switch pci {
        case "0":
            let n = Int(String(c[1]), radix: 16)!
            respond(cmd, String(c[2..<(2 + n * 2)]), count: count)
        case "1":
            rxTotal = Int(String(c[1..<4]), radix: 16)!
            rxData = String(c[4...])
            reply(cmd, ["300000"])          // ECU flow control
        case "2":
            rxData += String(c[2...])
            if rxData.count >= rxTotal * 2 {
                respond(cmd, String(rxData.prefix(rxTotal * 2)), count: count)
            } else {
                reply(cmd, ["NO DATA"])
            }
        case "3":
            let n = min(count ?? pendingCF.count, pendingCF.count)
            let frames = Array(pendingCF.prefix(n))
            pendingCF.removeFirst(n)
            reply(cmd, frames)
        default:
            reply(cmd, ["?"])
        }
    }

    private func respond(_ cmd: String, _ request: String, count: Int?) {
        guard let resp = ecu[request] else { reply(cmd, ["NO DATA"]); return }
        let frames = IsoTP.encode(resp)
        if frames.count == 1 || autoFlowControl {
            reply(cmd, frames)
        } else {
            reply(cmd, [frames[0]])
            pendingCF = Array(frames.dropFirst())
        }
    }

    private func spaced(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { i -> String in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[s..<hex.index(s, offsetBy: 2)])
        }.joined(separator: " ")
    }
}

final class ElmSessionTests: XCTestCase {
    private var events = [ElmEvent]()
    private let eventsLock = NSLock()
    private let cbq = DispatchQueue(label: "test.callbacks")

    private func makeSession(_ mock: MockElm) -> ElmSession {
        let s = ElmSession(callbackQueue: cbq, logURL: nil)
        s.idleTimeout = 0.5
        cbq.sync {
            s.changeHandler { [weak self] e in
                guard let self else { return }
                self.eventsLock.lock(); self.events.append(e); self.eventsLock.unlock()
            }
        }
        s.connect(link: mock)
        waitFor { s.isConnected }
        return s
    }

    private func waitFor(timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(cond(), "condition not met in time")
    }

    private func responses() -> [(String, String)] {
        eventsLock.lock(); defer { eventsLock.unlock() }
        return events.compactMap { if case let .response(r, p) = $0 { return (r, p) } else { return nil } }
    }

    private func reply(to request: String, in s: ElmSession) -> String? {
        waitFor { self.responses().contains { $0.0 == request } }
        return responses().last { $0.0 == request }?.1
    }

    func testCanSingleAndMultiFrame() {
        let mock = MockElm()
        let ident = "6180" + String(repeating: "11", count: 24)
        mock.ecu = ["10C0": "50C0", "2180": ident]
        let s = makeSession(mock)
        s.initElm()
        s.initCan(rxa: "76B", txa: "74B")
        s.write("10C0")
        s.write("2180")
        XCTAssertEqual(reply(to: "10C0", in: s), "50C0")
        XCTAssertEqual(reply(to: "2180", in: s), ident)
        XCTAssertTrue(mock.log.contains("AT SH 74B"))
        XCTAssertTrue(mock.log.contains("AT CRA 76B"))
        XCTAssertTrue(mock.log.contains("AT SP 6"))
        XCTAssertFalse(mock.log.contains("AT CFC0"))
        s.disconnect()
    }

    func testCanMultiFrameWrite() {
        let mock = MockElm()
        let write = "2E2130" + String(repeating: "AB", count: 17)   // 20 bytes → FF + 2 CF
        mock.ecu = [write: "6E2130"]
        let s = makeSession(mock)
        s.initCan(rxa: "76B", txa: "74B")
        s.write(write)
        XCTAssertEqual(reply(to: write, in: s), "6E2130")
        XCTAssertTrue(mock.log.contains("10142E2130ABABAB"))
        s.disconnect()
    }

    func testSoftwareFlowControl() {
        let mock = MockElm()
        let ident = "6180" + (0..<30).map { String(format: "%02X", $0) }.joined()
        mock.ecu = ["2180": ident, "10C0": "50C0"]
        let s = makeSession(mock)
        s.setSoftFlowControl(true)
        s.initCan(rxa: "76B", txa: "74B")
        s.write("10C0")
        s.write("2180")
        XCTAssertEqual(reply(to: "10C0", in: s), "50C0")
        XCTAssertEqual(reply(to: "2180", in: s), ident)
        XCTAssertTrue(mock.log.contains("AT CFC0"))
        XCTAssertTrue(mock.log.contains("0221801"))
        s.disconnect()
    }

    func testKwp() {
        let mock = MockElm()
        mock.kwpMode = true
        mock.ecu = ["2180": "6180AABBCC"]
        let s = makeSession(mock)
        s.initKwp(address: "7A", fastInit: true)
        s.write("2180")
        XCTAssertEqual(reply(to: "2180", in: s), "6180AABBCC")
        XCTAssertTrue(mock.log.contains("AT SH 81 7A F1"))
        XCTAssertTrue(mock.log.contains("AT FI"))
        s.disconnect()
    }

    func testErrorsAndDelay() {
        let mock = MockElm()
        let s = makeSession(mock)
        s.initCan(rxa: "76B", txa: "74B")
        s.write("DELAY:50")
        s.write("1234")
        XCTAssertEqual(reply(to: "1234", in: s)?.hasPrefix("ERROR"), true)
        s.disconnect()
    }

    func testTimeoutsDisconnect() {
        let mock = MockElm()
        let s = makeSession(mock)
        mock.mute = true
        s.write("AT I")
        s.write("AT I")
        s.write("AT I")
        waitFor(timeout: 5) { s.state == .disconnected }
    }

    func testHandlerSwitchReplaysState() {
        let mock = MockElm()
        let s = makeSession(mock)
        var got: ElmState?
        cbq.sync { s.changeHandler { e in if case let .state(st) = e { got = st } } }
        waitFor { self.cbq.sync { got } == .connected }
        s.disconnect()
    }

    func testNrcTable() {
        XCTAssertEqual(ElmSession.ecuErrorCode("78"), "Request Correctly Received-Response Pending")
        XCTAssertEqual(ElmSession.ecuErrorCode("7f"), "Service Not Supported In Active Session")
    }
}
