import Foundation

/// Errors thrown by the ECU layer. In the Java original most of these were
/// unchecked exceptions (NPE, NumberFormatException, ArrayIndexOutOfBounds…)
/// caught somewhere up the call stack; here they are explicit.
public enum EcuError: Error, CustomStringConvertible, Equatable {
    case requestNotFound(String)
    case dataNotFound(String)
    case dataItemNotFound(String)
    case responseTooShort
    case numberFormat(String)
    case invalidValue(String)
    case divisionByZero
    case database(String)

    public var description: String {
        switch self {
        case .requestNotFound(let n): return "Request '\(n)' not found in ECU definition"
        case .dataNotFound(let n): return "Data '\(n)' not found in ECU definition"
        case .dataItemNotFound(let n): return "Data item '\(n)' not found in request"
        case .responseTooShort: return "Response too short"
        case .numberFormat(let s): return "Invalid number: '\(s)'"
        case .invalidValue(let s): return "Invalid value: \(s)"
        case .divisionByZero: return "Division by zero"
        case .database(let s): return s
        }
    }
}

/// Helpers that reproduce the exact semantics of the Java library calls used by
/// the original EcuTweaker code (BigInteger, Integer.parseInt, String.format…),
/// so the Swift port produces byte-for-byte identical frames and display strings.
public enum JavaCompat {

    // MARK: - Strings

    /// Ecu.padLeft — NB: when `str` is longer than `length` it is truncated to its
    /// *first* `length` characters (quirk of the original, kept on purpose).
    public static func padLeft(_ str: String, _ length: Int, _ pad: Character) -> String {
        let count = str.count
        if count >= length { return String(str.prefix(length)) }
        return String(repeating: String(pad), count: length - count) + str
    }

    /// Java `String.split(String)` with limit 0 for a single-character separator:
    /// trailing empty strings are removed, leading ones are kept.
    public static func split(_ s: String, _ separator: Character) -> [String] {
        guard s.contains(separator) else { return [s] }
        var parts = s.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        return parts
    }

    /// Java `String.substring(begin, end)` that throws instead of crashing.
    public static func substring(_ s: String, _ begin: Int, _ end: Int) throws -> String {
        let chars = Array(s)
        guard begin >= 0, end <= chars.count, begin <= end else { throw EcuError.responseTooShort }
        return String(chars[begin..<end])
    }

    /// Like `substring` but clamps the end to the string length (never throws).
    public static func substringClamped(_ s: String, _ begin: Int, _ end: Int) -> String {
        let chars = Array(s)
        let b = max(0, min(begin, chars.count))
        let e = max(b, min(end, chars.count))
        return String(chars[b..<e])
    }

    /// Java `String.hashCode()`.
    public static func javaStringHash(_ s: String) -> Int32 {
        var h: Int32 = 0
        for u in s.utf16 { h = h &* 31 &+ Int32(u) }
        return h
    }

    /// Iteration order of a `java.util.HashMap<String, …>` filled with `put()` in
    /// the given insertion order (default capacity 16, load factor 0.75).
    public static func javaHashMapOrder(_ insertionOrder: [String]) -> [String] {
        var cap = 16
        while Double(insertionOrder.count) > Double(cap) * 0.75 { cap *= 2 }
        func bucket(_ k: String) -> Int {
            let h = javaStringHash(k)
            let spread = h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)
            return Int(spread) & (cap - 1)
        }
        return insertionOrder.enumerated()
            .map { (bucket($0.element), $0.offset, $0.element) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            .map { $0.2 }
    }

    // MARK: - Hex

    /// Java `Character.digit(c, 16)`.
    @inline(__always)
    public static func hexDigit(_ c: Character) -> Int {
        guard let a = c.asciiValue else { return -1 }
        switch a {
        case 48...57: return Int(a) - 48
        case 65...70: return Int(a) - 55
        case 97...102: return Int(a) - 87
        default: return -1
        }
    }

    public static func isHexadecimal(_ text: String) -> Bool {
        for c in text where hexDigit(c) < 0 { return false }
        return true
    }

