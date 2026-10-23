import Foundation

/// Port of org.quark.dr.ecu.Ecu — an ECU definition (requests + data items)
/// loaded from a DDT4All-style JSON file, with frame decoding/encoding.
public final class Ecu {
    public private(set) var globalEndian: String = ""
    public private(set) var requests: [String: EcuRequest] = [:]
    public private(set) var data: [String: EcuData] = [:]
    public private(set) var sdsRequests: [String: String] = [:]
    public private(set) var protocolName: String = ""
    public private(set) var functionalAddress: String = ""
    public private(set) var name: String = ""
    public private(set) var txId: String = ""
    public private(set) var rxId: String = ""
    public private(set) var fastInit: Bool = false
    public private(set) var defaultSDS: String = "10C0"

    public convenience init(json: String) throws {
        try self.init(object: J.parseObject(json))
    }

    public convenience init(data: Data) throws {
        guard let obj = try J.parse(data) as? [String: Any] else {
            throw EcuError.database("ECU JSON root is not an object")
        }
        try self.init(object: obj)
    }

    public init(object ecudef: [String: Any]) throws {
        if let e = J.str(ecudef["endian"]) { globalEndian = e }
        if let n = J.str(ecudef["ecuname"]) { name = n }

        if let obd = J.obj(ecudef["obd"]) {
            protocolName = J.str(obd["protocol"]) ?? ""
            if protocolName == "CAN" {
                txId = J.str(obd["send_id"]) ?? ""
                rxId = J.str(obd["recv_id"]) ?? ""
            }
            if protocolName == "KWP2000" {
                fastInit = J.bool(obd["fastinit"]) ?? false
            }
            if let fa = J.str(obd["funcaddr"]) { functionalAddress = fa }
        }

        for case let reqObj as [String: Any] in J.arr(ecudef["requests"]) ?? [] {
            let req = EcuRequest(json: reqObj)
            requests[req.name] = req
        }

        for (key, value) in J.obj(ecudef["data"]) ?? [:] {
            guard let dataObj = J.obj(value) else { continue }
            data[key] = EcuData(json: dataObj, name: key)
        }

        gatherSdsRequests()
    }

    // MARK: - StartDiagnosticSession discovery (Ecu.init tail in Java)

    private func gatherSdsRequests() {
        // Java iterated a HashMap; we iterate in sorted order to be deterministic.
        for requestName in requests.keys.sorted() {
            let upper = requestName.uppercased()
            guard upper.contains("START"), upper.contains("DIAG"), upper.contains("SESSION"),
                  let request = requests[requestName] else { continue }

            if upper.contains("EXTENDED") && !request.sentBytes.isEmpty {
                defaultSDS = request.sentBytes
            }
            for sdsItemName in request.sendDataItems.keys.sorted() {
                guard let item = request.sendDataItems[sdsItemName] else { continue }
                let upperItem = sdsItemName.uppercased()
                guard upperItem.contains("SESSION"), upperItem.contains("NAME"),
                      let sdsData = data[sdsItemName] else { continue }
                for listItemName in sdsData.items.keys.sorted() {
                    guard let stream = try? setRequestValues(requestName, [item.name: listItemName]) else { continue }
                    let hex = JavaCompat.bytesToHex(stream).uppercased()
                    sdsRequests[listItemName] = hex
                    // NB: original tests the *data item* name, not the list entry name.
                    if item.name.uppercased().contains("EXTENDED") {
                        defaultSDS = hex
                    }
                }
            }
            if request.sendDataItems.isEmpty {
                sdsRequests[requestName] = request.sentBytes
            }
        }
    }

    public func setDefaultSDS(_ sdsName: String) {
        if let v = sdsRequests[sdsName] { defaultSDS = v }
    }

    public func request(_ name: String) -> EcuRequest? { requests[name] }
    public func dataItem(_ name: String) -> EcuData? { data[name] }

    // MARK: - Decoding

    public func requestData(_ bytes: [UInt8], request requestName: String, data dataName: String) throws -> String {
        guard let req = requests[requestName] else { throw EcuError.requestNotFound(requestName) }
        guard let item = req.receiveDataItems[dataName] else { throw EcuError.dataItemNotFound(dataName) }
        guard let d = data[dataName] else { throw EcuError.dataNotFound(dataName) }
        return try d.displayValue(bytes, item, globalEndian: globalEndian)
    }

