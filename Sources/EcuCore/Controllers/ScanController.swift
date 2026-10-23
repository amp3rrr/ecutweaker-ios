import Foundation

/// UI-independent port of MainActivity's bus scan / ECU auto-identification
/// (2180 "old" method and 22F1xx UDS method).
public final class ScanController {
    public struct IdentFields: Equatable {
        public var diagVersion = ""
        public var supplier = ""
        public var soft = ""
        public var version = ""
    }

    public let database: EcuDatabase
    public let session: ElmSession
    public var address: Int

    public private(set) var isScanning = false
    public private(set) var fields = IdentFields()
    public private(set) var results: [EcuDatabase.IdentResult] = []

    public var onChange: (() -> Void)?
    public var onLog: ((String) -> Void)?

    private var family = "CAN"
    private var newIdent = IdentFields()
    private var newIdentMask = 0

    public init(database: EcuDatabase, session: ElmSession, address: Int) {
        self.database = database
        self.session = session
        self.address = address
    }

    private func log(_ s: String) { onLog?(s) }

    /// CAN: old (10C0 + 2180) then new (1003 + 22F1A0/8A/94/95) identification.
    public func scanCAN() {
        guard session.isConnected else { log("No ELM connection"); return }
        guard let addrs = canAddresses() else {
            log("Cannot initialize CAN bus: TX/RX addresses not found for ECU")
            return
        }
        let (rxa, txa) = addrs
        start(family: "CAN")
        session.setSessionActive(false)
        session.initElm()
        session.initCan(rxa: rxa, txa: txa, canline: 0, brp: false)
        session.setTimeOut(1000)
        session.write("10C0")
        session.write("2180")

        session.initElm()
        session.initCan(rxa: rxa, txa: txa, canline: 0, brp: false)
        session.setTimeOut(1000)
        for cmd in ["1003", "22F1A0", "22F18A", "22F194", "22F195"] { session.write(cmd) }
    }

    /// KWP2000: slow init then fast init, 10C0 + 2180 each.
    public func scanKWP() {
        guard session.isConnected else { log("No ELM connection"); return }
        start(family: "KWP")
        let hexAddr = JavaCompat.padLeft(String(address, radix: 16).uppercased(), 2, "0")
        session.setSessionActive(false)
        session.initElm()
        session.initKwp(address: hexAddr, fastInit: false)
        session.setTimeOut(1000)
        session.write("10C0")
        session.write("2180")
        session.initKwp(address: hexAddr, fastInit: true)
        session.setTimeOut(1000)
        session.write("10C0")
        session.write("2180")
    }

    public func cancel() {
        session.clearMessages()
        isScanning = false
        onChange?()
    }

    private func start(family f: String) {
        family = f
        results = []
        fields = IdentFields()
        newIdent = IdentFields()
        newIdentMask = 0
        isScanning = true
        onChange?()
    }

    /// MainActivity.initBus("CAN") addresses (11-bit first, then 29-bit).
    func canAddresses() -> (String, String)? {
        if let tx = database.txAddress(address), let rx = database.rxAddress(address) { return (rx, tx) }
        if let tx = database.txExtAddress(address), let rx = database.rxExtAddress(address) { return (rx, tx) }
        return nil
    }

    // MARK: - Events

    public func handle(_ event: ElmEvent) {
        switch event {
        case .response(let request, let reply):
            handleResult(request: request, reply: reply)
        case .queue(let n):
            if n == 0 && isScanning { isScanning = false; finishNewIdentIfPossible() }
        case .state(let s):
            if s != .connected && s != .connecting { isScanning = false }
        default:
            break
        }
        onChange?()
    }

    private func handleResult(request: String, reply: String) {
        if reply.isEmpty || request.uppercased().hasPrefix("AT") { return }
        let r = reply.replacingOccurrences(of: " ", with: "")
        log("> \(request) : \(reply)")

        // Old method (2180)
        if let p = EcuDatabase.parseOldIdent(r) {
            session.clearMessages()
            isScanning = false
            fields = IdentFields(diagVersion: p.diag, supplier: p.supplier, soft: p.soft, version: p.version)
            log("ECU found : supplier \(p.supplier) diag version : \(p.diag) version : \(p.version) soft version : \(p.soft)")
            identify(fields)
            return
        }

        // New method (UDS 22F1xx), decoded like DDT4All
        guard r.count > 5 else { return }
        if r.hasPrefix("62F1A0") {
            let hex = JavaCompat.substringClamped(r, 6, 8)
            newIdent.diagVersion = Int(hex, radix: 16).map(String.init) ?? hex
            newIdentMask |= 1
        } else if r.hasPrefix("62F18A") {
            newIdent.supplier = EcuDatabase.asciiPayload(r, from: 6, to: 132).trimmingCharacters(in: .whitespaces)
            newIdentMask |= 2
        } else if r.hasPrefix("62F194") {
            newIdent.soft = EcuDatabase.asciiPayload(r, from: 6, stripPadding: true)
            newIdentMask |= 4
        } else if r.hasPrefix("62F195") {
            newIdent.version = EcuDatabase.asciiPayload(r, from: 6, to: 38)
            newIdentMask |= 8
        } else {
            return
        }
        fields = newIdent
        if newIdentMask == 15 {
            newIdentMask = 0
            identify(newIdent)
        }
    }

    /// Scan finished with a partial UDS identification (e.g. 22F195 refused):
    /// still try to match with what we have (diag version + supplier + soft).
    private func finishNewIdentIfPossible() {
        let haveDiagSupplierSoft = newIdentMask & 0b0111 == 0b0111
        if haveDiagSupplierSoft && newIdentMask != 15 && results.isEmpty {
            identify(newIdent)
        }
    }

    private func identify(_ f: IdentFields) {
        results = database.identify(address: address, diagVersion: f.diagVersion, supplier: f.supplier,
                                    soft: f.soft, version: f.version, protocolFamily: family)
        if let first = results.first {
            log(first.exact ? "ECU match : \(first.info.ecuName)" : "ECU partial match : \(first.info.ecuName)")
        } else {
            log("No relevant ECU file found")
        }
    }
}
