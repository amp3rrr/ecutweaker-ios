import Foundation
import SwiftUI

enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Canonical location of the database: visible in Files → On My iPhone → EcuTweaker.
    static var ecuZip: URL { documents.appendingPathComponent("ecu.zip") }

    static var logFile: URL { documents.appendingPathComponent("Logs/log.txt") }

    /// Finds ecu.zip in Documents (any letter case, up to two folders deep).
    static func findEcuZip() -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: ecuZip.path) { return ecuZip }
        guard let e = fm.enumerator(at: documents, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        while let url = e.nextObject() as? URL {
            if e.level > 3 { e.skipDescendants(); continue }
            if url.lastPathComponent.lowercased() == "ecu.zip" { return url }
        }
        return nil
    }
}

/// In-app log (the green log panel of the Android app).
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    private let maxLines = 4000

    func append(_ text: String) {
        lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    func clear() { lines.removeAll() }

    var text: String { lines.joined(separator: "\n") }
}

extension Layout.Color {
    var swiftUI: SwiftUI.Color {
        SwiftUI.Color(red: Double(r & 0xFF) / 255, green: Double(g & 0xFF) / 255, blue: Double(b & 0xFF) / 255)
    }
}

extension ElmState {
    var label: String {
        switch self {
        case .none: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .orange
        default: return .red
        }
    }
}

enum AppInfo {
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