    /// Ecu.getRequestValues — all received data items of a request.
    public func requestValues(_ bytes: [UInt8], request requestName: String, withUnits: Bool) throws -> [String: String] {
        guard let req = requests[requestName] else { return [:] }
        var out = [String: String]()
        for (key, item) in req.receiveDataItems {
            guard let d = data[key] else { throw EcuError.dataNotFound(key) }
            out[key] = withUnits
                ? try d.displayValueWithUnit(bytes, item, globalEndian: globalEndian)
                : try d.displayValue(bytes, item, globalEndian: globalEndian)
        }
        return out
    }

    /// Ecu.getRequestValuesWithUnit — (value, unit) pairs.
    public func requestValuesWithUnit(_ bytes: [UInt8], request requestName: String) throws -> [String: (value: String, unit: String)] {
        guard let req = requests[requestName] else { return [:] }
        var out = [String: (value: String, unit: String)]()
        for (key, item) in req.receiveDataItems {
            guard let d = data[key] else { throw EcuError.dataNotFound(key) }
            out[key] = (try d.displayValue(bytes, item, globalEndian: globalEndian), d.unit)
        }
        return out
    }

    // MARK: - Encoding

    /// Ecu.setRequestValues — builds a frame from `sentbytes` + user values.
    public func setRequestValues(_ requestName: String, _ values: [String: String]) throws -> [UInt8] {
        try setRequestValues(requestName, ordered: values.keys.sorted().map { ($0, values[$0]!) })
    }

    /// Same, with values given in the order they were inserted into the Java HashMap.
    /// Items are applied in Java HashMap iteration order, so overlapping data items
    /// (e.g. "InjectorCode.hexa.All" vs ".1"…".4") resolve exactly like on Android.
    public func setRequestValues(_ requestName: String, ordered pairs: [(String, String)]) throws -> [UInt8] {
        guard let req = requests[requestName] else { throw EcuError.requestNotFound(requestName) }
        var frame = try JavaCompat.hexStringToBytes(req.sentBytes)
        var values = [String: String]()
        var insertion = [String]()
        for (k, v) in pairs {
            if values[k] == nil { insertion.append(k) }
            values[k] = v
        }
        for key in JavaCompat.javaHashMapOrder(insertion) {
            let value = values[key]!
            guard let d = data[key] else { throw EcuError.dataNotFound(key) }
            guard let item = req.sendDataItems[key] else { throw EcuError.dataItemNotFound(key) }
            if !d.items.isEmpty, let code = d.items[value] {
                // Integer.toHexString semantics (two's complement for negatives)
                let hex = String(UInt32(bitPattern: Int32(truncatingIfNeeded: code)), radix: 16)
                try d.setValue(hex, into: &frame, item: item, globalEndian: globalEndian)
                continue
            }
            try d.setValue(value, into: &frame, item: item, globalEndian: globalEndian)
        }
        return frame
    }

    // MARK: - DTC

    /// Ecu.decodeDTC — returns one list of "name:value" lines per DTC.
    public func decodeDTC(request dtcRequestName: String, response: String) -> [[String]] {
        var dtcList = [[String]]()
        guard let dtcRequest = requests[dtcRequestName],
              var bytes = try? JavaCompat.hexStringToBytes(response),
              bytes.count > 1 else { return dtcList }
        let shift = dtcRequest.shiftBytesCount
        let numDtc = Int(bytes[1])
        for _ in 0..<numDtc {
            if bytes.count < shift { break }
            guard let current = try? requestValues(bytes, request: dtcRequestName, withUnits: true) else { continue }
            let lines = current.keys.sorted().filter { $0 != "NDTC" }.map { "\($0):\(current[$0]!)" }
            dtcList.append(lines)
            if bytes.count >= shift {
                bytes = Array(bytes[shift...])
            } else {
                break
            }
        }
        return dtcList
    }

    // MARK: - Static helpers kept from the Java API

    public static func hex8ToSigned(_ val: Int32) -> Int32 { -(val & 0x80) | (val & 0x7f) }
    public static func hex16ToSigned(_ val: Int32) -> Int32 { -(val & 0x8000) | (val & 0x7fff) }
}

// MARK: - Data items

public struct EcuDataItem {
    public var firstByte: Int = 0
    public var bitOffset: Int = 0
    public var ref: Bool = false
    public var endian: String = ""
    public let name: String

