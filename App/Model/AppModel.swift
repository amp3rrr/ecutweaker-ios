import Foundation
import SwiftUI

/// App-wide state: the ECU database (ecu.zip + bundled projects.json), the selected
/// vehicle project and the connection. Mirrors MainActivity's non-UI responsibilities.
@MainActor
final class AppModel: ObservableObject {
    enum DBState: Equatable {
        case loading
        case missing
        case ready
        case failed(String)
    }

    @Published private(set) var dbState: DBState = .loading
    @Published private(set) var projectCode: String = UserDefaults.standard.string(forKey: "project") ?? ""
    @Published private(set) var projectName: String = ""
    @Published private(set) var functions: [String] = []
    @Published private(set) var ecuCount = 0
    @Published var importError: String?

    let log: LogStore
    let connection: ConnectionManager
    private(set) var database: EcuDatabase?

    init() {
        let log = LogStore()
        self.log = log
        connection = ConnectionManager(log: log)
        log.append("EcuTweaker iOS \(AppInfo.version)")
        Task { await loadDatabase() }
    }

    // MARK: - Database

    func loadDatabase() async {
        dbState = .loading
        database = nil
        guard let zipURL = AppPaths.findEcuZip() else {
            dbState = .missing
            log.append("Database not found: put ecu.zip in Files → On My iPhone → EcuTweaker, or import it")
            return
        }
        log.append("Indexing database \(zipURL.lastPathComponent)…")
        let code = projectCode
        do {
            let db = try await Task.detached(priority: .userInitiated) { () throws -> EcuDatabase in
                guard let url = Bundle.main.url(forResource: "projects", withExtension: "json") else {
                    throw EcuError.database("projects.json missing from the app bundle")
                }
                let db = try EcuDatabase(projectsJSON: Data(contentsOf: url))
                try db.loadDatabase(zipPath: zipURL.path)
                db.buildMaps(code)
                return db
            }.value
            database = db
            ecuCount = db.zip?.count ?? 0
            refreshProject()
            dbState = .ready
            log.append("Loaded vehicle Name: \(db.currentProjectName)")
        } catch {
            dbState = .failed(String(describing: error))
            log.append("Database exception : \(error)")
        }
    }

    /// Copies a user-picked or "Open in…" ecu.zip into Documents and reloads.
    func importDatabase(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let dest = AppPaths.ecuZip
        do {
            if url.standardizedFileURL.path != dest.standardizedFileURL.path {
                let tmp = AppPaths.documents.appendingPathComponent(".ecu-import.zip")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: url, to: tmp)
                let check = try ZipFileSystem(path: tmp.path)
                guard check.fileExists("db.json") else {
                    try? fm.removeItem(at: tmp)
                    throw EcuError.database("This ZIP does not contain db.json – it is not a DDT4All ecu.zip")
                }
                database = nil
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
                if url.path.contains("/Inbox/") { try? fm.removeItem(at: url) }
            }
            log.append("Database imported")
            await loadDatabase()
        } catch {
            importError = String(describing: error)
            log.append("Import failed : \(error)")
        }
    }

    // MARK: - Project (vehicle model)

    var models: [String] { database?.models ?? [] }

    func selectModel(_ model: String) {
        guard let db = database else { return }
        projectCode = db.selectModel(model)
        UserDefaults.standard.set(projectCode, forKey: "project")
        refreshProject()
        log.append("Loaded vehicle Name: \(db.currentProjectName)")
    }

    private func refreshProject() {
        guard let db = database else { return }
        projectName = db.currentProjectName
        functions = db.ecuFunctions(project: projectCode)
    }

    // MARK: - ECU helpers

    func address(forFunction f: String) -> Int? { database?.address(forFunction: f) }

    func ecus(forFunction f: String) -> [EcuDatabase.EcuInfo] {
        guard let db = database, let a = db.address(forFunction: f) else { return [] }
        return db.ecuInfos(address: a, project: projectCode)
    }
}
