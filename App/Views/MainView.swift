import SwiftUI
import UniformTypeIdentifiers

/// MainActivity: adapter, vehicle project, ECU types, log.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var conn: ConnectionManager
    @State var showDevices = false
    @State var showImporter = false
    @State var search = ""

    private var filteredFunctions: [String] {
        search.isEmpty ? model.functions : model.functions.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder
    private var databaseSections: some View {
        switch model.dbState {
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Indexing database…")
                }
            }
        case .missing:
            Section("Database") {
                DatabaseMissingView(showImporter: $showImporter)
            }
        case .failed(let error):
            Section("Database") {
                Text(error).foregroundColor(.red)
                Button("Import ecu.zip…") { showImporter = true }
            }
        case .ready:
            Section("Vehicle") {
                NavigationLink {
                    ModelPickerView()
                } label: {
                    HStack {
                        Text("Project")
                        Spacer()
                        Text(model.projectName.isEmpty ? "All" : model.projectName)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Section("ECU type (\(filteredFunctions.count))") {
                ForEach(filteredFunctions, id: \.self) { f in
                    NavigationLink(value: Route.function(f)) { Text(f) }
                }
            }
        }
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })
    }

    var body: some View {
        List {
            Section("Adapter") {
                ConnectionRow(showDevices: $showDevices)
            }

            databaseSections

            Section {
                NavigationLink {
                    LogView()
                } label: {
                    Label("Log", systemImage: "text.alignleft")
                }
            }
        }
        .searchable(text: $search, prompt: "Search ECU type")
        .navigationTitle("EcuTweaker")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showImporter = true } label: { Label("Import ecu.zip…", systemImage: "square.and.arrow.down") }
                    Button { Task { await model.loadDatabase() } } label: { Label("Reload database", systemImage: "arrow.clockwise") }
                    if model.dbState == .ready {
                        Text("\(model.ecuCount) files in ecu.zip")
                    }
                    Text("Version \(AppInfo.version)")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showDevices) {
            DevicePickerView()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType.zip]) { result in
            if case .success(let url) = result {
                Task { await model.importDatabase(from: url) }
            }
        }
        .alert("Import failed", isPresented: importErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importError ?? "")
        }
    }
}

struct ConnectionRow: View {
    @EnvironmentObject var conn: ConnectionManager
    @Binding var showDevices: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Link", selection: $conn.mode) {
                ForEach(LinkMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Circle().fill(conn.state.color).frame(width: 10, height: 10)
                Text(conn.state.label).font(.subheadline)
                Spacer()
                Text(conn.isConnected ? (conn.deviceName ?? conn.selectedDeviceDescription) : conn.selectedDeviceDescription)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Button {
                    showDevices = true
                } label: {
                    Label("Choose device", systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
                Spacer()
                if conn.isConnected || conn.isConnecting || conn.wantsConnection {
                    Button(role: .destructive) {
                        conn.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        conn.connect()
                    } label: {
                        Label("Connect", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!conn.hasDevice)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DatabaseMissingView: View {
    @Binding var showImporter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ecu.zip not found").font(.headline)
            Text("EcuTweaker needs the DDT4All database (ecu.zip, JSON version). Either:")
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                Text("• import it from Files, iCloud Drive, Downloads…")
                Text("• or copy it to Files → On My iPhone → EcuTweaker (also from a PC via Apple Devices / iTunes → File Sharing)")
                Text("• or use Share → EcuTweaker on the file")
            }
            .font(.footnote)
            .foregroundColor(.secondary)
            Button {
                showImporter = true
            } label: {
                Label("Import ecu.zip…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }
}

/// MainActivity.chooseProject
struct ModelPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var search = ""

    var body: some View {
        let models = model.models.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        List(models, id: \.self) { m in
            Button {
                model.selectModel(m)
                dismiss()
            } label: {
                HStack {
                    Text(m).foregroundColor(.primary)
                    Spacer()
                    if m == model.projectName { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                }
            }
        }
        .searchable(text: $search, prompt: "Search vehicle")
        .navigationTitle("Choose project")
    }
}
