import Combine
import CoreBluetooth
import ExternalAccessory
import SwiftUI

/// DeviceListActivity: pick the adapter for the selected link type.
struct DevicePickerView: View {
    @EnvironmentObject var conn: ConnectionManager
    @Environment(\.dismiss) var dismiss
    @StateObject var scanner = BLEScanner()
    @State var showAll = false
    @State var mfiRefresh = 0
    @State var pairMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Link", selection: $conn.mode) {
                        ForEach(LinkMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                }
                switch conn.mode {
                case .ble: bleSection
                case .mfi: mfiSection
                case .wifi: wifiSection
                }
            }
            .navigationTitle("Adapter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { scanner.start() }
            .onDisappear { scanner.stop() }
            .onReceive(NotificationCenter.default.publisher(for: .EAAccessoryDidConnect)) { _ in mfiRefresh += 1 }
            .onReceive(NotificationCenter.default.publisher(for: .EAAccessoryDidDisconnect)) { _ in mfiRefresh += 1 }
        }
    }

    // MARK: BLE

    private var bleDevices: [BLEScanner.Device] {
        scanner.devices
            .filter { showAll || BLEScanner.looksLikeObd($0.name) || $0.id.uuidString == conn.bleDeviceID }
            .sorted { $0.rssi > $1.rssi }
    }

    @ViewBuilder private var bleSection: some View {
        Section {
            if scanner.state != .poweredOn {
                Text(bluetoothStateText).foregroundColor(.secondary)
            }
            ForEach(bleDevices) { d in
                Button {
                    conn.selectBLE(id: d.id, name: d.name)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name.isEmpty ? "(no name)" : d.name).foregroundColor(.primary)
                            Text(d.id.uuidString).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(d.rssi) dBm").font(.caption).foregroundColor(.secondary)
                        if d.id.uuidString == conn.bleDeviceID {
                            Image(systemName: "checkmark").foregroundColor(.accentColor)
                        }
                    }
                }
            }
            if scanner.state == .poweredOn && bleDevices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning…").foregroundColor(.secondary)
                }
            }
            Toggle("Show all BLE devices", isOn: $showAll)
        } header: {
            Text("Bluetooth LE")
        } footer: {
            Text("vLinker FS/MC+ (BLE), iCar Pro BLE and other ELM327 BLE adapters. Plug the adapter in and switch the ignition on. Classic Bluetooth (SPP) adapters cannot be used by iOS apps.")
        }
    }

    private var bluetoothStateText: String {
        switch scanner.state {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied – enable it in Settings → EcuTweaker"
        case .unsupported: return "Bluetooth LE not supported"
        default: return "Waiting for Bluetooth…"
        }
    }

    // MARK: MFi

    @ViewBuilder private var mfiSection: some View {
        let _ = mfiRefresh
        let compatible = MFiSupport.compatibleAccessories()
        Section {
            ForEach(compatible, id: \.connectionID) { acc in
                Button {
                    conn.selectMFi(serial: acc.serialNumber.isEmpty ? nil : acc.serialNumber, name: acc.name)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(acc.name).foregroundColor(.primary)
                        Text("\(acc.manufacturer) \(acc.modelNumber) • fw \(acc.firmwareRevision)")
                            .font(.caption).foregroundColor(.secondary)
                        Text(acc.protocolStrings.joined(separator: ", ")).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            if compatible.isEmpty {
                Text("No compatible MFi accessory connected").foregroundColor(.secondary)
            }
            Button {
                MFiSupport.showPairingPicker { error in
                    pairMessage = error
                    mfiRefresh += 1
                }
            } label: {
                Label("Pair Bluetooth accessory…", systemImage: "plus.circle")
            }
            Button {
                mfiRefresh += 1
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            if let pairMessage {
                Text(pairMessage).font(.footnote).foregroundColor(.red)
            }
        } header: {
            Text("MFi accessories")
        } footer: {
            Text("Adapters with Apple MFi certification (e.g. vLinker FS/MC+ for iOS). Pair it once here or in iOS Settings → Bluetooth.")
        }

        Section {
            ForEach(MFiSupport.declaredProtocols, id: \.self) { p in
                Text(p).font(.system(.footnote, design: .monospaced))
            }
            let all = MFiSupport.connectedAccessories
            if all.isEmpty {
                Text("iOS reports no accessory to this app").font(.footnote).foregroundColor(.secondary)
            }
            ForEach(all, id: \.connectionID) { acc in
                VStack(alignment: .leading) {
                    Text("\(acc.name) (\(acc.manufacturer))").font(.footnote)
                    Text(acc.protocolStrings.isEmpty ? "no protocols" : acc.protocolStrings.joined(separator: ", "))
                        .font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Diagnostics – declared protocols")
        } footer: {
            Text("iOS only lets the app see MFi accessories whose protocol string is listed in Info.plist (UISupportedExternalAccessoryProtocols). If your adapter does not show up, its protocol string is missing from this list – see README.")
        }
    }

    // MARK: Wi-Fi

    @ViewBuilder private var wifiSection: some View {
        Section {
            TextField("IP address", text: $conn.wifiHost)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", value: $conn.wifiPort, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            Button {
                conn.connect(manual: true)
                dismiss()
            } label: {
                Label("Connect", systemImage: "bolt.horizontal.circle")
            }
        } header: {
            Text("ELM327 Wi-Fi")
        } footer: {
            Text("Join the adapter's Wi-Fi network in iOS Settings first. Default: 192.168.0.10, port 35000.")
        }
    }
}
