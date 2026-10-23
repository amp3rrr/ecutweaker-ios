import Foundation

/// Port of org.quark.dr.ecu.EcuDatabase + ProjectData.
/// Holds the vehicle projects (bundled projects.json) and the ECU index (db.json in ecu.zip).
public final class EcuDatabase: @unchecked Sendable {

    public struct Project {
        public let name: String
        public let code: String
        public var addressing: [String: [String]] = [:]
        public var snat: [String: String] = [:]
        public var snatExt: [String: String] = [:]
        public var dnat: [String: String] = [:]
        public var dnatExt: [String: String] = [:]
    }

    public struct EcuIdent {
        public var supplierCode = ""
        public var softVersion = ""
        public var version = ""
        public var diagnosticVersion = ""
    }

    public final class EcuInfo: Identifiable {
        public var id: String { href }
        public let href: String
        public let ecuName: String
        public let protocolName: String
        public let addressId: Int
        public let projects: Set<String>
        public let idents: [EcuIdent]

        init(href: String, ecuName: String, protocolName: String, addressId: Int, projects: Set<String>, idents: [EcuIdent]) {
            self.href = href
            self.ecuName = ecuName
            self.protocolName = protocolName
            self.addressId = addressId
            self.projects = projects
            self.idents = idents
        }
    }

    public struct IdentResult {
        public let info: EcuInfo
        public let exact: Bool
    }

    public private(set) var projects: [String: Project] = [:]
    private var ecuInfo: [Int: [EcuInfo]] = [:]
    private var ecuAddressing: [Int: String] = [:]
    private var rxMap: [Int: String] = [:]
    private var txMap: [Int: String] = [:]
    private var rxExtMap: [Int: String] = [:]
    private var txExtMap: [Int: String] = [:]
    private var modelsMap: [String: String] = [:]      // code → model name
    private var addressSet: Set<Int> = []

    public private(set) var currentProjectCode = ""
    private var currentCodeRaw = "ALL"
    public private(set) var currentProjectName = ""
    public private(set) var projectSet: Set<String> = []
    public private(set) var isLoaded = false
    public private(set) var zip: ZipFileSystem?
    public private(set) var ecuFilePath: String?

    public init(projectsJSON: Data) throws {
        let parsed = try J.releasingTemporaries { () throws -> ([String: Project], [String: String]) in
            guard let root = try J.parse(projectsJSON) as? [String: Any],
                  let projectsObj = J.obj(root["projects"]) else {
                throw EcuError.database("projects.json not found or not loaded!")
            }
            var projects = [String: Project](), models = [String: String]()
            for (name, value) in projectsObj {
                guard let p = J.obj(value), let code = J.str(p["code"]) else { continue }
                var project = Project(name: name, code: code)
                for (k, v) in J.obj(p["addressing"]) ?? [:] {
                    project.addressing[k] = (J.arr(v) ?? []).compactMap { J.str($0) }
                }
                project.snat = Self.stringMap(p["snat"])
                project.snatExt = Self.stringMap(p["snat_ext"])
                project.dnat = Self.stringMap(p["dnat"])
                project.dnatExt = Self.stringMap(p["dnat_ext"])
                projects[name] = project
                models[code] = name
            }
            return (projects, models)
        }
        projects = parsed.0
        modelsMap = parsed.1
        buildMaps("ALL")
    }

    private static func stringMap(_ v: Any?) -> [String: String] {
        var out = [String: String]()
        for (k, val) in J.obj(v) ?? [:] { if let s = J.str(val) { out[k] = s } }
        return out
    }

    // MARK: - Project maps

    public func buildMaps(_ codeIn: String) {
        let code = codeIn.isEmpty ? "ALL" : codeIn
        currentCodeRaw = code
        ecuAddressing.removeAll()
        txMap.removeAll(); txExtMap.removeAll(); rxMap.removeAll(); rxExtMap.removeAll()
        for (name, p) in projects where p.code == code {
            currentProjectCode = code.uppercased()
            currentProjectName = name
            for (k, v) in p.addressing {
                guard let key = JavaCompat.parseIntOrNil(k, radix: 16), v.count > 1 else { continue }
                if isLoaded && !addressSet.contains(key) { continue }
                ecuAddressing[key] = v[1].trimmingCharacters(in: .whitespaces)
            }
            for (k, v) in p.dnat { if let key = JavaCompat.parseIntOrNil(k, radix: 16) { txMap[key] = v.trimmingCharacters(in: .whitespaces) } }
            for (k, v) in p.dnatExt { if let key = JavaCompat.parseIntOrNil(k, radix: 16) { txExtMap[key] = v.trimmingCharacters(in: .whitespaces) } }
            for (k, v) in p.snat { if let key = JavaCompat.parseIntOrNil(k, radix: 16) { rxMap[key] = v.trimmingCharacters(in: .whitespaces) } }
            // Fix: the original stored snat_ext into the 11-bit RX map, overwriting
            // 7xx receive IDs with 29-bit ones (breaking CAN scans on those ECUs).
            for (k, v) in p.snatExt { if let key = JavaCompat.parseIntOrNil(k, radix: 16) { rxExtMap[key] = v.trimmingCharacters(in: .whitespaces) } }
        }
    }