    /// Ecu.hexStringToByteArray (spaces removed). Odd length throws, like the
    /// StringIndexOutOfBoundsException of the original.
    public static func hexStringToBytes(_ s: String) throws -> [UInt8] {
        let chars = Array(s.replacingOccurrences(of: " ", with: ""))
        guard chars.count % 2 == 0 else { throw EcuError.numberFormat(s) }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            let v = (hexDigit(chars[i]) << 4) + hexDigit(chars[i + 1])
            out.append(UInt8(truncatingIfNeeded: v))
            i += 2
        }
        return out
    }

    /// Ecu.byteArrayToHex — uppercase, two digits per byte.
    public static func bytesToHex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF")
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes {
            s.append(digits[Int(b >> 4)])
            s.append(digits[Int(b & 0x0F)])
        }
        return s
    }

    /// Java `Integer.parseInt(s, radix)`.
    public static func parseInt(_ s: String, radix: Int = 10) throws -> Int {
        guard !s.isEmpty, let v = Int(s, radix: radix), v >= Int(Int32.min), v <= Int(Int32.max) else {
            throw EcuError.numberFormat(s)
        }
        return v
    }

    /// Lenient integer parse used where the original would have thrown and the
    /// exception would have aborted an otherwise harmless operation.
    public static func parseIntOrNil(_ s: String, radix: Int = 10) -> Int? {
        try? parseInt(s.trimmingCharacters(in: .whitespaces), radix: radix)
    }

    private static func validatedDigits(_ s: String, radix: Int) throws -> [Int] {
        var str = Substring(s)
        if str.first == "+" { str = str.dropFirst() }
        guard !str.isEmpty else { throw EcuError.numberFormat(s) }
        var out = [Int]()
        out.reserveCapacity(str.count)
        for c in str {
            let d = hexDigit(c)
            guard d >= 0, d < radix else { throw EcuError.numberFormat(s) }
            out.append(d)
        }
        return out
    }

    /// `new BigInteger(hex, 16).intValue()` — low 32 bits, two's complement.
    public static func intValueOfHex(_ hex: String) throws -> Int32 {
        let digits = try validatedDigits(hex, radix: 16)
        var v: UInt32 = 0
        for d in digits.suffix(8) { v = (v << 4) | UInt32(d) }
        return Int32(bitPattern: v)
    }

    /// `new BigInteger(bin, 2).toString(16)`.
    public static func binToHex(_ bin: String) throws -> String {
        let bits = try validatedDigits(bin, radix: 2)
        let padded = Array(repeating: 0, count: (4 - bits.count % 4) % 4) + bits
        let hexChars = Array("0123456789abcdef")
        var out = ""
        var i = 0
        while i < padded.count {
            let n = padded[i] << 3 | padded[i + 1] << 2 | padded[i + 2] << 1 | padded[i + 3]
            if !(out.isEmpty && n == 0) { out.append(hexChars[n]) }
            i += 4
        }
        return out.isEmpty ? "0" : out
    }

    /// `new BigInteger(hex, 16).toString(2)`.
    public static func hexToBin(_ hex: String) throws -> String {
        let digits = try validatedDigits(hex, radix: 16)
        var out = ""
        out.reserveCapacity(digits.count * 4)
        for d in digits {
            for shift in stride(from: 3, through: 0, by: -1) {
                let bit = (d >> shift) & 1
                if out.isEmpty && bit == 0 { continue }
                out.append(bit == 1 ? "1" : "0")
            }
        }
        return out.isEmpty ? "0" : out
    }

    /// `Integer.toBinaryString(int)` (32-bit two's complement for negatives).
    public static func toBinaryString(_ v: Int32) -> String {
        String(UInt32(bitPattern: v), radix: 2)
    }

    /// Ecu.byteToBinaryString(b, 8)
    @inline(__always)
    public static func byteToBinary(_ b: UInt8) -> String {
        padLeft(String(b, radix: 2), 8, "0")
    }

    /// Ecu.stringToHex — each UTF-16 unit as `%02x`.
    public static func stringToHex(_ s: String) -> String {
        var out = ""
        for u in s.utf16 { out += String(format: "%02x", Int(u)) }
        return out
    }

    // MARK: - Numbers

    /// Java `(int) floatValue` — truncation toward zero, saturating, NaN → 0.
    public static func f2i(_ f: Float) -> Int32 {
        if f.isNaN { return 0 }
        if f >= 2147483648.0 { return Int32.max }
        if f <= -2147483648.0 { return Int32.min }
        return Int32(f)
    }

    /// Java `(long) doubleValue`.
    public static func d2l(_ d: Double) -> Int64 {
        if d.isNaN { return 0 }
        if d >= 9223372036854775807.0 { return Int64.max }
        if d <= -9223372036854775808.0 { return Int64.min }
        return Int64(d)
    }

    /// Java `Float.parseFloat` (decimal subset: optional sign, digits, '.', exponent,
    /// optional f/F/d/D suffix, "NaN", "Infinity", surrounding whitespace).
    public static func parseFloat(_ s: String) throws -> Float {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsigned = t.hasPrefix("-") || t.hasPrefix("+") ? String(t.dropFirst()) : t
        if unsigned == "NaN" { return .nan }
        if unsigned == "Infinity" { return t.hasPrefix("-") ? -.infinity : .infinity }
        if let last = t.last, "fFdD".contains(last) { t.removeLast() }
        let allowed = Set("0123456789.eE+-")
        guard !t.isEmpty, t.allSatisfy({ allowed.contains($0) }), let v = Float(t) else {
            throw EcuError.numberFormat(s)
        }
        return v
    }

    /// Ecu.EcuData.fmt(double): integral values as `%d`, others `%.2f` (Locale.US).
    public static func fmt(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        let l = d2l(d)
        if Double(l) == d { return String(l) }
        return formatFixed(d, fractionDigits: 2)
    }

    /// Java `String.format(Locale.US, "%.Nf", d)`: HALF_UP rounding applied to the
    /// shortest decimal representation of `d` (FormattedFloatingDecimal behaviour).
    public static func formatFixed(_ d: Double, fractionDigits n: Int) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        let dec = DecimalDigits(d).rounded(fractionDigits: n, mode: .halfUp)
        return dec.render(minInt: 1, minFrac: n, grouping: 0)
    }
}

