import Foundation

/// UI-independent port of ScreenActivity: opens an ECU + its layout, sends the
/// requests of the current screen, decodes replies into display values, executes
/// buttons (frame building from inputs), reads/clears DTCs, auto-reload.
/// The SwiftUI layer observes it through the `on…` callbacks.
public final class ScreenController {
    public let ecu: Ecu
    public let layout: Layout
    public let href: String
    public let session: ElmSession
    private let zip: ZipFileSystem?

    public private(set) var currentScreen: Layout.ScreenData?
    public private(set) var currentScreenName: String?
    /// Display values keyed by display text ("value unit"), "---" until received.
    public private(set) var displayValues: [String: String] = [:]
    /// Text field contents keyed by input text.
    public var inputValues: [String: String] = [:]
    /// Selected list item keyed by input text.
    public var pickerValues: [String: String] = [:]
    public private(set) var autoReload = false
    /// True while the ELM queue is not empty (buttons disabled, like setElMWorking).
    public private(set) var busy = false
    public private(set) var softFlowControl: Bool
    public private(set) var canTimeout = 0

    private var displaysRequestSet = Set<String>()
    private var startRequestSet = Set<String>()
    private var requestsInputs = [String: [Layout.InputData]]()
    private var lastSDSTime = Date.distantPast
    /// Last reply (hex) of each request, for diagnostics.
    public private(set) var lastResponses: [String: String] = [:]
    private var currentDtcRequestName = ""
    private var currentDtcRequestBytes = ""

    public var onChange: (() -> Void)?
    public var onLog: ((String) -> Void)?
    public var onAlert: ((String) -> Void)?
    public var onDTCReport: (([[String]]) -> Void)?
    /// Called when the link dropped (Java: activity.reconnect()).
    public var onDisconnected: (() -> Void)?

    public init(ecuJSON: String, layoutJSON: String?, href: String, session: ElmSession,
                zip: ZipFileSystem?, softFlowControl: Bool = false) throws {
        ecu = try J.releasingTemporaries { try Ecu(json: ecuJSON) }
        if let lj = layoutJSON, let l = try? Layout(json: lj) {
            layout = l
        } else {
            layout = Layout(object: [:])
        }
        self.href = href
        self.session = session
        self.zip = zip
        self.softFlowControl = softFlowControl
        session.setSoftFlowControl(softFlowControl)
    }

    public convenience init(database: EcuDatabase, href: String, session: ElmSession, softFlowControl: Bool = false) throws {
        guard let json = database.zipString(href) else { throw EcuError.database("ECU file \(href) not found in ecu.zip") }
        try self.init(ecuJSON: json, layoutJSON: database.zipString(href + ".layout"), href: href,
                      session: session, zip: database.zip, softFlowControl: softFlowControl)
    }

    private func log(_ s: String) { onLog?(s) }

    /// Definition and decoding details of a display / input value (long-press in the UI).
    public func diagnostics(forData name: String) -> String {
        // Re-read the entry from the file instead of keeping every raw JSON object in memory.
        let raw: [String: Any]? = J.releasingTemporaries {
            guard let d = zip?.data(href), let root = try? J.parse(d) as? [String: Any] else { return nil }
            return J.obj(root["data"]).flatMap { J.obj($0[name]) }
        }
        return ecu.diagnostics(forData: name, responses: lastResponses, rawJSON: raw)
    }

    /// The ECU file (and its layout) as stored in ecu.zip.
    public func ecuFiles() -> [(name: String, data: Data)] {
        var out = [(name: String, data: Data)]()
        if let d = zip?.data(href) { out.append((href, d)) }
        if let l = zip?.data(href + ".layout") { out.append((href + ".layout", l)) }
        return out
    }

    // MARK: - Events (messageHandler)

    public func handle(_ event: ElmEvent) {
        switch event {
        case .state(let s):
            switch s {
            case .connected: initELM()
            case .none, .disconnected: onDisconnected?()
            case .connecting: break
            }
        case .response(let request, let reply):
            handleElmResult(request: request, reply: reply)
        case .deviceName(let name):
            log("New device : \(name)")
        case .queue(let remaining):
            setElmWorking(queueEmpty: remaining == 0)
        case .log:
            break
        }
        onChange?()
    }

    private var isConnected: Bool { session.isConnected }

    private func sendCmd(_ cmd: String) {
        guard isConnected else {
            log("Frame not sent (no connection) : \(cmd)")
            return
        }
        session.write(cmd)
    }

    private func sendDelay(_ ms: Int) {
        guard isConnected else {
            log("No chat session")
            return
        }
        session.write("DELAY:\(ms)")
    }

    // MARK: - Bus init

    private func initELM() {
        guard isConnected else { return }
        session.initElm()
        initBus()
    }

    private func initBus() {
        guard isConnected else { return }
        switch ecu.protocolName {
        case "CAN":
            session.setEcuName(ecu.name)
            session.initCan(rxa: ecu.rxId, txa: ecu.txId, canline: 0, brp: ecu.isCan250)
        case "KWP2000":
            session.initKwp(address: ecu.functionalAddress, fastInit: ecu.fastInit)
        case "ISO8":
            session.initIso8(address: ecu.functionalAddress)
        default:
            log("Unknown protocol '\(ecu.protocolName)'")
        }
        updateDisplays()
    }