    init(json: [String: Any], name: String) {
        self.name = name
        if let v = J.int(json["firstbyte"]) { firstByte = v }
        if let v = J.int(json["bitoffset"]) { bitOffset = v }
        if let v = J.bool(json["ref"]) { ref = v }
        if let v = J.str(json["endian"]) { endian = v }
    }
}

public final class EcuData {
    public let name: String
    public var bitsCount = 8
    public var scaled = false
    public var signed = false
    public var isByte = false
    public var binary = false
    public var bytesCount = 1
    public var bytesASCII = false
    public var step: Float = 1.0
    public var offset: Float = 0.0
    public var divideBy: Float = 1.0
    public var format = ""
    public var lists: [Int: String] = [:]
    public var items: [String: Int] = [:]
    public var descriptionText: String?
    public var unit = ""
    public var comment = ""
    /// The JSON object this definition was read from (for diagnostics).
    public let raw: [String: Any]

    init(json: [String: Any], name: String) {
        self.name = name
        self.raw = json
        if let v = J.int(json["bitscount"]) { bitsCount = v }
        if let v = J.bool(json["scaled"]) { scaled = v }
        if let v = J.bool(json["byte"]) { isByte = v }
        if let v = J.bool(json["signed"]) { signed = v }
        if let v = J.bool(json["binary"]) { binary = v }
        if let v = J.bool(json["bytesascii"]) { bytesASCII = v }
        if let v = J.int(json["bytescount"]) { bytesCount = v }
        if let v = J.double(json["step"]) { step = Float(v) }
        if let v = J.double(json["offset"]) { offset = Float(v) }
        if let v = J.double(json["divideby"]) { divideBy = Float(v) }
        if let v = J.str(json["format"]) { format = v }
        if let v = J.str(json["description"]) { descriptionText = v }
        if let v = J.str(json["unit"]) { unit = v }
        if let v = J.str(json["comment"]) { comment = v }
        if let list = J.obj(json["lists"]) {
            for (key, value) in list {
                guard let k = JavaCompat.parseIntOrNil(key), let s = J.str(value) else { continue }
                lists[k] = s
                items[s] = k
            }
        }
    }

    private static func isLittleEndian(_ item: EcuDataItem, globalEndian: String) -> Bool {
        var little = globalEndian == "Little"
        if item.endian == "Little" { little = true }
        if item.endian == "Big" { little = false }
        return little
    }

    private static func ceilDiv8(_ v: Int) -> Int { Int((Float(v) / 8.0).rounded(.up)) }

    /// EcuData.getHexValue
    public func hexValue(_ resp: [UInt8], _ item: EcuDataItem, globalEndian: String) throws -> String {
        let startBit = item.bitOffset
        let little = Self.isLittleEndian(item, globalEndian: globalEndian)
        let dataBytesLen = Self.ceilDiv8(bitsCount)
        let requiredBytes = Self.ceilDiv8(bitsCount + startBit)
        let sb = item.firstByte - 1
        guard sb >= 0, sb + dataBytesLen <= resp.count, sb + requiredBytes <= resp.count else {
            throw EcuError.responseTooShort
        }

        var bin = ""
        bin.reserveCapacity(requiredBytes * 8)
        let slice: [Character]
        if little {
            for i in (0..<requiredBytes).reversed() { bin += JavaCompat.byteToBinary(resp[i + sb]) }
            let bitLength = requiredBytes * 8
            let chars = Array(bin)
            let from = bitLength - startBit - bitsCount
            let to = bitLength - startBit
            guard from >= 0, to <= chars.count, from <= to else { throw EcuError.responseTooShort }
            slice = Array(chars[from..<to])
        } else {
            for i in 0..<requiredBytes { bin += JavaCompat.byteToBinary(resp[i + sb]) }
            let chars = Array(bin)
            guard startBit >= 0, startBit + bitsCount <= chars.count else { throw EcuError.responseTooShort }
            slice = Array(chars[startBit..<(startBit + bitsCount)])
        }
        let hex = try JavaCompat.binToHex(String(slice))
        return JavaCompat.padLeft(hex, dataBytesLen * 2, "0")
    }

    public func displayValueWithUnit(_ resp: [UInt8], _ item: EcuDataItem, globalEndian: String) throws -> String {
        try displayValue(resp, item, globalEndian: globalEndian) + " " + unit
    }