/// A decimal number as a digit string: value = 0.d1d2d3… × 10^pointPos.
struct DecimalDigits {
    enum Rounding { case halfUp, halfEven }

    var negative: Bool
    var digits: [UInt8]      // no leading/trailing zeros; empty means zero
    var pointPos: Int

    /// Shortest round-trip representation (same digits Java's Double.toString uses).
    init(_ d: Double) {
        negative = d.sign == .minus
        digits = []
        pointPos = 0
        var s = Substring(abs(d).description)
        var exp = 0
        if let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp = Int(s[s.index(after: eIdx)...]) ?? 0
            s = s[..<eIdx]
        }
        var intCount = 0
        var seenPoint = false
        for c in s {
            if c == "." { seenPoint = true; continue }
            guard let v = c.wholeNumberValue else { continue }
            digits.append(UInt8(v))
            if !seenPoint { intCount += 1 }
        }
        pointPos = intCount + exp
        normalize()
    }

    private mutating func normalize() {
        while let f = digits.first, f == 0 { digits.removeFirst(); pointPos -= 1 }
        while let l = digits.last, l == 0 { digits.removeLast() }
        if digits.isEmpty { pointPos = 0 }
    }

    func rounded(fractionDigits n: Int, mode: Rounding) -> DecimalDigits {
        var r = self
        let keep = pointPos + n
        if keep >= digits.count { return r }
        if keep < 0 {
            r.digits = []
            r.pointPos = 0
            return r
        }
        let first = digits[keep]
        let restNonZero = digits[(keep + 1)...].contains { $0 != 0 }
        let up: Bool
        switch mode {
        case .halfUp:
            up = first >= 5
        case .halfEven:
            let prevOdd = keep > 0 && digits[keep - 1] % 2 == 1
            up = first > 5 || (first == 5 && (restNonZero || prevOdd))
        }
        r.digits = Array(digits[0..<keep])
        if up {
            var i = r.digits.count - 1
            var carry = true
            while carry && i >= 0 {
                if r.digits[i] == 9 { r.digits[i] = 0; i -= 1 } else { r.digits[i] += 1; carry = false }
            }
            if carry { r.digits.insert(1, at: 0); r.pointPos += 1 }
        }
        r.normalize()
        return r
    }

    /// Renders as fixed point. `grouping` > 0 inserts ',' every `grouping` digits.
    func render(minInt: Int, minFrac: Int, grouping: Int, alwaysIntegerZero: Bool = true) -> String {
        var intDigits = [UInt8]()
        var fracDigits = [UInt8]()
        if pointPos > 0 {
            for i in 0..<pointPos { intDigits.append(i < digits.count ? digits[i] : 0) }
            if pointPos < digits.count { fracDigits = Array(digits[pointPos...]) }
        } else {
            fracDigits = Array(repeating: 0, count: -pointPos) + digits
        }
        while intDigits.count < minInt { intDigits.insert(0, at: 0) }
        while fracDigits.count < minFrac { fracDigits.append(0) }
        var intStr = intDigits.map { String($0) }.joined()
        if intStr.isEmpty && fracDigits.isEmpty && alwaysIntegerZero { intStr = "0" }
        if grouping > 0 && intStr.count > grouping {
            var grouped = ""
            for (i, c) in intStr.enumerated() {
                if i > 0 && (intStr.count - i) % grouping == 0 { grouped.append(",") }
                grouped.append(c)
            }
            intStr = grouped
        }
        var s = negative ? "-" : ""
        s += intStr
        if !fracDigits.isEmpty { s += "." + fracDigits.map { String($0) }.joined() }
        return s
    }
}

