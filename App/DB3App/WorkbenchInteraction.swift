import AppKit
import Foundation
import DB3Core

/// Value snapshots form the task 05 boundary; browser selection never mutates a query.
struct QueryOpeningContext: Equatable, Sendable {
    let profile: ConnectionProfile?
    let database: String?
    let schema: String?
    let object: String?

    init(profile: ConnectionProfile?, database: String? = nil, schema: String? = nil, object: String? = nil) {
        var snapshot = profile
        if let database { snapshot?.database = database }
        self.profile = snapshot
        self.database = database ?? profile?.database
        self.schema = schema
        self.object = object
    }
}

protocol WorkbenchPersistence: Sendable {
    func loadProfiles() async throws -> [ConnectionProfile]
    func saveProfiles(_ profiles: [ConnectionProfile]) async throws
    func password(for id: UUID) async throws -> String
    func savePassword(_ password: String, for id: UUID) async throws
    func readSQL(at url: URL) async throws -> String
    func writeSQL(_ sql: String, at url: URL) async throws
}

struct ConnectionEditTarget: Equatable {
    let worksheetID: UUID
    let intent: UUID
}

/// A one-use credential request contains context only, never the password.
struct WorksheetCredentialRequest: Identifiable, Equatable {
    let id = UUID()
    let profile: ConnectionProfile
    let target: ConnectionEditTarget
}

enum WorksheetCloseDecision { case save, discard, keepOpen, reviewGrid }

struct WorksheetCloseSnapshot: Equatable {
    let id: UUID
    let title: String
    let documentRevision: UInt64
    let isDirty: Bool
    let isBusy: Bool
    let isSaving: Bool
    let isCancelling: Bool
    let transaction: TransactionState
    let activityGeneration: UUID
    let preservesDraft: Bool
    let pendingGridCells: Int
    let hasActiveCellEditor: Bool
    let gridDraftRevision: UInt64

    @MainActor init(_ sheet: Worksheet, preservingDraft: Bool = false) {
        id = sheet.id; title = sheet.title; documentRevision = sheet.documentRevision
        isDirty = sheet.isDirty && !preservingDraft; isBusy = sheet.isBusy; isSaving = sheet.isSaving; isCancelling = sheet.isCancelling
        transaction = sheet.transaction; activityGeneration = sheet.activityGeneration
        preservesDraft = preservingDraft
        pendingGridCells = sheet.changedCellCount; hasActiveCellEditor = sheet.hasActiveCellEditor || sheet.lookup != nil
        gridDraftRevision = sheet.draftRevision
    }
    var hasGridDrafts: Bool { pendingGridCells > 0 || hasActiveCellEditor }
    var needsDecision: Bool { isDirty || isBusy || isSaving || hasGridDrafts || transaction == .inTransaction || transaction == .failed }
}

/// Injectable UI boundary: model/lifecycle tests never open dialogs or access Keychain.
@MainActor
protocol WorkbenchDialogs {
    func chooseOpenSQL() async -> URL?
    func chooseSaveSQL(title: String, currentURL: URL?) async -> URL?
    func chooseExportCSV() async -> URL?
    func confirmClose(_ snapshot: WorksheetCloseSnapshot) async -> WorksheetCloseDecision
}

@MainActor
struct NativeWorkbenchDialogs: WorkbenchDialogs {
    func chooseOpenSQL() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .data]; panel.allowsMultipleSelection = false
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
    func chooseSaveSQL(title: String, currentURL: URL?) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = currentURL?.lastPathComponent ?? (title.hasSuffix(".sql") ? title : title + ".sql")
        panel.directoryURL = currentURL?.deletingLastPathComponent()
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
    func chooseExportCSV() async -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "results.csv"
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
    func confirmClose(_ snapshot: WorksheetCloseSnapshot) async -> WorksheetCloseDecision {
        let alert = NSAlert()
        let hasTransaction = snapshot.transaction == .inTransaction || snapshot.transaction == .failed
        alert.messageText = hasTransaction ? "Uncommitted transaction in “\(snapshot.title)”" : "Close “\(snapshot.title)”?"
        if hasTransaction { alert.alertStyle = .warning }
        var consequences: [String] = []
        if snapshot.preservesDraft { consequences.append("Your SQL and tabs will be preserved for the next launch.") }
        if snapshot.isDirty { consequences.append("This query has unsaved SQL changes.") }
        if snapshot.isBusy { consequences.append("Running work will be cancelled. A statement already sent to the server may have completed.") }
        if snapshot.isSaving { consequences.append("Wait for the current save to finish before closing this query.") }
        if snapshot.hasGridDrafts { consequences.append("There are unsaved database-value drafts or an active cell editor. These values are memory-only and will be discarded on close. Preview and Apply does not commit a Manual-mode transaction.") }
        if hasTransaction {
            consequences.append("The open transaction will be rolled back when this session disconnects.")
        }
        alert.informativeText = consequences.joined(separator: "\n\n")
        if snapshot.hasGridDrafts {
            alert.addButton(withTitle: "Preview Changes")
            alert.addButton(withTitle: "Keep Open")
            alert.addButton(withTitle: hasTransaction ? "Discard Drafts, Roll Back and Close" : "Discard Changes and Close")
        } else if snapshot.isDirty {
            alert.addButton(withTitle: "Save and Close")
            alert.addButton(withTitle: "Keep Open")
            alert.addButton(withTitle: "Close Without Saving")
        } else {
            alert.addButton(withTitle: hasTransaction ? "Roll Back and Close" : "Close Query")
            alert.addButton(withTitle: "Keep Open")
        }
        if hasTransaction {
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { response = await alert.beginSheetModal(for: window) }
        else { return .keepOpen }
        if snapshot.hasGridDrafts {
            if response == .alertFirstButtonReturn { return .reviewGrid }
            return response == .alertThirdButtonReturn ? .discard : .keepOpen
        }
        if response == .alertFirstButtonReturn { return snapshot.isDirty ? .save : .discard }
        if snapshot.isDirty, response == .alertThirdButtonReturn { return .discard }
        return .keepOpen
    }
}