    /// EcuData.getDisplayValue
    public func displayValue(_ resp: [UInt8], _ item: EcuDataItem, globalEndian: String) throws -> String {
        let hexval = try hexValue(resp, item, globalEndian: globalEndian)
        if bytesASCII {
            let b = try JavaCompat.hexStringToBytes(hexval)
            return String(decoding: b, as: UTF8.self)
        }

        var val = try JavaCompat.intValueOfHex(hexval)
        if signed {
            if bytesCount == 1 {
                val = Ecu.hex8ToSigned(val)
            } else if bytesCount == 2 {
                val = Ecu.hex16ToSigned(val)
            }
        }

        if !scaled {
            if let s = lists[Int(val)] { return s }
            return hexval
        }

        if divideBy == 0 { throw EcuError.divisionByZero }
        let res: Float = (Float(val) * step + offset) / divideBy

        if !format.isEmpty, let df = JavaDecimalFormat(pattern: format) {
            return df.format(Double(res))
        }
        return JavaCompat.fmt(Double(res))
    }

    /// EcuData.setValue — writes `value` into `frame` at the item's position.
    /// The original forces big-endian here ("Not sure it's required to format
    /// little endian values"); kept identical.
    public func setValue(_ value: String, into frame: inout [UInt8], item: EcuDataItem, globalEndian: String) throws {
        let startByte = item.firstByte - 1
        let startBit = item.bitOffset

        var finalBin: String
        if bytesASCII {
            var units = Array(value.utf16)
            if bytesCount > units.count {
                units = Array(repeating: UInt16(0x20), count: bytesCount - units.count) + units
            }
            if bytesCount < units.count { units = Array(units[0..<bytesCount]) }
            let str = String(decoding: units, as: UTF16.self)
            finalBin = try JavaCompat.hexToBin(JavaCompat.stringToHex(str))
        } else if scaled {
            let cleaned = value.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
            var f = try JavaCompat.parseFloat(cleaned)
            f = ((f * divideBy) - offset) / step
            let intval = JavaCompat.f2i(f)
            if intval < 0 && bitsCount > 0 && bitsCount < 32 {
                // Fix: the original kept the *top* bits of the 32-bit two's complement
                // string for negative numbers; write the low `bitsCount` bits instead.
                let mask = (UInt32(1) << UInt32(bitsCount)) - 1
                finalBin = JavaCompat.padLeft(String(UInt32(bitPattern: intval) & mask, radix: 2), bitsCount, "0")
            } else {
                finalBin = JavaCompat.padLeft(JavaCompat.toBinaryString(intval), bitsCount, "0")
            }
        } else {
            finalBin = try JavaCompat.hexToBin(value.replacingOccurrences(of: " ", with: ""))
        }

        finalBin = JavaCompat.padLeft(finalBin, bitsCount, "0")
        let numReqBytes = Self.ceilDiv8(bitsCount + startBit)

        guard startByte >= 0, startByte <= frame.count else { throw EcuError.responseTooShort }
        var requestBin = ""
        for i in 0..<numReqBytes {
            let idx = startByte + i
            requestBin += JavaCompat.byteToBinary(idx < frame.count ? frame[idx] : 0)
        }

        var binaryRequest = Array(requestBin)
        let binaryValue = Array(finalBin)
        guard bitsCount + startBit <= binaryRequest.count, binaryValue.count >= bitsCount else {
            throw EcuError.invalidValue("bit layout of \(name)")
        }
        for i in 0..<bitsCount { binaryRequest[i + startBit] = binaryValue[i] }

        let valueHex = try JavaCompat.binToHex(String(binaryRequest))
        let str16 = Array(JavaCompat.padLeft(valueHex, bytesCount * 2, "0"))
        guard startByte + bytesCount <= frame.count else { throw EcuError.responseTooShort }
        for i in 0..<bytesCount {
            let hi = JavaCompat.hexDigit(str16[i * 2])
            let lo = JavaCompat.hexDigit(str16[i * 2 + 1])
            frame[i + startByte] = UInt8(truncatingIfNeeded: (hi << 4) + lo)
        }
    }
}

// MARK: - Requests

public struct SDSFlags {
    public var nosds = true
    public var plant = true
    public var aftersales = true
    public var engineering = true
    public var supplier = true
}

