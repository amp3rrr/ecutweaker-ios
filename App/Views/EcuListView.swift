import SwiftUI

@MainActor
final class ScanViewModel: ObservableObject {
    @Published private(set) var ecus: [EcuDatabase.EcuInfo] = []
    @Published private(set) var results: [EcuDatabase.IdentResult] = []
    @Published private(set) var fields = ScanController.IdentFields()
    @Published private(set) var scanning = false

    private var controller: ScanController?
    private var token: UUID?
    private weak var connection: ConnectionManager?

    func attach(model: AppModel, function: String) {
        connection = model.connection
        ecus = model.ecus(forFunction: function)
        if controller == nil, let db = model.database, let address = model.address(forFunction: function) {
            let c = ScanController(database: db, session: model.connection.session, address: address)
            let log = model.log
            c.onLog = { log.append($0) }
            c.onChange = { [weak self] in self?.sync() }
            controller = c
        }
        token = model.connection.attach { [weak self] e in self?.controller?.handle(e) }
    }

    func detach() {
        if let token { connection?.detach(token) }
        token = nil
    }

    func scanCAN() { controller?.scanCAN(); sync() }
    func scanKWP() { controller?.scanKWP(); sync() }
    func cancel() { controller?.cancel(); sync() }

    func result(for info: EcuDatabase.EcuInfo) -> EcuDatabase.IdentResult? {
        results.first { $0.info.href == info.href }
    }

    var addressText: String {
        guard let a = controller?.address else { return "" }
        return String(format: "0x%02X", a)
    }

    private func sync() {
        guard let c = controller else { return }
        results = c.results
        fields = c.fields
        scanning = c.isScanning
    }
}

/// MainActivity's second list: ECU files for the selected function + auto-identification.
struct EcuListView: View {
    let function: String
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var conn: ConnectionManager
    @StateObject var vm = ScanViewModel()
    @State var showBusChoice = false
    @State var search = ""

    var body: some View {
        let list = vm.ecus.filter { search.isEmpty || $0.ecuName.localizedCaseInsensitiveContains(search) }
        List {
            if !vm.results.isEmpty || vm.fields != ScanController.IdentFields() {
                Section("Identification") {
                    identRow("Supplier", vm.fields.supplier)
                    identRow("Diag version", vm.fields.diagVersion)
                    identRow("Soft", vm.fields.soft)
                    identRow("Version", vm.fields.version)
                    ForEach(vm.results, id: \.info.href) { r in
                        NavigationLink(value: Route.screen(href: r.info.href, name: r.info.ecuName)) {
                            Label(r.info.ecuName, systemImage: r.exact ? "checkmark.seal.fill" : "questionmark.diamond.fill")
                                .foregroundColor(r.exact ? .green : .orange)
                        }
                    }
                    if !vm.scanning && vm.results.isEmpty {
                        Text("No relevant ECU file found").foregroundColor(.red)
                    }
                }
            }
            Section("ECU files (\(list.count)) – address \(vm.addressText)") {
                ForEach(list) { info in
                    NavigationLink(value: Route.screen(href: info.href, name: info.ecuName)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.ecuName)
                                Text("\(info.protocolName) • \(info.href)").font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            if let r = vm.result(for: info) {
                                Image(systemName: r.exact ? "checkmark.seal.fill" : "questionmark.diamond.fill")
                                    .foregroundColor(r.exact ? .green : .orange)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Filter ECU files")
        .navigationTitle(function)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.scanning {
                    Button {
                        vm.cancel()
                    } label: {
                        HStack(spacing: 6) { ProgressView(); Text("Cancel") }
                    }
                } else {
                    Button {
                        showBusChoice = true
                    } label: {
                        Label("Scan", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(!conn.isConnected)
                }
            }
        }
        .confirmationDialog("Select bus", isPresented: $showBusChoice, titleVisibility: .visible) {
            Button("CAN") { vm.scanCAN() }
            Button("KWP2000") { vm.scanKWP() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Auto-identify the ECU at \(vm.addressText)")
        }
        .onAppear { vm.attach(model: model, function: function) }
        .onDisappear { vm.detach() }
    }

    private func identRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.isEmpty ? "—" : value).foregroundColor(.secondary).textSelection(.enabled)
        }
    }
}
