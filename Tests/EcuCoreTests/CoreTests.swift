import XCTest
@testable import EcuCore

final class CoreTests: XCTestCase {

    var resources: URL { OracleTests.resources }
    var projectsURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/Resources/projects.json")
    }

    // MARK: Java helpers (asserts from the original ecuUnitTest.java)

    func testJavaHelpers() throws {
        XCTAssertEqual(Ecu.hex8ToSigned(125), 125)
        XCTAssertEqual(Ecu.hex8ToSigned(254), -2)
        XCTAssertEqual(Ecu.hex16ToSigned(63000), -2536)
        XCTAssertEqual(Ecu.hex16ToSigned(6000), 6000)
        XCTAssertEqual(JavaCompat.padLeft("FFFF", 8, "0"), "0000FFFF")
        XCTAssertEqual(try JavaCompat.hexStringToBytes("00FF0A"), [0x00, 0xFF, 0x0A])
        XCTAssertEqual(JavaCompat.padLeft(JavaCompat.toBinaryString(1), 8, "0"), "00000001")
        XCTAssertEqual(JavaCompat.padLeft(JavaCompat.toBinaryString(254), 8, "0"), "11111110")
        XCTAssertEqual(try JavaCompat.intValueOfHex("FF"), 255)
        XCTAssertEqual(try JavaCompat.binToHex("11111110"), "fe")
        XCTAssertEqual(try JavaCompat.hexToBin("0F"), "1111")
        XCTAssertEqual(JavaCompat.split("a\nb\n\n", "\n"), ["a", "b"])
        XCTAssertEqual(JavaCompat.split("\na", "\n"), ["", "a"])
        XCTAssertEqual(JavaCompat.split("abc", "\n"), ["abc"])
        XCTAssertEqual(JavaCompat.fmt(12.0), "12")
        XCTAssertEqual(JavaCompat.fmt(0.125), "0.13")
        XCTAssertEqual(JavaCompat.formatFixed(-0.001, fractionDigits: 2), "-0.00")
        XCTAssertEqual(try JavaCompat.parseFloat("1.5f"), 1.5)
        XCTAssertThrowsError(try JavaCompat.parseFloat("abc"))
        XCTAssertEqual(JavaCompat.javaStringHash("hello"), 99162322)
    }

    // MARK: ISO-TP

    func testIsoTpEncode() {
        XCTAssertEqual(IsoTP.encode("2180"), ["022180"])
        XCTAssertEqual(IsoTP.encode("21 80"), ["022180"])
        XCTAssertEqual(IsoTP.encode("XYZ"), [])
        let msg = (0..<20).map { String(format: "%02X", $0) }.joined()
        let frames = IsoTP.encode(msg)
        XCTAssertEqual(frames, ["1014000102030405", "21060708090A0B0C", "220D0E0F10111213"])
        // sequence number wraps after 0xF
        let long = String(repeating: "AA", count: 6 + 7 * 17)
        let lf = IsoTP.encode(long)
        XCTAssertEqual(lf.count, 18)
        XCTAssertTrue(lf[15].hasPrefix("2F"))
        XCTAssertTrue(lf[16].hasPrefix("20"))
        XCTAssertTrue(lf[17].hasPrefix("21"))
    }

    func testIsoTpDecode() {
        XCTAssertEqual(IsoTP.decode(["0250C0"]), "50C0")
        XCTAssertEqual(IsoTP.decode([]), "ERROR : NO DATA")
        XCTAssertEqual(IsoTP.decode(["NO DATA"]), "ERROR : NON HEXA")
        XCTAssertEqual(IsoTP.decode(["1014000102030405", "21060708090A0B0C", "220D0E0F10111213"]),
                       (0..<20).map { String(format: "%02X", $0) }.joined())
        XCTAssertEqual(IsoTP.decode(["1014000102030405", "22060708090A0B0C"]), "ERROR : BAD CFC")
        XCTAssertTrue(IsoTP.decode(["1014000102030405"]).hasPrefix("ERROR"))
        // round trip with wrap-around
        let long = (0..<130).map { String(format: "%02X", $0 & 0xFF) }.joined()
        XCTAssertEqual(IsoTP.decode(IsoTP.encode(long)), long)
    }

    // MARK: ECU behaviour

    func testDtcDecode() throws {
        let ecu = try Ecu(data: Data(contentsOf: resources.appendingPathComponent("acu.json")))
        let dtcs = ecu.decodeDTC(request: "ReadDTC", response: "5706903161900161901461900b61")
        // Same result as the original Java Ecu.decodeDTC on this input
        XCTAssertEqual(dtcs.count, 4)
        XCTAssertEqual(Set(dtcs[0]), ["DTC fugitif:1 ", "DTC présent:1 ", "FirstDTC:Capteur Position Siège Avant Conducteur ",
                                 "Status DTC global:97 ", "Status DTC:Circuit ouvert "])
        XCTAssertTrue(dtcs[3].contains("FirstDTC:AirBag Latéral Thorax Avant Conducteur "))
    }

    func testNegativeScaledValueIsTwosComplement() throws {
        let json = """
        {"endian":"Big","requests":[{"name":"W","sentbytes":"3B0100",
          "sendbyte_dataitems":{"T":{"firstbyte":3}}}],
         "devices":[],"data":{"T":{"scaled":true,"signed":true,"bitscount":8,"bytescount":1}}}
        """
        let ecu = try Ecu(json: json)
        XCTAssertEqual(JavaCompat.bytesToHex(try ecu.setRequestValues("W", ["T": "-2"])), "3B01FE")
        XCTAssertEqual(JavaCompat.bytesToHex(try ecu.setRequestValues("W", ["T": "5"])), "3B0105")
    }

    func testLayout() throws {
        let text = try String(contentsOf: resources.appendingPathComponent("test.json.layout"), encoding: .utf8)
        let layout = try Layout(json: text)
        XCTAssertEqual(Set(layout.categoryNames), ["After Sales", "Manufacturer"])
        let names = layout.screenNames(category: "After Sales")
        XCTAssertEqual(names.count, 4)
        let screen = try XCTUnwrap(layout.screen(names[0]))
        XCTAssertGreaterThan(screen.width, 0)
        XCTAssertFalse(screen.labels.isEmpty || screen.displays.isEmpty)
        // labels sorted by decreasing area
        for (a, b) in zip(screen.labels, screen.labels.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.rect.area, b.rect.area)
        }
        // every display request exists in the ECU file
        let ecu = try Ecu(data: Data(contentsOf: resources.appendingPathComponent("test.json")))
        for s in layout.screens.values {
            for d in s.displays { XCTAssertNotNil(ecu.request(d.request), "missing request \(d.request)") }
        }
    }

    // MARK: ZIP + database

    func testZipAndDatabase() throws {
        let zipURL = resources.appendingPathComponent("fixture-ecu.zip")
        let zfs = try ZipFileSystem(path: zipURL.path)
        XCTAssertTrue(zfs.fileExists("db.json"))
        XCTAssertTrue(zfs.fileExists("graphics/TEST.GIF"))
        XCTAssertFalse(zfs.fileExists("graphics/"))
        XCTAssertEqual(zfs.data("graphics/TEST.GIF")?.prefix(3), Data("GIF".utf8))
        let original = try Data(contentsOf: resources.appendingPathComponent("test.json"))
        XCTAssertEqual(zfs.data("test.json"), original)

        let projects = try Data(contentsOf: projectsURL)
        let db = try EcuDatabase(projectsJSON: projects)
        XCTAssertTrue(db.models.contains("All"))
        try db.loadDatabase(zipPath: zipURL.path)
        XCTAssertTrue(db.isLoaded)
        XCTAssertEqual(db.ecuInfos(address: 0x1C).count, 1)
        let functions = db.ecuFunctions(project: "")
        XCTAssertFalse(functions.isEmpty)
        let ecuJson = try XCTUnwrap(db.zipString("test.json"))
        XCTAssertNoThrow(try Ecu(json: ecuJson))
        XCTAssertNotNil(db.zipString("test.json.layout"))

        // Identification (DDT4All semantics): exact prefix match, else closest version
        let exact = db.identify(address: 0x1C, diagVersion: "4", supplier: "ABC", soft: "0102", version: "0310", protocolFamily: "CAN")
        XCTAssertEqual(exact.first?.exact, true)
        let approx = db.identify(address: 0x1C, diagVersion: "5", supplier: "ABC", soft: "0102", version: "0305", protocolFamily: "CAN")
        XCTAssertEqual(approx.count, 1)
        XCTAssertEqual(approx.first?.exact, false)
        XCTAssertTrue(db.identify(address: 0x1C, diagVersion: "4", supplier: "XYZ", soft: "0102", version: "0300", protocolFamily: "CAN").isEmpty)
    }

    func testProjectMapsKeepExtendedAddressesSeparate() throws {
        let projects = try Data(contentsOf: projectsURL)
        let db = try EcuDatabase(projectsJSON: projects)
        db.buildMaps("ALL")
        // 0x01 (ABS) has both an 11-bit and a 29-bit address in "All"
        XCTAssertEqual(db.rxAddress(0x01), "760")
        XCTAssertEqual(db.rxExtAddress(0x01), "18DAF12D")
        XCTAssertEqual(db.rxAddress(0x01)?.count, db.txAddress(0x01)?.count)
    }

    func testOldIdentParsing() throws {
        // 61 80 + 26 bytes; diag at byte 7, supplier bytes 8..10 (ASCII), soft 16-17, version 18-19
        let resp = "6180" + "0102030405" + "0A" + "414243" + "0000000000" + "0B12" + "0F02" + "000000000000"
        let p = try XCTUnwrap(EcuDatabase.parseOldIdent(resp))
        XCTAssertEqual(p.diag, "10")
        XCTAssertEqual(p.supplier, "ABC")
        XCTAssertEqual(p.soft, "0B12")
        XCTAssertEqual(p.version, "0F02")
        XCTAssertEqual(EcuDatabase.asciiPayload("62F18A414243202020", stripPadding: true), "ABC")
    }
}

