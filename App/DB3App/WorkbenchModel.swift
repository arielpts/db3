import AppKit
import Foundation
import Observation
import DB3Core

@MainActor @Observable
final class WorkbenchModel {
    var worksheets = [Worksheet()]
    var selectedID: UUID?
    var profiles: [ConnectionProfile] = []
    var showingConnection = false
    var showingInspector = false
    var editingProfile: ConnectionProfile?
    var error: String?
    var closingWorksheet: Worksheet?
    @ObservationIgnored let persistence = LocalPersistence()
    var active: Worksheet { worksheets.first(where: { $0.id == selectedID }) ?? worksheets[0] }
    var hasUnfinishedWork: Bool { worksheets.contains { $0.isBusy || $0.transaction == .inTransaction || $0.transaction == .failed } }
    init() { selectedID = worksheets[0].id }

    func load() async {
        do { profiles = try await persistence.loadProfiles() }
        catch { self.error = "Could not load connection profiles: \(error.localizedDescription)" }
    }
    func addWorksheet() {
        guard worksheets.count < 4 else { error = "This scaffold supports four pinned worksheet sessions. Close a worksheet before opening another."; return }
        let sheet = Worksheet(title: "Query \(worksheets.count + 1)")
        worksheets.append(sheet); selectedID = sheet.id
    }
    func newConnection() { editingProfile = nil; showingConnection = true }
    func editConnection(_ profile: ConnectionProfile) { editingProfile = profile; showingConnection = true }
    func connectSaved(_ profile: ConnectionProfile) {
        let sheet = active
        guard !sheet.isBusy else { return }
        if sheet.transaction == .inTransaction || sheet.transaction == .failed { error = "Commit or roll back the current transaction before changing connections."; return }
        Task {
            do { sheet.connect(profile, password: try await persistence.password(for: profile.id)) }
            catch { self.error = error.localizedDescription }
        }
    }
    func saveAndConnect(profile: ConnectionProfile, password: String, remember: Bool) async throws {
        let sheet = active
        guard !sheet.isBusy, sheet.transaction != .inTransaction, sheet.transaction != .failed else { throw DatabaseError("Finish the active query or transaction before changing connections.") }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile } else { updated.append(profile) }
        if remember { try await persistence.savePassword(password, for: profile.id) }
        else { try await persistence.savePassword("", for: profile.id) }
        try await persistence.saveProfiles(updated)
        profiles = updated
        sheet.connect(profile, password: password)
    }
    func sample() {
        guard !active.isBusy, active.transaction != .inTransaction, active.transaction != .failed else { return }
        active.sql = "-- Sample workspace · generated locally, no PostgreSQL server\n-- Press Run to inspect 10,000 sample rows.\nSELECT * FROM sample_customers;"
        active.connect(ConnectionProfile(name: "Sample workspace"), password: "", demo: true)
    }
    func requestClose(_ sheet: Worksheet) {
        if sheet.isBusy || sheet.transaction == .inTransaction || sheet.transaction == .failed { closingWorksheet = sheet }
        else { close(sheet) }
    }
    func close(_ sheet: Worksheet) {
        sheet.prepareToClose()
        Task {
            await sheet.close()
            worksheets.removeAll { $0.id == sheet.id }
            if worksheets.isEmpty { worksheets.append(Worksheet()) }
            if selectedID == sheet.id { selectedID = worksheets[0].id }
        }
    }
    func shutdown() async { for sheet in worksheets { await sheet.close() } }
    func openSQL() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .data]; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let sheet = self.active
            Task {
                do { sheet.sql = try await self.persistence.readSQL(at: url); sheet.title = url.lastPathComponent }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    func saveSQL() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = active.title.hasSuffix(".sql") ? active.title : active.title + ".sql"
        let sql = active.sql
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { do { try await self.persistence.writeSQL(sql, at: url) } catch { self.error = error.localizedDescription } }
        }
    }
    func exportCSV() {
        let sheet = active
        let panel = NSSavePanel(); panel.nameFieldStringValue = "results.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            sheet.exportCSV(to: url)
        }
    }
}