    // MARK: - Screens

    public var categories: [String] { layout.categoryNames }
    public func screens(in category: String) -> [String] { layout.screenNames(category: category) }

    /// ScreenActivity.drawScreen (model part).
    public func drawScreen(_ name: String) {
        session.clearRequests()
        displayValues = [:]
        inputValues = [:]
        pickerValues = [:]
        displaysRequestSet = []
        startRequestSet = []
        requestsInputs = [:]
        guard let screen = layout.screen(name) else { currentScreen = nil; onChange?(); return }
        currentScreen = screen
        currentScreenName = name

        for pre in screen.preSendData {
            guard let req = ecu.request(pre.request) else { continue }
            if req.sentBytes.hasPrefix("10") { continue }   // skip start diagnostic session
            startRequestSet.insert(pre.request)
        }
        for d in screen.displays {
            displayValues[d.text] = "---"
            displaysRequestSet.insert(d.request)
        }
        for input in screen.inputs {
            if let first = pickerItems(for: input).first { pickerValues[input.text] = first }
            requestsInputs[input.request, default: []].append(input)
        }
        updateDisplays()
        onChange?()
    }

    public func isPicker(_ input: Layout.InputData) -> Bool {
        !(ecu.dataItem(input.text)?.items.isEmpty ?? true)
    }

    public func pickerItems(for input: Layout.InputData) -> [String] {
        (ecu.dataItem(input.text)?.items.keys.map { $0 } ?? []).sorted()
    }

    /// Picture referenced by a "::pic:name" label or "::btn:…|name" button, from graphics/ in ecu.zip.
    public func imageData(forPictureText text: String, isButton: Bool) -> Data? {
        var name = text
        if isButton {
            for p in ["::BTN:|", "::btn:|", "::btn:DOWN|", "::btn:UP|", "::btn:LEFT|", "::btn:RIGHT|"] {
                name = name.replacingOccurrences(of: p, with: "")
            }
        } else {
            name = name.replacingOccurrences(of: "::pic:", with: "").replacingOccurrences(of: "::PIC:", with: "")
        }
        name = name.replacingOccurrences(of: "\\", with: "/")
        for candidate in ["graphics/\(name).GIF", "graphics/\(name).gif"] {
            if let d = zip?.data(candidate) { return d }
        }
        return nil
    }

    // MARK: - Requests

    /// ScreenActivity.updateDisplays
    public func updateDisplays() {
        guard isConnected, let screen = currentScreen else { return }
        if Date().timeIntervalSince(lastSDSTime) > 3 {
            sendCmd(ecu.defaultSDS)
            lastSDSTime = Date()
        }
        session.setSessionActive(true)
        for pre in screen.preSendData {
            if pre.delay > 0 { sendDelay(pre.delay) }
            if let req = ecu.request(pre.request) { sendCmd(req.sentBytes) }
        }
        for name in displaysRequestSet.sorted() {
            guard let req = ecu.request(name) else {
                log("Cannot find request \(name)")
                continue
            }
            sendCmd(req.sentBytes)
        }
    }

    private func updateScreen(request req: String, response: String) {
        if req.isEmpty && response.isEmpty { return }
        if response.count < 4 { return }
        guard let responseHeader = Int(JavaCompat.substringClamped(response, 0, 2), radix: 16),
              let requestHeader = Int(JavaCompat.substringClamped(req, 0, 2), radix: 16) else {
            log("Cannot decode service ID of \(response)/\(req)")
            return
        }
        if requestHeader + 0x40 != responseHeader {
            log("Bad response (\(responseHeader)) to request : \(requestHeader)")
            return
        }
        for name in displaysRequestSet.union(startRequestSet) {
            guard let request = ecu.request(name), request.sentBytes == req else { continue }
            lastResponses[name] = response
            let values: [String: (value: String, unit: String)]
            do {
                values = try ecu.requestValuesWithUnit(JavaCompat.hexStringToBytes(response), request: name)
            } catch {
                log("Cannot decode request \(name)")
                log("Exception : \(error)")
                continue
            }
            for (key, v) in values {
                if displayValues[key] != nil { displayValues[key] = v.value + " " + v.unit }
                if let input = currentScreen?.inputs.first(where: { $0.text == key }) {
                    if isPicker(input) {
                        if pickerItems(for: input).contains(v.value) { pickerValues[key] = v.value }
                    } else {
                        inputValues[key] = v.value
                    }
                }
            }
        }
    }

    // MARK: - Buttons

