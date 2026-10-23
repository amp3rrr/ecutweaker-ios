import ExternalAccessory
import Foundation
import SwiftUI
import UIKit

enum LinkMode: String, CaseIterable, Identifiable {
    case ble = "BLE"
    case mfi = "MFi"
    case wifi = "Wi-Fi"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .ble: return "antenna.radiowaves.left.and.right"
        case .mfi: return "link"
        case .wifi: return "wifi"
        }
    }
}

/// Owns the single ElmSession (the Java ElmBase singleton), builds the link for the
/// selected transport, auto-reconnects (MainActivity's 4 s connection timer) and routes
/// events to whichever screen is active (ElmBase.changeHandler).
@MainActor
final class ConnectionManager: ObservableObject {
    private enum Keys {
        static let mode = "linkMode", bleID = "bleDeviceID", bleName = "bleDeviceName"
        static let mfiSerial = "mfiSerial", mfiName = "mfiName", wifiHost = "wifiHost", wifiPort = "wifiPort"
    }

    @Published var mode: LinkMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            disconnect()
        }
    }
    @Published private(set) var state: ElmState = .none
    @Published private(set) var deviceName: String?
    @Published private(set) var queueRemaining = 0
    @Published private(set) var wantsConnection = false

    @Published private(set) var bleDeviceID: String? = UserDefaults.standard.string(forKey: Keys.bleID)
    @Published private(set) var bleDeviceName: String? = UserDefaults.standard.string(forKey: Keys.bleName)
    @Published private(set) var mfiSerial: String? = UserDefaults.standard.string(forKey: Keys.mfiSerial)
    @Published private(set) var mfiName: String? = UserDefaults.standard.string(forKey: Keys.mfiName)
    @Published var wifiHost: String = UserDefaults.standard.string(forKey: Keys.wifiHost) ?? "192.168.0.10" {
        didSet { UserDefaults.standard.set(wifiHost, forKey: Keys.wifiHost) }
    }
    @Published var wifiPort: Int = (UserDefaults.standard.object(forKey: Keys.wifiPort) as? Int) ?? 35000 {
        didSet { UserDefaults.standard.set(wifiPort, forKey: Keys.wifiPort) }
    }

    let session: ElmSession
    private let log: LogStore
    private var consumerID: UUID?
    private var consumer: ((ElmEvent) -> Void)?
    private var timer: Timer?

    init(log: LogStore) {
        self.log = log
        self.mode = LinkMode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .ble
        self.session = ElmSession(callbackQueue: .main, logURL: AppPaths.logFile)
        session.changeHandler { [weak self] e in self?.dispatch(e) }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconnectIfNeeded() }
        }
        EAAccessoryNotifications.register()
    }

    var isConnected: Bool { state == .connected }
    var isConnecting: Bool { state == .connecting }

    var selectedDeviceDescription: String {
        switch mode {
        case .ble: return bleDeviceName ?? (bleDeviceID == nil ? "No device selected" : "BLE device")
        case .mfi: return mfiName ?? "First compatible MFi accessory"
        case .wifi: return "\(wifiHost):\(wifiPort)"
        }
    }

    var hasDevice: Bool {
        switch mode {
        case .ble: return bleDeviceID != nil
        case .mfi, .wifi: return true
        }
    }

    // MARK: - Device selection

    func selectBLE(id: UUID, name: String) {
        bleDeviceID = id.uuidString
        bleDeviceName = name.isEmpty ? "BLE device" : name
        UserDefaults.standard.set(bleDeviceID, forKey: Keys.bleID)
        UserDefaults.standard.set(bleDeviceName, forKey: Keys.bleName)
        mode = .ble
        connect()
    }

    func selectMFi(serial: String?, name: String) {
        mfiSerial = serial
        mfiName = name
        UserDefaults.standard.set(serial, forKey: Keys.mfiSerial)
        UserDefaults.standard.set(name, forKey: Keys.mfiName)
        mode = .mfi
        connect()
    }

    // MARK: - Connection

    func connect() {
        wantsConnection = true
        guard let link = makeLink() else {
            log.append("No device selected")
            return
        }
        log.append("Connecting to \(selectedDeviceDescription)…")
        session.connect(link: link)
    }

    func disconnect() {
        wantsConnection = false
        session.disconnect()
    }

    func reconnectIfNeeded() {
        guard wantsConnection, !isConnected, !isConnecting, hasDevice else { return }
        if UIApplication.shared.applicationState == .background { return }
        connect()
    }

    private func makeLink() -> ElmLink? {
        switch mode {
        case .ble:
            guard let id = bleDeviceID.flatMap(UUID.init(uuidString:)) else { return nil }
            return BLELink(peripheralID: id, name: bleDeviceName ?? "BLE")
        case .mfi:
            return MFiLink(preferredSerial: mfiSerial)
        case .wifi:
            return WiFiLink(host: wifiHost, port: UInt16(clamping: wifiPort))
        }
    }

    // MARK: - Event routing (ElmBase.changeHandler)

    private func dispatch(_ e: ElmEvent) {
        switch e {
        case .state(let s):
            state = s
            UIApplication.shared.isIdleTimerDisabled = (s == .connected)
        case .deviceName(let n):
            deviceName = n
        case .log(let t):
            log.append("ELM manager : " + t)
        case .queue(let n):
            queueRemaining = n
        case .response:
            break
        }
        consumer?(e)
    }

    /// Makes `handler` the receiver of ELM events; the current state is replayed to it
    /// (so a screen opening on a live connection initialises its bus, like on Android).
    @discardableResult
    func attach(_ handler: @escaping (ElmEvent) -> Void) -> UUID {
        let id = UUID()
        consumerID = id
        consumer = handler
        session.changeHandler { [weak self] e in self?.dispatch(e) }
        return id
    }

    /// Releases the receiver if it is still the current one (pending commands are dropped).
    func detach(_ id: UUID) {
        guard consumerID == id else { return }
        consumerID = nil
        consumer = nil
        session.clearMessages()
        session.changeHandler { [weak self] e in self?.dispatch(e) }
    }

    /// Queue a command (MainActivity/ScreenActivity.sendCmd).
    func send(_ cmd: String) {
        guard isConnected else { return }
        session.write(cmd)
    }
}

enum EAAccessoryNotifications {
    private static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        EAAccessoryManager.shared().registerForLocalNotifications()
    }
}
