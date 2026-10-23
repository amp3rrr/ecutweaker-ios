import XCTest
@testable import EcuCore

/// End-to-end tests of the screen and scan logic against the ELM327 simulator.
final class ControllerTests: XCTestCase {
    var resources: URL { OracleTests.resources }
    var projectsURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/Resources/projects.json")
    }

    private let cbq = DispatchQueue(label: "controller.callbacks")

    private func waitFor(timeout: TimeInterval = 8, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cbq.sync(execute: cond) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("condition not met in time")
    }

    /// ECU simulator answering every request of an ECU file with its sample `replybytes`
    /// (or a positive response padded with zeros).
    private func mock(for ecu: Ecu) -> MockElm {
        let m = MockElm()
        for req in ecu.requests.values where !req.sentBytes.isEmpty {
            let sent = req.sentBytes.replacingOccurrences(of: " ", with: "").uppercased()
            var reply = req.replyBytes.replacingOccurrences(of: " ", with: "").uppercased()
            if reply.isEmpty || !JavaCompat.isHexadecimal(reply) || reply.count % 2 == 1 {
                let sid = (Int(String(sent.prefix(2)), radix: 16) ?? 0) + 0x40
                reply = String(format: "%02X", sid & 0xFF) + String(sent.dropFirst(2))
            }
            let minLen = max(req.minBytes, 2) * 2
            while reply.count < minLen { reply += "00" }
            m.ecu[sent] = reply
        }
        m.ecu["10C0"] = "50C0"
        return m
    }

    func testScreenControllerDisplaysButtonsAndAutoReload() throws {
        let json = try String(contentsOf: resources.appendingPathComponent("test.json"), encoding: .utf8)
        let layoutJSON = try String(contentsOf: resources.appendingPathComponent("test.json.layout"), encoding: .utf8)
        let session = ElmSession(callbackQueue: cbq)
        session.idleTimeout = 0.5
        let ctrl = try ScreenController(ecuJSON: json, layoutJSON: layoutJSON, href: "test.json", session: session, zip: nil)
        let elm = mock(for: ctrl.ecu)
        var logs = [String]()
        var alerts = [String]()
        ctrl.onLog = { logs.append($0) }
        ctrl.onAlert = { alerts.append($0) }
        cbq.sync { session.changeHandler { ctrl.handle($0) } }
        session.connect(link: elm)
        waitFor { session.isConnected }

        // Screen with displays: values must replace "---"
        let screenName = "Actual Timings"
        cbq.sync { ctrl.drawScreen(screenName) }
        waitFor { !ctrl.displayValues.isEmpty && !ctrl.displayValues.values.contains("---") }
        XCTAssertTrue(elm.log.contains("AT SH 74B"), "bus initialised from the ECU file: \(elm.log.prefix(40)) logs: \(logs.prefix(20)) values: \(ctrl.displayValues)")
        XCTAssertTrue(elm.log.contains("02" + ctrl.ecu.defaultSDS), "SDS frame sent")

        // Screen with inputs and buttons: press every button, frames must reach the ELM
        let manual = "Manual Control"
        cbq.sync { ctrl.drawScreen(manual) }
        let screen = try XCTUnwrap(ctrl.layout.screen(manual))
        waitFor { !ctrl.busy && session.queueLength == 0 }
        let before = elm.log.count
        for b in screen.buttons {
            cbq.sync { ctrl.executeButton(b.uniqueName) }
        }
        waitFor { session.queueLength == 0 && elm.log.count > before }
        XCTAssertTrue(alerts.isEmpty, "alerts: \(alerts)")
        XCTAssertTrue(logs.contains { $0.hasPrefix("Computed frame") })

        // Auto reload keeps sending while enabled
        cbq.sync { ctrl.drawScreen(screenName); ctrl.setAutoReload(true) }
        let c0 = elm.log.count
        waitFor { elm.log.count > c0 + 20 }
        cbq.sync { ctrl.stopAutoReload() }
        session.disconnect()
    }

    func testInvalidInputIsRejected() throws {
        let json = try String(contentsOf: resources.appendingPathComponent("test.json"), encoding: .utf8)
        let layoutJSON = try String(contentsOf: resources.appendingPathComponent("test.json.layout"), encoding: .utf8)
        let session = ElmSession(callbackQueue: cbq)
        let ctrl = try ScreenController(ecuJSON: json, layoutJSON: layoutJSON, href: "test.json", session: session, zip: nil)
        var alerts = [String]()
        ctrl.onAlert = { alerts.append($0) }
        // find a screen/button whose request takes a free-text (non list) input
        for (name, screen) in ctrl.layout.screens {
            for input in screen.inputs where !ctrl.isPicker(input) {
                guard let button = screen.buttons.first(where: { $0.sendData.contains { $0.request == input.request } }),
                      let d = ctrl.ecu.dataItem(input.text), !d.bytesASCII else { continue }
                ctrl.drawScreen(name)
                ctrl.inputValues[input.text] = "xyz!"
                ctrl.executeButton(button.uniqueName)
                XCTAssertFalse(alerts.isEmpty, "invalid input on \(name)/\(input.text) must be refused")
                return
            }
        }
    }

    func testDTCReadAndClear() throws {
        let json = try String(contentsOf: resources.appendingPathComponent("acu.json"), encoding: .utf8)
        let session = ElmSession(callbackQueue: cbq)
        session.idleTimeout = 0.5
        let ctrl = try ScreenController(ecuJSON: json, layoutJSON: nil, href: "acu.json", session: session, zip: nil)
        let elm = mock(for: ctrl.ecu)
        let dtcReq = try XCTUnwrap(ctrl.ecu.request("ReadDTC"))
        elm.ecu[dtcReq.sentBytes] = "5706903161900161901461900b61".uppercased()
        elm.ecu[ctrl.clearDTCCommand] = "54"
        var report: [[String]]?
        var logs = [String]()
        ctrl.onDTCReport = { report = $0 }
        ctrl.onLog = { logs.append($0) }
        cbq.sync { session.changeHandler { ctrl.handle($0) } }
        session.connect(link: elm)
        waitFor { session.isConnected }
        waitFor { session.queueLength == 0 && elm.log.contains("AT SH 752") }
        cbq.sync { ctrl.readDTC() }
        waitFor { report != nil }
        XCTAssertEqual(report?.count, 4)
        cbq.sync { ctrl.clearDTC() }
        waitFor { logs.contains("DTC cleared") }
        session.disconnect()
    }

    func testScanIdentifiesEcu() throws {
        let db = try EcuDatabase(projectsJSON: Data(contentsOf: projectsURL))
        try db.loadDatabase(zipPath: resources.appendingPathComponent("fixture-ecu.zip").path)
        let session = ElmSession(callbackQueue: cbq)
        session.idleTimeout = 0.5
        let scan = ScanController(database: db, session: session, address: 0x1C)
        let elm = MockElm()
        // 61 80 | 5 bytes | diag=04 | "ABC" | 5 bytes | soft 0102 | version 0310 | 6 bytes
        elm.ecu["10C0"] = "50C0"
        elm.ecu["2180"] = "6180" + "0000000000" + "04" + "414243" + "0000000000" + "0102" + "0310" + "000000000000"
        cbq.sync { session.changeHandler { scan.handle($0) } }
        session.connect(link: elm)
        waitFor { session.isConnected }
        cbq.sync { scan.scanCAN() }
        waitFor { !scan.results.isEmpty }
        XCTAssertEqual(scan.results.first?.info.ecuName, "Pilotage capote TEST")
        XCTAssertEqual(scan.results.first?.exact, true)
        XCTAssertEqual(scan.fields.supplier, "ABC")
        XCTAssertTrue(elm.log.contains("AT CRA 76B"))
        session.disconnect()
    }

    func testScanUdsIdentification() throws {
        let db = try EcuDatabase(projectsJSON: Data(contentsOf: projectsURL))
        try db.loadDatabase(zipPath: resources.appendingPathComponent("fixture-ecu.zip").path)
        let session = ElmSession(callbackQueue: cbq)
        session.idleTimeout = 0.5
        let scan = ScanController(database: db, session: session, address: 0x2C)
        let elm = MockElm()
        func ascii(_ s: String) -> String { s.utf8.map { String(format: "%02X", $0) }.joined() }
        elm.ecu["1003"] = "5003"
        elm.ecu["22F1A0"] = "62F1A00C"
        elm.ecu["22F18A"] = "62F18A" + ascii("AUTOLIV   ")
        elm.ecu["22F194"] = "62F194" + ascii("SW1") + "FFFF"
        elm.ecu["22F195"] = "62F195" + ascii("V1")
        cbq.sync { session.changeHandler { scan.handle($0) } }
        session.connect(link: elm)
        waitFor { session.isConnected }
        cbq.sync { scan.scanCAN() }
        waitFor { !scan.results.isEmpty }
        XCTAssertEqual(scan.results.first?.info.ecuName, "Airbag ACU")
        XCTAssertEqual(scan.results.first?.exact, true)
        session.disconnect()
    }
}