public struct EcuRequest {
    public var name: String = ""
    public var minBytes = 0
    public var shiftBytesCount = 0
    public var replyBytes = ""
    public var sentBytes = ""
    public var manualSend = false
    public var receiveDataItems: [String: EcuDataItem] = [:]
    public var sendDataItems: [String: EcuDataItem] = [:]
    public var sds = SDSFlags()

    init(json: [String: Any]) {
        name = J.str(json["name"]) ?? ""
        if let v = J.int(json["minbytes"]) { minBytes = v }
        if let v = J.int(json["shiftbytescount"]) { shiftBytesCount = v }
        if let v = J.str(json["replybytes"]) { replyBytes = v }
        if let v = J.bool(json["manualsend"]) { manualSend = v }
        if let v = J.str(json["sentbytes"]) { sentBytes = v }
        for case let s as String in J.arr(json["deny_sds"]) ?? [] {
            switch s {
            case "nosds": sds.nosds = false
            case "plant": sds.plant = false
            case "aftersales": sds.aftersales = false
            case "engineering": sds.engineering = false
            case "supplier": sds.supplier = false
            default: break
            }
        }
        for (key, value) in J.obj(json["sendbyte_dataitems"]) ?? [:] {
            guard let o = J.obj(value) else { continue }
            sendDataItems[key] = EcuDataItem(json: o, name: key)
        }
        for (key, value) in J.obj(json["receivebyte_dataitems"]) ?? [:] {
            guard let o = J.obj(value) else { continue }
            receiveDataItems[key] = EcuDataItem(json: o, name: key)
        }
    }
}

// MARK: - Diagnostics

extension Ecu {
    /// One-line health summary of the data definitions, written to the log when a screen opens.
    public var dataSummary: String {
        let all = Array(data.values)
        let scaled = all.filter(\.scaled).count
        let unitOnly = all.filter { !$0.scaled && !$0.unit.isEmpty }.count
        var s = "ECU data: \(all.count) items, \(scaled) scaled"
        if unitOnly > 0 { s += ", \(unitOnly) with a unit but not scaled" }
        if let raw = all.lazy.compactMap({ $0.raw["scaled"] }).first {
            s += " (\"scaled\" is stored as \(raw) : \(type(of: raw)))"
        }
        return s
    }

    /// Definition of a data item and how it decodes `responses` (request name → reply hex).
    public func diagnostics(forData name: String, responses: [String: String] = [:]) -> String {
        guard let d = data[name] else { return "Data \"\(name)\" is not defined in this ECU file." }
        var out = ["Data: \(name)"]
        for (reqName, req) in requests.sorted(by: { $0.key < $1.key }) {
            guard let item = req.receiveDataItems[name] else { continue }
            out.append("")
            out.append("Request: \(reqName)")
            out.append("  sent \(req.sentBytes), reply \(req.replyBytes), minbytes \(req.minBytes)")
            out.append("  firstbyte \(item.firstByte), bitoffset \(item.bitOffset), endian '\(item.endian)'")
            if let resp = responses[reqName] {
                out.append("  last response: \(resp)")
                if let bytes = try? JavaCompat.hexStringToBytes(resp) {
                    let hex = (try? d.hexValue(bytes, item, globalEndian: globalEndian)) ?? "<error>"
                    let shown = (try? d.displayValue(bytes, item, globalEndian: globalEndian)) ?? "<error>"
                    out.append("  raw value: \(hex) → \(shown) \(d.unit)")
                }
            } else {
                out.append("  no response yet")
            }
        }
        out.append("")
        out.append("Parsed definition:")
        out.append("  scaled \(d.scaled), signed \(d.signed), ascii \(d.bytesASCII)")
        out.append("  bitscount \(d.bitsCount), bytescount \(d.bytesCount)")
        out.append("  step \(d.step), offset \(d.offset), divideby \(d.divideBy)")
        out.append("  format '\(d.format)', unit '\(d.unit)', list entries \(d.lists.count)")
        out.append("  ECU endian '\(globalEndian)'")
        out.append("")
        out.append("JSON in the ECU file:")
        for (k, v) in d.raw.sorted(by: { $0.key < $1.key }) {
            if k == "lists" {
                out.append("  lists: \(J.obj(v)?.count ?? 0) entries")
            } else {
                out.append("  \(k): \(v)  [\(type(of: v))]")
            }
        }
        return out.joined(separator: "\n")
    }
}
