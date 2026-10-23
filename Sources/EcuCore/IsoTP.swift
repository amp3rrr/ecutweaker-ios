import Foundation

/// Port of IsoTPEncode / IsoTPDecode (raw ISO-TP framing as hex strings for ELM327 with CAF0).
public enum IsoTP {

    /// Splits a hex message into single/first/consecutive frames.
    /// Fixes vs. the Java original (both match DDT4All's elm.py):
    ///  * first frame header is "1" + the *last* three length digits (Java took
    ///    `header.substring(0, 3)` and dropped the last digit, breaking every ≥8-byte request);
    ///  * consecutive frame sequence number wraps modulo 16.
    public static func encode(_ message: String) -> [String] {
        let msg = message.replacingOccurrences(of: " ", with: "")
        guard JavaCompat.isHexadecimal(msg), msg.count % 2 == 0 else { return [] }
        let chars = Array(msg)
        let len = chars.count / 2
        if len < 8 {
            return [String(format: "%02X", len) + msg]
        }
        var frames = [String]()
        let lenHex = String(format: "%03X", len)
        frames.append("1" + String(lenHex.suffix(3)) + String(chars[0..<12]))
        var pos = 12
        var frameNumber = 1
        while pos < chars.count {
            let end = min(pos + 14, chars.count)
            frames.append("2" + String(format: "%X", frameNumber % 16) + String(chars[pos..<end]))
            frameNumber += 1
            pos = end
        }
        return frames
    }

    /// Reassembles ISO-TP response frames into the payload hex string, or an
    /// "ERROR : …" string. Unlike the Java original, error strings are returned
    /// as-is (Java truncated them to `nbytes*2` characters, usually to "").
    public static func decode(_ responsesIn: [String]) -> String {
        guard let first = responsesIn.first else { return "ERROR : NO DATA" }
        for line in responsesIn where !JavaCompat.isHexadecimal(line) { return "ERROR : NON HEXA" }

        let nbytes: Int
        var result: String

        if responsesIn.count == 1 {
            guard first.first == "0", let n = Int(JavaCompat.substringClamped(first, 1, 2), radix: 16) else {
                return "ERROR : BAD CAN FORMAT (SINGLE LINE)"
            }
            nbytes = n
            result = JavaCompat.substringClamped(first, 2, 2 + nbytes * 2)
        } else {
            guard first.first == "1", let n = Int(JavaCompat.substringClamped(first, 1, 4), radix: 16) else {
                return "ERROR : BAD CAN FORMAT (MULTILINE)"
            }
            nbytes = n
            result = JavaCompat.substringClamped(first, 4, 16)
            var cframe = 1
            for fr in responsesIn.dropFirst() {
                guard fr.first == "2" else { return "ERROR : BAD CAN FORMAT" }
                let seq = Int(JavaCompat.substringClamped(fr, 1, 2), radix: 16) ?? -1
                if seq != cframe % 16 { return "ERROR : BAD CFC" }
                cframe += 1
                result += JavaCompat.substringClamped(fr, 2, 16)
            }
        }

        if result.count >= nbytes * 2 {
            return String(result.prefix(nbytes * 2))
        }
        return "ERROR : RESPONSE TOO SHORT (" + result + ")"
    }
}
