import Foundation

/// Lenient accessors mimicking Android's org.json coercions
/// (getString on numbers, getInt on doubles/strings, getBoolean on "true"/"false").
enum J {
    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func parseObject(_ text: String) throws -> [String: Any] {
        guard let obj = try parse(Data(text.utf8)) as? [String: Any] else {
            throw EcuError.database("JSON root is not an object")
        }
        return obj
    }

    static func obj(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func arr(_ v: Any?) -> [Any]? { v as? [Any] }

    static func str(_ v: Any?) -> String? {
        guard let v else { return nil }
        if v is NSNull { return nil }
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double {
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ v: Any?) -> Int? {
        guard let v else { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double, d.isFinite { return Int(JavaCompat.d2l(d)) }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite {
            return Int(JavaCompat.d2l(d))
        }
        return nil
    }

    static func double(_ v: Any?) -> Double? {
        guard let v else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Lenient boolean: JSON true/false, numbers (non-zero = true, like DDT4All's
    /// Python truthiness) and the strings "true"/"false"/"1"/"0".
    static func bool(_ v: Any?) -> Bool? {
        guard let v else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.doubleValue != 0 }
        if let i = v as? Int { return i != 0 }
        if let d = v as? Double { return d != 0 }
        if let s = v as? String {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no", "": return false
            default: return nil
            }
        }
        return nil
    }
}