/// Subset of `java.text.DecimalFormat` (Locale.US) sufficient for DDT format
/// strings such as "0.00", "####0", "00.0". Rounding is HALF_EVEN on the shortest
/// decimal representation (what Android's ICU-backed DecimalFormat does).
/// Patterns without any digit character (e.g. "bin") are rejected (init returns nil)
/// and the caller falls back to the default formatting — same as DDT4All.
public struct JavaDecimalFormat {
    let prefix: String
    let suffix: String
    let minInt: Int
    let minFrac: Int
    let maxFrac: Int
    let grouping: Int
    let multiplier: Double

    public init?(pattern: String) {
        // Positive sub-pattern only.
        var chars = [Character]()
        var inQuote = false
        var literalMask = [Bool]()
        var it = Array(pattern)
        var i = 0
        while i < it.count {
            let c = it[i]
            if c == "'" {
                if i + 1 < it.count && it[i + 1] == "'" { chars.append("'"); literalMask.append(true); i += 2; continue }
                inQuote.toggle(); i += 1; continue
            }
            if c == ";" && !inQuote { break }
            chars.append(c)
            literalMask.append(inQuote)
            i += 1
        }
        it = chars
        let numberChars: Set<Character> = ["#", "0", ",", "."]
        guard let start = it.indices.first(where: { !literalMask[$0] && numberChars.contains(it[$0]) }) else { return nil }
        var end = start
        while end < it.count && !literalMask[end] && numberChars.contains(it[end]) { end += 1 }
        let number = Array(it[start..<end])
        guard number.contains("0") || number.contains("#") else { return nil }
        if it[end...].contains(where: { $0 == "E" }) { return nil }

        var mult = 1.0
        func literal(_ range: Range<Int>) -> String {
            var s = ""
            for j in range {
                let c = it[j]
                if !literalMask[j] {
                    if c == "%" { mult = 100 }
                    if c == "\u{2030}" { mult = 1000 }
                }
                s.append(c)
            }
            return s
        }
        prefix = literal(0..<start)
        suffix = literal(end..<it.count)
        multiplier = mult

        let pointIdx = number.firstIndex(of: ".")
        let intPart = pointIdx.map { Array(number[..<$0]) } ?? number
        let fracPart = pointIdx.map { Array(number[number.index(after: $0)...]) } ?? []
        var mi = intPart.filter { $0 == "0" }.count
        if mi == 0 && intPart.contains("#") && pointIdx != nil { mi = 1 }   // "#.##" → "#0.##"
        minInt = mi
        minFrac = fracPart.filter { $0 == "0" }.count
        maxFrac = fracPart.filter { $0 == "0" || $0 == "#" }.count
        if let lastComma = intPart.lastIndex(of: ",") {
            grouping = intPart[intPart.index(after: lastComma)...].filter { $0 == "0" || $0 == "#" }.count
        } else {
            grouping = 0
        }
    }

    public func format(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        let negative = value.sign == .minus
        if value.isInfinite { return (negative ? "-" : "") + prefix + "\u{221E}" + suffix }
        var dec = DecimalDigits(abs(value) * multiplier).rounded(fractionDigits: maxFrac, mode: .halfEven)
        dec.negative = false
        let body = dec.render(minInt: minInt, minFrac: minFrac, grouping: grouping)
        return (negative ? "-" : "") + prefix + body + suffix
    }
}
