import Foundation

/// Port of org.quark.dr.ecu.Layout — the screen layout file (`<ecu>.json.layout`).
public final class Layout {
    public private(set) var screens: [String: ScreenData] = [:]
    public private(set) var categories: [String: [String]] = [:]

    public convenience init(json: String) throws {
        try self.init(object: J.parseObject(json))
    }

    public init(object: [String: Any]) {
        for (key, value) in J.obj(object["screens"]) ?? [:] {
            guard let s = J.obj(value) else { continue }
            screens[key] = ScreenData(name: key, json: s)
        }
        for (key, value) in J.obj(object["categories"]) ?? [:] {
            categories[key] = (J.arr(value) ?? []).compactMap { J.str($0) }
        }
    }

    /// Category names, sorted (the Java HashMap gave an arbitrary order).
    public var categoryNames: [String] { categories.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    public func screenNames(category: String) -> [String] { categories[category] ?? [] }

    public func screen(_ name: String) -> ScreenData? { screens[name] }

    // MARK: - Model

    public struct Color: Equatable {
        public var r: Int, g: Int, b: Int

        public init(r: Int = 0, g: Int = 0, b: Int = 0) { self.r = r; self.g = g; self.b = b }

        /// Parses "rgb(r,g,b)". When the tag is present but malformed the
        /// original left r=g=b=10; when absent the caller keeps its default.
        init(json: [String: Any], tag: String) {
            r = 10; g = 10; b = 10
            guard let s = J.str(json[tag]), s.count > 5 else { return }
            let inner = s.dropFirst(4).dropLast()
            let cols = inner.split(separator: ",", omittingEmptySubsequences: false)
            if cols.count == 3,
               let rr = Int(cols[0].trimmingCharacters(in: .whitespaces)),
               let gg = Int(cols[1].trimmingCharacters(in: .whitespaces)),
               let bb = Int(cols[2].trimmingCharacters(in: .whitespaces)) {
                r = rr; g = gg; b = bb
            }
        }

        /// ARGB int, like Layout.Color.get()
        public var argb: UInt32 { 0xFF00_0000 | UInt32(r & 0xFF) << 16 | UInt32(g & 0xFF) << 8 | UInt32(b & 0xFF) }
    }

    public struct Font {
        public var name: String?
        public var size: Int = 10
        public var color = Color()

        init() {}
        init(json: [String: Any]) {
            name = J.str(json["name"])
            if let s = J.int(json["size"]) { size = s }
            if json["color"] != nil { color = Color(json: json, tag: "color") }
        }
    }

    public struct Rect {
        public var x = 0, y = 0, w = 0, h = 0
        public var area: Int { w * h }

        init() {}
        init(json: [String: Any]) {
            if let v = J.int(json["width"]) { w = v }
            if let v = J.int(json["height"]) { h = v }
            if let v = J.int(json["top"]) { y = v }
            if let v = J.int(json["left"]) { x = v }
        }
    }

    public struct InputData {
        public var text = ""
        public var request = ""
        public var rect = Rect()
        public var width = 0
        public var font = Font()
        public var color: Color?
        public var fontColor: Color?
    }

    public typealias DisplayData = InputData

    public struct LabelData {
        public var text = ""
        public var rect = Rect()
        public var font = Font()
        public var alignment = 0
        public var color: Color?
        public var fontColor: Color?
    }

    public struct ButtonData {
        public var text = ""
        public var uniqueName = ""
        public var rect = Rect()
        public var font = Font()
        public var sendData: [(delay: Int, request: String)] = []
    }

    public struct ScreenData {
        public let name: String
        public var width = 0
        public var height = 0
        public var color = Color(r: 255, g: 255, b: 255)
        public var preSendData: [(delay: Int, request: String)] = []
        public var inputs: [InputData] = []
        public var labels: [LabelData] = []      // sorted by area, largest first
        public var displays: [DisplayData] = []
        public var buttons: [ButtonData] = []

        init(name: String, json: [String: Any]) {
            self.name = name
            preSendData = Self.sendList(json["presend"])
            if let v = J.int(json["width"]) { width = v }
            if let v = J.int(json["height"]) { height = v }
            if json["color"] != nil { color = Color(json: json, tag: "color") }

            inputs = (J.arr(json["inputs"]) ?? []).compactMap { J.obj($0) }.map(Self.inputData)
            displays = (J.arr(json["displays"]) ?? []).compactMap { J.obj($0) }.map(Self.inputData)

            var labelList = [LabelData]()
            for case let o as [String: Any] in J.arr(json["labels"]) ?? [] {
                var l = LabelData()
                if let t = J.str(o["text"]) { l.text = t }
                if let b = J.obj(o["bbox"]) { l.rect = Rect(json: b) }
                if let f = J.obj(o["font"]) { l.font = Font(json: f) }
                if o["fontcolor"] != nil { l.fontColor = Color(json: o, tag: "fontcolor") }
                if let a = J.int(o["alignment"]) { l.alignment = a }
                if o["color"] != nil { l.color = Color(json: o, tag: "color") }
                labelList.append(l)
            }
            // Collections.sort with (O2.area - O1.area): stable, descending area
            labels = labelList.enumerated()
                .sorted { $0.element.rect.area != $1.element.rect.area ? $0.element.rect.area > $1.element.rect.area : $0.offset < $1.offset }
                .map { $0.element }

            for case let o as [String: Any] in J.arr(json["buttons"]) ?? [] {
                var b = ButtonData()
                if let t = J.str(o["text"]) { b.text = t }
                if let r = J.obj(o["rect"]) { b.rect = Rect(json: r) }
                if let f = J.obj(o["font"]) { b.font = Font(json: f) }
                if let u = J.str(o["uniquename"]) { b.uniqueName = u }
                b.sendData = Self.sendList(o["send"])
                buttons.append(b)
            }
        }

        private static func sendList(_ v: Any?) -> [(delay: Int, request: String)] {
            (J.arr(v) ?? []).compactMap { J.obj($0) }.compactMap { o in
                guard let name = J.str(o["RequestName"]) else { return nil }
                let delay = J.str(o["Delay"]).flatMap { JavaCompat.parseIntOrNil($0) } ?? 0
                return (delay, name)
            }
        }

        private static func inputData(_ o: [String: Any]) -> InputData {
            var d = InputData()
            if let t = J.str(o["text"]) { d.text = t }
            if let r = J.str(o["request"]) { d.request = r }
            if let w = J.int(o["width"]) { d.width = w }
            if let r = J.obj(o["rect"]) { d.rect = Rect(json: r) }
            if let f = J.obj(o["font"]) { d.font = Font(json: f) }
            if o["color"] != nil { d.color = Color(json: o, tag: "color") }
            if o["fontcolor"] != nil { d.fontColor = Color(json: o, tag: "fontcolor") }
            return d
        }

        public func button(named uniqueName: String) -> ButtonData? {
            buttons.first { $0.uniqueName == uniqueName }
        }
    }
}