final class DiagnosticsTests: XCTestCase {
    func testScaledFlagVariantsAndDiagnostics() throws {
        let json = """
        {"endian": "Big",
         "requests": [{"name": "Read", "sentbytes": "222809", "replybytes": "622809",
                       "receivebyte_dataitems": {"A": {"firstbyte": 4}, "B": {"firstbyte": 4},
                                                 "C": {"firstbyte": 4}, "D": {"firstbyte": 4}}}],
         "data": {
           "A": {"bitscount": 16, "bytescount": 2, "scaled": true, "step": 0.25, "unit": "rpm"},
           "B": {"bitscount": 16, "bytescount": 2, "scaled": 1, "step": 0.25, "unit": "rpm"},
           "C": {"bitscount": 16, "bytescount": 2, "scaled": "1", "step": 0.25, "unit": "rpm"},
           "D": {"bitscount": 16, "bytescount": 2, "unit": "rpm"}
         }}
        """
        let ecu = try Ecu(json: json)
        let bytes = try JavaCompat.hexStringToBytes("6228090C12")
        let v = try ecu.requestValues(bytes, request: "Read", withUnits: true)
        XCTAssertEqual(v["A"], "772.50 rpm")
        XCTAssertEqual(v["B"], "772.50 rpm")
        XCTAssertEqual(v["C"], "772.50 rpm")
        XCTAssertEqual(v["D"], "0c12 rpm")
        XCTAssertTrue(ecu.dataSummary.contains("4 items, 3 scaled, 1 with a unit but not scaled"), ecu.dataSummary)
        let text = ecu.diagnostics(forData: "A", responses: ["Read": "6228090C12"])
        XCTAssertTrue(text.contains("raw value: 0c12 → 772.50 rpm"), text)
        XCTAssertTrue(text.contains("scaled true"), text)
    }
}
