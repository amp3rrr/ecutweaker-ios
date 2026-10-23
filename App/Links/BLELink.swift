import CoreBluetooth
import Foundation

/// ELM327 over Bluetooth Low Energy (vLinker FS/MC+ BLE, iCar Pro BLE, generic FFF0/FFE0 dongles).
/// Replaces ElmBluetooth.java, which used classic SPP (not available to iOS apps).
final class BLELink: NSObject, ElmLink, CBCentralManagerDelegate, CBPeripheralDelegate {

    /// Known UART-over-GATT layouts (service, notify characteristic, write characteristic).
    static let knownProfiles: [(service: CBUUID, notify: CBUUID, write: CBUUID)] = [
        (CBUUID(string: "FFF0"), CBUUID(string: "FFF1"), CBUUID(string: "FFF2")),
        (CBUUID(string: "FFE0"), CBUUID(string: "FFE1"), CBUUID(string: "FFE1")),
        (CBUUID(string: "18F0"), CBUUID(string: "2AF0"), CBUUID(string: "2AF1")),
        (CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),
         CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
         CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F")),
    ]

    /// Standard GATT services that never carry the ELM serial stream.
    private static let ignoredServices: Set<CBUUID> = [
        CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A"),
        CBUUID(string: "180F"), CBUUID(string: "1805"), CBUUID(string: "FE59"),
    ]

    let peripheralID: UUID
    private(set) var displayName: String
    var onReceive: ((Data) -> Void)?
    var onClosed: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "ecutweaker.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var pendingServices = 0
    private var openCompletion: ((Error?) -> Void)?
    private var isOpen = false
    private var timeoutWork: DispatchWorkItem?

    init(peripheralID: UUID, name: String) {
        self.peripheralID = peripheralID
        self.displayName = name
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func open(completion: @escaping (Error?) -> Void) {
        queue.async {
            self.openCompletion = completion
            let work = DispatchWorkItem { [weak self] in self?.finishOpen(ElmLinkError("BLE connection timeout")) }
            self.timeoutWork = work
            self.queue.asyncAfter(deadline: .now() + 15, execute: work)
            if self.central.state == .poweredOn { self.connectNow() }
        }
    }

    func close() {
        queue.async {
            self.isOpen = false
            self.timeoutWork?.cancel()
            if let p = self.peripheral {
                if let n = self.notifyChar, p.state == .connected { p.setNotifyValue(false, for: n) }
                self.central.cancelPeripheralConnection(p)
            }
            self.peripheral = nil
        }
    }

    func send(_ data: Data) {
        queue.async {
            guard let p = self.peripheral, let w = self.writeChar else { return }
            let mtu = max(20, p.maximumWriteValueLength(for: self.writeType))
            var offset = 0
            while offset < data.count {
                let end = min(offset + mtu, data.count)
                p.writeValue(data.subdata(in: offset..<end), for: w, type: self.writeType)
                offset = end
            }
        }
    }

    // MARK: - Private

    private func finishOpen(_ error: Error?) {
        guard let completion = openCompletion else { return }
        openCompletion = nil
        timeoutWork?.cancel()
        if error == nil {
            isOpen = true
        } else if let p = peripheral {
            central.cancelPeripheralConnection(p)
            peripheral = nil
        }
        completion(error)
    }

    private func connectNow() {
        guard peripheral == nil else { return }
        guard let p = central.retrievePeripherals(withIdentifiers: [peripheralID]).first else {
            finishOpen(ElmLinkError("BLE device not found – scan and select it again"))
            return
        }
        peripheral = p
        p.delegate = self
        if let n = p.name { displayName = n }
        central.connect(p, options: nil)
    }

    private func choose(on p: CBPeripheral) {
        let services = p.services ?? []
        // 1) known profiles
        for profile in Self.knownProfiles {
            guard let s = services.first(where: { $0.uuid == profile.service }),
                  let n = s.characteristics?.first(where: { $0.uuid == profile.notify }),
                  let w = s.characteristics?.first(where: { $0.uuid == profile.write }) else { continue }
            use(notify: n, write: w, on: p)
            return
        }
        // 2) generic: a service with a notify/indicate and a write characteristic
        for s in services where !Self.ignoredServices.contains(s.uuid) {
            let chars = s.characteristics ?? []
            let notifying = chars.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            let writable = chars.filter { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            if let both = notifying.first(where: { writable.contains($0) }) {
                use(notify: both, write: both, on: p)
                return
            }
            if let n = notifying.first, let w = writable.first {
                use(notify: n, write: w, on: p)
                return
            }
        }
        finishOpen(ElmLinkError("No serial (UART) characteristic found on this BLE device"))
    }

    private func use(notify n: CBCharacteristic, write w: CBCharacteristic, on p: CBPeripheral) {
        notifyChar = n
        writeChar = w
        writeType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.setNotifyValue(true, for: n)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if openCompletion != nil { connectNow() }
        case .poweredOff, .unauthorized, .unsupported:
            if openCompletion != nil {
                finishOpen(ElmLinkError(central.state == .unauthorized ? "Bluetooth permission denied" : "Bluetooth is off"))
            } else if isOpen {
                isOpen = false
                onClosed?(ElmLinkError("Bluetooth turned off"))
            }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        finishOpen(error ?? ElmLinkError("BLE connection failed"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        if openCompletion != nil {
            finishOpen(error ?? ElmLinkError("BLE device disconnected"))
        } else if isOpen {
            isOpen = false
            onClosed?(error)
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        if let error { finishOpen(error); return }
        if services.isEmpty { finishOpen(ElmLinkError("BLE device has no services")); return }
        pendingServices = services.count
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServices -= 1
        if pendingServices <= 0 && notifyChar == nil { choose(on: peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == notifyChar else { return }
        if let error { finishOpen(error); return }
        if characteristic.isNotifying { finishOpen(nil) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let v = characteristic.value, !v.isEmpty else { return }
        onReceive?(v)
    }
}

/// Scanner used by the device picker.
final class BLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    struct Device: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var state: CBManagerState = .unknown
    private var central: CBCentralManager?

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        } else if central?.state == .poweredOn {
            scan()
        }
    }

    func stop() { central?.stopScan() }

    private func scan() {
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        if central.state == .poweredOn { scan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let rssi = RSSI.intValue
        if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            if devices[i].name.isEmpty && !name.isEmpty { devices[i].name = name }
            if rssi != 127 { devices[i].rssi = rssi }
        } else {
            devices.append(Device(id: peripheral.identifier, name: name, rssi: rssi))
        }
    }

    static func looksLikeObd(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["OBD", "ELM", "VLINK", "V-LINK", "LINK", "IOS-VLINK", "VGATE", "ICAR", "KONNWEI", "VEEPEAK", "CAN", "SCAN"]
            .contains { n.contains($0) }
    }
}
