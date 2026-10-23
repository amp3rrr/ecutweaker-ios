import SwiftUI
import UIKit

/// Full-screen log with copy / share / clear (MainActivity view-log & clear-log buttons).
struct LogView: View {
    @EnvironmentObject var log: LogStore
    @EnvironmentObject var conn: ConnectionManager
    @State var confirmClear = false

    var body: some View {
        LogLines(lines: log.lines, fontSize: 12)
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = log.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    ShareLink(item: AppPaths.logFile) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .confirmationDialog("Delete the log?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete log", role: .destructive) {
                    log.clear()
                    conn.session.resetLogFile()
                }
            }
    }
}

/// Compact log panel shown under a screen (the green log view).
struct LogPanel: View {
    @EnvironmentObject var log: LogStore

    var body: some View {
        LogLines(lines: Array(log.lines.suffix(300)), fontSize: 10)
            .background(Color(.systemGroupedBackground))
    }
}

struct LogLines: View {
    let lines: [String]
    let fontSize: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: fontSize, design: .monospaced))
                            .foregroundColor(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(6)
                .textSelection(.enabled)
            }
            .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            .onChange(of: lines.count) { n in
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("Negative response") || line.contains("ERROR") || line.contains("Bad response") || line.contains("exception") {
            return .red
        }
        if line.hasPrefix("ECU match") || line.contains("DTC cleared") { return .green }
        if line.hasPrefix("ELM manager") { return .secondary }
        return .primary
    }
}