    /// ScreenActivity.exectuteButtonCommands
    public func executeButton(_ uniqueName: String) {
        guard let button = currentScreen?.button(named: uniqueName) else { return }
        var commands = [(delay: Int, frame: String)]()
        for send in button.sendData {
            guard let request = ecu.request(send.request) else {
                log("Cannot find request \(send.request)")
                return
            }
            guard let inputs = requestsInputs[send.request] else {
                commands.append((send.delay, request.sentBytes))
                continue
            }
            var ordered = [(String, String)]()
            for input in inputs {
                if isPicker(input) {
                    guard let v = pickerValues[input.text] else { continue }
                    ordered.append((input.text, v))
                } else {
                    let text = inputValues[input.text] ?? ""
                    if request.sendDataItems[input.text] != nil, let data = ecu.dataItem(input.text), !data.bytesASCII {
                        if data.scaled {
                            let normalized = text.replacingOccurrences(of: ",", with: ".")
                            if normalized.range(of: #"^[-+]?[0-9]*\.?[0-9]+$"#, options: .regularExpression) == nil {
                                onAlert?("Invalid value for \(input.text): '\(text)'")
                                return
                            }
                        } else if text.isEmpty || !JavaCompat.isHexadecimal(text.replacingOccurrences(of: " ", with: "")) {
                            onAlert?("Invalid value for \(input.text): '\(text)' (hex expected)")
                            return
                        }
                    }
                    ordered.append((input.text, text))
                }
            }
            do {
                let frame = try ecu.setRequestValues(send.request, ordered: ordered)
                commands.append((send.delay, JavaCompat.bytesToHex(frame)))
            } catch {
                onAlert?("Failed to compute frame: \(error)")
                return
            }
        }
        for c in commands {
            if c.delay > 0 { sendDelay(c.delay) }
            log("Computed frame : \(c.frame)")
            sendCmd(c.frame)
        }
    }

    // MARK: - DTC

    public func readDTC() {
        stopAutoReload()
        guard let req = ecu.request("ReadDTCInformation.ReportDTC") ?? ecu.request("ReadDTC") else {
            onAlert?("No READ_DTC request in this file")
            return
        }
        currentDtcRequestName = req.name
        currentDtcRequestBytes = req.sentBytes
        sendCmd(ecu.defaultSDS)
        sendCmd(currentDtcRequestBytes)
    }

    public var clearDTCCommand: String {
        (ecu.request("ClearDiagnosticInformation.All") ?? ecu.request("ClearDTC")
            ?? ecu.request("Clear Diagnostic Information"))?.sentBytes ?? "14FF00"
    }

    /// Call after the user confirmed "Clear all DTCs?".
    public func clearDTC() {
        stopAutoReload()
        sendCmd("AT ST FF")
        sendCmd(ecu.defaultSDS)
        sendCmd(clearDTCCommand)
        sendCmd("AT ST 00")
    }

    private func decodeDTC(_ response: String) {
        let dtcs = ecu.decodeDTC(request: currentDtcRequestName, response: response)
        if dtcs.isEmpty {
            onAlert?("No DTC stored")
        } else {
            onDTCReport?(dtcs)
        }
    }

    // MARK: - Auto reload & settings

    public func setAutoReload(_ on: Bool) {
        autoReload = on
        if on { updateDisplays() }
        onChange?()
    }

    public func stopAutoReload() {
        autoReload = false
        onChange?()
    }

    public func applySettings(canTimeout: Int, softFlowControl: Bool, sdsName: String?) {
        self.canTimeout = canTimeout
        self.softFlowControl = softFlowControl
        session.setSoftFlowControl(softFlowControl)
        if let sdsName {
            ecu.setDefaultSDS(sdsName)
            log("Default diag session switched to \(ecu.defaultSDS)")
        }
        if isConnected { session.setTimeOut(canTimeout) }
    }

    private func setElmWorking(queueEmpty: Bool) {
        guard currentScreen != nil else { return }
        busy = !queueEmpty
        if queueEmpty && autoReload { updateDisplays() }
    }

    // MARK: - Replies (handleElmResult)

    private func handleElmResult(request requestCode: String, reply replyCode: String) {
        if replyCode.isEmpty {
            log("No ELM response (\(requestCode))")
            return
        }
        if requestCode.uppercased().hasPrefix("AT") || requestCode.uppercased().hasPrefix("ST") { return }

        if requestCode.hasPrefix("14") && replyCode.hasPrefix("54") {
            log("DTC cleared")
            return
        }

        if replyCode.count >= 6 && replyCode.hasPrefix("7F") {
            let resultCode = String(replyCode.prefix(6)).uppercased()
            let nrc = JavaCompat.substringClamped(resultCode, 4, 6)
            if let text = ElmSession.ecuErrorCode(nrc) {
                log("Negative response : \(text) (\(resultCode))")
            } else {
                log("Negative response : \(resultCode)")
            }
            return
        }
        log("ELM response : \(replyCode) to request \(requestCode)")

        if replyCode.hasPrefix("ERROR") {
            log("Bad response : \(replyCode) to request '\(requestCode)'")
            return
        }
        if !currentDtcRequestBytes.isEmpty && requestCode == currentDtcRequestBytes {
            decodeDTC(replyCode)
            currentDtcRequestBytes = ""
            return
        }
        updateScreen(request: requestCode, response: replyCode)
    }
}
