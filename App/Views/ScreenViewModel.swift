import SwiftUI
import UIKit

struct DTCReport: Identifiable {
    let id = UUID()
    let items: [[String]]
}

struct ValueDiagnostics: Identifiable {
    let id = UUID()
    let name: String
    let text: String
}

/// Bridges ScreenController (ScreenActivity logic) to SwiftUI.
@MainActor
final class ScreenViewModel: ObservableObject {
    @Published private(set) var screen: Layout.ScreenData?
    @Published private(set) var screenName: String?
    @Published private(set) var values: [String: String] = [:]
    @Published private(set) var inputs: [String: String] = [:]
    @Published private(set) var pickers: [String: String] = [:]
    @Published private(set) var autoReload = false
    @Published private(set) var busy = false
    @Published var dtcReport: DTCReport?
    @Published var alertText: String?
    @Published var diagnostics: ValueDiagnostics?
    /// Copies of the ECU file and layout in a temporary folder, for sharing.
    @Published private(set) var ecuExportURLs: [URL] = []
    @Published private(set) var openError: String?

    private(set) var controller: ScreenController?
    private var token: UUID?
    private weak var connection: ConnectionManager?
    private var href = ""
    private var imageCache: [String: UIImage] = [:]

    static let softFlowKey = "softFlowControl"

    var categories: [String] { controller?.categories ?? [] }
    func screens(in category: String) -> [String] { controller?.screens(in: category) ?? [] }
    var sdsNames: [String] { controller?.ecu.sdsRequests.keys.sorted() ?? [] }
    var defaultSDS: String { controller?.ecu.defaultSDS ?? "" }
    var canTimeout: Int { controller?.canTimeout ?? 0 }
    var softFlowControl: Bool { controller?.softFlowControl ?? false }
    var ecuName: String { controller?.ecu.name ?? "" }

    func open(model: AppModel, href: String) {
        connection = model.connection
        self.href = href
        if controller == nil {
            guard let db = model.database else {
                openError = "Database not loaded"
                return
            }
            do {
                let c = try ScreenController(database: db, href: href, session: model.connection.session,
                                             softFlowControl: UserDefaults.standard.bool(forKey: Self.softFlowKey))
                let log = model.log
                let conn = model.connection
                c.onLog = { log.append($0) }
                c.onChange = { [weak self] in self?.sync() }
                c.onAlert = { [weak self] in self?.alertText = $0 }
                c.onDTCReport = { [weak self] in self?.dtcReport = DTCReport(items: $0) }
                c.onDisconnected = { conn.reconnectIfNeeded() }
                controller = c
                log.append("Opened \(href) (\(c.ecu.protocolName))")
                log.append("Default diag session : \(c.ecu.defaultSDS)")
                log.append(c.ecu.dataSummary)
                ecuExportURLs = Self.writeExport(c.ecuFiles())
                if let last = UserDefaults.standard.string(forKey: "lastScreen.\(href)"), c.layout.screen(last) != nil {
                    c.drawScreen(last)
                }
            } catch {
                openError = String(describing: error)
                return
            }
        }
        token = model.connection.attach { [weak self] e in self?.controller?.handle(e) }
        if !model.connection.isConnected && model.connection.hasDevice && !model.connection.isConnecting {
            model.connection.connect()
        }
        sync()
    }

    func close() {
        controller?.stopAutoReload()
        if let token { connection?.detach(token) }
        token = nil
    }

    func draw(_ name: String) {
        controller?.drawScreen(name)
        UserDefaults.standard.set(name, forKey: "lastScreen.\(href)")
        sync()
    }

    func reload() {
        guard let c = controller else { return }
        if connection?.isConnected != true {
            connection?.connect()
            alertText = "Not connected"
            return
        }
        c.stopAutoReload()
        c.updateDisplays()
    }

    func toggleAutoReload() {
        guard let c = controller else { return }
        if connection?.isConnected != true {
            connection?.connect()
            return
        }
        c.setAutoReload(!c.autoReload)
        sync()
    }

    func showDiagnostics(for name: String) {
        guard let c = controller else { return }
        diagnostics = ValueDiagnostics(name: name, text: c.diagnostics(forData: name))
    }

    private static func writeExport(_ files: [(name: String, data: Data)]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ecu-export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return files.compactMap { f in
            let url = dir.appendingPathComponent((f.name as NSString).lastPathComponent)
            return (try? f.data.write(to: url)) != nil ? url : nil
        }
    }

    func press(_ uniqueName: String) { controller?.executeButton(uniqueName) }
    func readDTC() { controller?.readDTC() }
    func clearDTC() { controller?.clearDTC() }

    func applySettings(canTimeout: Int, softFlowControl: Bool, sdsName: String?) {
        UserDefaults.standard.set(softFlowControl, forKey: Self.softFlowKey)
        controller?.applySettings(canTimeout: canTimeout, softFlowControl: softFlowControl, sdsName: sdsName)
        if let name = screenName { draw(name) }
    }

    // MARK: Inputs

    func inputBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { self.inputs[key] ?? "" },
            set: { v in
                self.inputs[key] = v
                self.controller?.inputValues[key] = v
            })
    }

    func pickerBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { self.pickers[key] ?? "" },
            set: { v in
                self.pickers[key] = v
                self.controller?.pickerValues[key] = v
            })
    }

    func isPicker(_ input: Layout.InputData) -> Bool { controller?.isPicker(input) ?? false }
    func pickerItems(_ input: Layout.InputData) -> [String] { controller?.pickerItems(for: input) ?? [] }

    func image(for text: String, button: Bool) -> UIImage? {
        let key = (button ? "b:" : "p:") + text
        if let img = imageCache[key] { return img }
        guard let data = controller?.imageData(forPictureText: text, isButton: button),
              let img = UIImage(data: data) else { return nil }
        imageCache[key] = img
        return img
    }

    private func sync() {
        guard let c = controller else { return }
        if screenName != c.currentScreenName || (screen == nil) != (c.currentScreen == nil) {
            screenName = c.currentScreenName
            screen = c.currentScreen
        }
        if values != c.displayValues { values = c.displayValues }
        if inputs != c.inputValues { inputs = c.inputValues }
        if pickers != c.pickerValues { pickers = c.pickerValues }
        if autoReload != c.autoReload { autoReload = c.autoReload }
        if busy != c.busy { busy = c.busy }
    }
}