    /// Model names ("[X61] - Renault Master III", "All", …), sorted.
    public var models: [String] { modelsMap.values.sorted() }

    /// EcuDatabase.getProjectFromModel — returns the project code ("" for All) and rebuilds the maps.
    @discardableResult
    public func selectModel(_ model: String) -> String {
        var result = ""
        if model.uppercased() != "ALL" {
            result = modelsMap.first { $0.value.uppercased() == model.uppercased() }?.key ?? ""
        }
        buildMaps(result)
        return result
    }

    public func projectCode(forModel model: String) -> String? {
        modelsMap.first { $0.value == model }?.key
    }

    public func modelName(forCode code: String) -> String? { modelsMap[code] }

    // MARK: - ECU lookup

    /// EcuDatabase.getEcuByFunctionsAndType — ECU function names for a project code ("" = all).
    public func ecuFunctions(project type: String) -> [String] {
        var set = Set<String>()
        for infos in ecuInfo.values {
            for info in infos where (type.isEmpty || info.projects.contains(type)) {
                if let name = ecuAddressing[info.addressId] { set.insert(name) }
            }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// EcuDatabase.getAddressByFunction (lowest address with that name).
    public func address(forFunction name: String) -> Int? {
        ecuAddressing.keys.sorted().first { ecuAddressing[$0] == name }
    }

    public func functionName(forAddress addr: Int) -> String? { ecuAddressing[addr] }

    public func ecuInfos(address: Int) -> [EcuInfo] { ecuInfo[address] ?? [] }

    /// ECU files for an address filtered by project, sorted by name (MainActivity.ecuTypeSelected).
    public func ecuInfos(address: Int, project: String) -> [EcuInfo] {
        ecuInfos(address: address)
            .filter { project.isEmpty || $0.projects.contains(project) }
            .sorted { $0.ecuName.localizedStandardCompare($1.ecuName) == .orderedAscending }
    }

    public func rxAddress(_ id: Int) -> String? { rxMap[id] }
    public func txAddress(_ id: Int) -> String? { txMap[id] }
    public func rxExtAddress(_ id: Int) -> String? { rxExtMap[id] }
    public func txExtAddress(_ id: Int) -> String? { txExtMap[id] }

    // MARK: - Loading ecu.zip

    public func loadDatabase(zipPath: String) throws {
        guard FileManager.default.fileExists(atPath: zipPath) else {
            throw EcuError.database("Ecu file (ecu.zip) not found")
        }
        let zfs = try ZipFileSystem(path: zipPath)
        let (infos, projectSet, addresses) = try J.releasingTemporaries {
            () throws -> ([Int: [EcuInfo]], Set<String>, Set<Int>) in
            guard let dbData = zfs.data("db.json"), !dbData.isEmpty else {
                throw EcuError.database("Database (db.json) file not found")
            }
            guard let root = try? J.parse(dbData) as? [String: Any] else {
                throw EcuError.database("JSON conversion issue")
            }

            var infos = [Int: [EcuInfo]]()
            var projectSet = Set<String>()
            var addresses = Set<Int>()
            for (href, value) in root {
                guard let o = J.obj(value),
                      let addrStr = J.str(o["address"]),
                      let addr = JavaCompat.parseIntOrNil(addrStr, radix: 16) else {
                    throw EcuError.database("JSON parsing issue (\(href))")
                }
                let projects = Set((J.arr(o["projects"]) ?? []).compactMap { J.str($0)?.uppercased() })
                projectSet.formUnion(projects)
                addresses.insert(addr)
                let idents: [EcuIdent] = (J.arr(o["autoidents"]) ?? []).compactMap { J.obj($0) }.map {
                    EcuIdent(supplierCode: J.str($0["supplier_code"]) ?? "",
                             softVersion: J.str($0["soft_version"]) ?? "",
                             version: J.str($0["version"]) ?? "",
                             diagnosticVersion: J.str($0["diagnostic_version"]) ?? "")
                }
                let info = EcuInfo(href: href,
                                   ecuName: J.str(o["ecuname"]) ?? href,
                                   protocolName: J.str(o["protocol"]) ?? "",
                                   addressId: addr,
                                   projects: projects,
                                   idents: idents)
                infos[addr, default: []].append(info)
            }
            return (infos, projectSet, addresses)
        }

        ecuInfo = infos
        self.projectSet = projectSet
        addressSet = addresses
        zip = zfs
        ecuFilePath = zipPath
        isLoaded = true
        buildMaps(currentCodeRaw)
    }

    public func zipString(_ name: String) -> String? { zip?.string(name) }
    public func zipData(_ name: String) -> Data? { zip?.data(name) }

    // MARK: - Identification

    /// Matches identification data against autoidents, following DDT4All's
    /// ecu_scanner.check_ecu2 (exact prefix match, else closest version among
    /// entries with the same supplier and soft). Replaces the Java
    /// identifyOldEcu / identifyNewEcu, which had bugs that made the
    /// partial match and the UDS (22F1xx) method never return a result.
    public func identify(address: Int, diagVersion: String, supplier: String, soft: String,
                         version: String, protocolFamily: String) -> [IdentResult] {
        let candidates = ecuInfo[address] ?? []
        func family(_ p: String) -> String { p == "CAN" ? "CAN" : (p.hasPrefix("KWP") || p.hasPrefix("ISO8") ? "KWP" : p) }
        func hexInt(_ s: String) -> Int? { Int(s.trimmingCharacters(in: .whitespaces), radix: 16) }

        var approximate = [(EcuInfo, EcuIdent)]()
        for info in candidates where family(info.protocolName) == protocolFamily {
            for ident in info.idents where !ident.diagnosticVersion.isEmpty {
                let sup = ident.supplierCode.trimmingCharacters(in: .whitespaces)
                let sft = ident.softVersion.trimmingCharacters(in: .whitespaces)
                let ver = ident.version.trimmingCharacters(in: .whitespaces)
                let rSup = supplier.trimmingCharacters(in: .whitespaces)
                let rSoft = soft.trimmingCharacters(in: .whitespaces)
                let rVer = version.trimmingCharacters(in: .whitespaces)
                if let a = hexInt(ident.diagnosticVersion), let b = hexInt(diagVersion), a == b,
                   rSup.hasPrefix(sup), rSoft.hasPrefix(sft), rVer.hasPrefix(ver) {
                    return [IdentResult(info: info, exact: true)]
                }
                if sup == rSup && sft == rSoft {
                    approximate.append((info, ident))
                }
            }
        }

        guard let readVersion = hexInt(version) else {
            return approximate.first.map { [IdentResult(info: $0.0, exact: false)] } ?? []
        }
        var best: (EcuInfo, Int)?
        for (info, ident) in approximate {
            guard let v = hexInt(ident.version) else { continue }
            let delta = abs(v - readVersion)
            if best == nil || delta < best!.1 { best = (info, delta) }
        }
        return best.map { [IdentResult(info: $0.0, exact: false)] } ?? []
    }

    /// Parses a 2180 response ("6180…", spaces removed) — the "old" Renault identification.
    public static func parseOldIdent(_ response: String) -> (diag: String, supplier: String, soft: String, version: String)? {
        guard response.count > 39, response.hasPrefix("6180") else { return nil }
        let r = response
        let diagHex = JavaCompat.substringClamped(r, 14, 16)
        let supplierBytes = (try? JavaCompat.hexStringToBytes(JavaCompat.substringClamped(r, 16, 22))) ?? []
        let supplier = String(decoding: supplierBytes, as: UTF8.self)
        let soft = JavaCompat.substringClamped(r, 32, 36)
        let version = JavaCompat.substringClamped(r, 36, 40)
        let diag = Int(diagHex, radix: 16).map(String.init) ?? diagHex
        return (diag, supplier, soft, version)
    }

    /// Decodes the ASCII payload of a 62F1xx response the way DDT4All does.
    public static func asciiPayload(_ response: String, from: Int = 6, to: Int? = nil, stripPadding: Bool = false) -> String {
        let hex = JavaCompat.substringClamped(response, from, to ?? response.count)
        let evenHex = hex.count % 2 == 0 ? hex : String(hex.dropLast())
        var bytes = (try? JavaCompat.hexStringToBytes(evenHex)) ?? []
        if stripPadding {
            while let l = bytes.last, l == 0x00 || l == 0xFF || l == 0x20 { bytes.removeLast() }
        }
        return String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "")
    }
}
