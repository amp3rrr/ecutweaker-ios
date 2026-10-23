import SwiftUI
import UIKit

/// ScreenActivity: renders a DDT screen, toolbar with screens / reload / auto / DTC / settings.
struct ScreenView: View {
    let href: String
    let title: String

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var conn: ConnectionManager
    @StateObject var vm = ScreenViewModel()

    @State var showScreens = false
    @State var showSettings = false
    @State var confirmClear = false
    @State var showLog = true
    @AppStorage("screenZoom") var zoom: Double = 0          // 0 = fit width
    @AppStorage("fontScale") var fontScale: Double = 100     // PREF_FONT_SCALE (%)
    @GestureState var pinch: CGFloat = 1

    var body: some View {
        mainContent
            .navigationTitle(vm.screenName ?? title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showScreens) {
                ScreenChooser(vm: vm, onSelect: { name in vm.draw(name) })
            }
            .sheet(isPresented: $showSettings) {
                ScreenSettingsView(vm: vm, fontScale: $fontScale)
            }
            .sheet(item: $vm.dtcReport) { report in
                DTCReportView(report: report)
            }
            .confirmationDialog("Clear all DTCs?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear all DTC", role: .destructive) { vm.clearDTC() }
                Button("Cancel", role: .cancel) {}
            }
            .alert(vm.alertText ?? "", isPresented: alertBinding) {
                Button("OK", role: .cancel) {}
            }
            .onAppear {
                vm.open(model: model, href: href)
                if vm.screen == nil && vm.openError == nil { showScreens = true }
            }
            .onDisappear { vm.close() }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { vm.alertText != nil }, set: { if !$0 { vm.alertText = nil } })
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            screenArea
            if showLog {
                Divider()
                LogPanel()
                    .frame(height: 130)
            }
        }
    }

    @ViewBuilder
    private var screenArea: some View {
        if let error = vm.openError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                Text(error).multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let screen = vm.screen {
            GeometryReader { geo in
                canvas(screen: screen, width: geo.size.width)
            }
        } else {
            VStack(spacing: 14) {
                Text(vm.ecuName).font(.headline)
                Button {
                    showScreens = true
                } label: {
                    Label("Choose a screen", systemImage: "rectangle.stack")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func canvas(screen: Layout.ScreenData, width: CGFloat) -> some View {
        let fit: CGFloat = max(0.05, (width - 8) / max(CGFloat(screen.width) / 8, 1))
        let base: CGFloat = zoom > 0 ? CGFloat(zoom) : fit
        let magnification = MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in zoom = Double(min(max(base * value, 0.05), 6)) }
        return ScrollView([.horizontal, .vertical]) {
            ScreenCanvas(vm: vm, screen: screen, zoom: base * pinch, fontScale: CGFloat(fontScale) / 100)
                .padding(4)
        }
        .simultaneousGesture(magnification)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 6) {
                if vm.busy { ProgressView().scaleEffect(0.7) }
                Circle().fill(conn.state.color).frame(width: 10, height: 10)
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { showScreens = true } label: { Image(systemName: "rectangle.stack") }
            Spacer()
            Button { vm.reload() } label: { Image(systemName: "arrow.clockwise") }
            Spacer()
            Button { vm.toggleAutoReload() } label: {
                Image(systemName: vm.autoReload ? "repeat.circle.fill" : "repeat")
                    .foregroundColor(vm.autoReload ? .green : .accentColor)
            }
            Spacer()
            dtcMenu
            Spacer()
            moreMenu
        }
    }

    private var dtcMenu: some View {
        Menu {
            Button { vm.readDTC() } label: { Label("Read DTC", systemImage: "exclamationmark.triangle") }
            Button(role: .destructive) { confirmClear = true } label: { Label("Clear all DTC", systemImage: "trash") }
        } label: {
            Image(systemName: "stethoscope")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { zoom = Double(currentZoomGuess * 1.25) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
            Button { zoom = Double(max(currentZoomGuess / 1.25, 0.05)) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
            Button { zoom = 0 } label: { Label("Fit width", systemImage: "arrow.left.and.right") }
            Button { showLog.toggle() } label: { Label(showLog ? "Hide log" : "Show log", systemImage: "text.alignleft") }
            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// Zoom used when "fit" is active, approximated for the +/- buttons.
    private var currentZoomGuess: CGFloat {
        if zoom > 0 { return CGFloat(zoom) }
        guard let w = vm.screen?.width, w > 0 else { return 0.35 }
        return UIScreen.main.bounds.width / (CGFloat(w) / 8)
    }
}

/// chooseCategory + chooseScreen
struct ScreenChooser: View {
    @ObservedObject var vm: ScreenViewModel
    let onSelect: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.categories, id: \.self) { category in
                    let screens = vm.screens(in: category).filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
                    if !screens.isEmpty {
                        Section(category) {
                            ForEach(screens, id: \.self) { name in
                                Button {
                                    onSelect(name)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(name).foregroundColor(.primary)
                                        Spacer()
                                        if name == vm.screenName { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                                    }
                                }
                            }
                        }
                    }
                }
                if vm.categories.isEmpty {
                    Text("This ECU file has no screen layout").foregroundColor(.secondary)
                }
            }
            .searchable(text: $search, prompt: "Search screen")
            .navigationTitle(vm.ecuName.isEmpty ? "Screens" : vm.ecuName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}

/// can_settings.xml: soft flow control, CAN timeout, default diag session, font size.
struct ScreenSettingsView: View {
    @ObservedObject var vm: ScreenViewModel
    @Binding var fontScale: Double
    @Environment(\.dismiss) var dismiss
    @State var softFlow = false
    @State var timeout = 0.0
    @State var sds = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Soft flow control (CFC0)", isOn: $softFlow)
                } footer: {
                    Text("Software ISO-TP flow control, for adapters/ECUs that fail multi-frame transfers.")
                }
                Section("CAN timeout: \(Int(timeout)) ms") {
                    Slider(value: $timeout, in: 0...1020, step: 4)
                }
                Section {
                    Picker("Diagnostic session", selection: $sds) {
                        Text("Default (\(vm.defaultSDS))").tag("")
                        ForEach(vm.sdsNames, id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text("Default diagnostic session")
                }
                Section("Font size: \(Int(fontScale)) %") {
                    Slider(value: $fontScale, in: 20...200, step: 5)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        vm.applySettings(canTimeout: Int(timeout), softFlowControl: softFlow, sdsName: sds.isEmpty ? nil : sds)
                        dismiss()
                    }
                }
            }
            .onAppear {
                softFlow = vm.softFlowControl
                timeout = Double(vm.canTimeout)
            }
        }
    }
}

struct DTCReportView: View {
    let report: DTCReport
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(report.items.enumerated()), id: \.offset) { i, lines in
                    Section("DTC #\(i + 1)") {
                        ForEach(lines, id: \.self) { line in
                            Text(line).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("DTC report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    ShareLink(item: report.items.enumerated().map { "DTC #\($0.offset + 1)\n" + $0.element.map { "* " + $0 }.joined(separator: "\n") }.joined(separator: "\n\n"))
                }
            }
        }
    }
}
