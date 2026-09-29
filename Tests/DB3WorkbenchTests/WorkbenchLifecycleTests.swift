import Foundation
import XCTest
import DB3Core
@testable import DB3Workbench

/// Exercise real application models with in-memory documents, scripted dialog
/// decisions, and isolated fake sessions. These tests never open native UI.
@MainActor
final class WorkbenchLifecycleTests: XCTestCase {
    func testUntitledAllocationAvoidsRenamesAndCapacityDoesNotMutateTabs() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active
        model.renameTab(first.id, to: "Query 2")
        model.addWorksheet()
        XCTAssertEqual(model.active.title, "Query 3")
        let removedID = model.active.id
        let closed = await model.closeTab(id: removedID)
        XCTAssertTrue(closed)
        model.addWorksheet()
        XCTAssertEqual(model.active.title, "Query 4")
        model.addWorksheet(); model.addWorksheet()
        let ids = model.worksheets.map(\.id)
        let selected = model.selectedID
        let sql = model.active.sql
        XCTAssertEqual(ids.count, 4)
        XCTAssertFalse(model.canAddWorksheet)
        model.addWorksheet()
        let refused = model.openQueryTab(context: QueryOpeningContext(profile: nil), sql: "SELECT forbidden", title: "No slot")
        XCTAssertNil(refused)
        XCTAssertEqual(model.worksheets.map(\.id), ids)
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertEqual(model.active.sql, sql)
        XCTAssertEqual(model.error, model.tabLimitMessage)
        XCTAssertEqual(Set(model.worksheets.map(\.title)).count, 4)
        await model.shutdown()
    }

    func testBrowserSelectionAndOpeningContextAreIndependentSnapshots() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let firstProfile = ConnectionProfile(name: "Original", host: "first.example", database: "first")
        let browserProfile = ConnectionProfile(name: "Browser", host: "second.example", database: "second")
        let first = model.active; first.profile = firstProfile
        model.profiles = [firstProfile, browserProfile]
        model.selectedBrowserProfileID = browserProfile.id
        XCTAssertEqual(first.profile, firstProfile)
        model.addWorksheet()
        let second = model.active
        XCTAssertEqual(second.profile, browserProfile)
        XCTAssertFalse(second.isConnected)
        model.selectTab(first.id)
        XCTAssertEqual(model.selectedBrowserProfileID, browserProfile.id)

        let context = QueryOpeningContext(profile: browserProfile, database: "captured_db", schema: "public", object: "orders")
        let generated = try XCTUnwrap(model.openQueryTab(context: context, sql: "SELECT * FROM public.orders;", title: "orders"))
        model.profiles[1].host = "edited.example"
        model.selectedBrowserProfileID = firstProfile.id
        XCTAssertEqual(generated.profile?.host, "second.example")
        XCTAssertEqual(generated.profile?.database, "captured_db")
        XCTAssertEqual(generated.queryContext, context)
        XCTAssertEqual(generated.queryContext?.schema, "public")
        XCTAssertTrue(generated.isDirty)
        XCTAssertFalse(generated.isConnected)
        let connections = await fixture.sessions[2].connections
        XCTAssertTrue(connections.isEmpty)
        model.selectedBrowserProfileID = nil
        model.selectTab(first.id); model.addWorksheet()
        XCTAssertEqual(model.active.profile, firstProfile)
        XCTAssertNotEqual(model.active.id, first.id)
        await model.shutdown()
    }

    func testSamplePreservesDirtyTargetAndDoesNothingAtCapacity() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let original = model.active
        let profile = ConnectionProfile(name: "Existing session", host: "original.example")
        original.connect(profile, password: "original-password")
        try await eventually { original.isConnected && !original.isBusy }
        original.sql = "SELECT 'unsaved work to preserve';"
        let originalIntent = original.connectionIntent
        let originalGeneration = original.activityGeneration
        model.sample(in: original)
        let sample = model.active
        XCTAssertEqual(model.worksheets.count, 2)
        XCTAssertNotEqual(sample.id, original.id)
        try await eventually { sample.isConnected && !sample.isBusy }
        XCTAssertTrue(sample.isDemo)
        XCTAssertTrue(sample.sql.contains("SELECT * FROM sample_customers;"))
        XCTAssertEqual(sample.profile?.name, "Sample workspace")
        XCTAssertEqual(original.sql, "SELECT 'unsaved work to preserve';")
        XCTAssertTrue(original.isDirty)
        XCTAssertTrue(original.isConnected)
        XCTAssertFalse(original.isDemo)
        XCTAssertEqual(original.profile, profile)
        XCTAssertEqual(original.connectionIntent, originalIntent)
        XCTAssertEqual(original.activityGeneration, originalGeneration)
        let originalConnections = await fixture.sessions[0].connections
        XCTAssertEqual(originalConnections, [.init(profile: profile, password: "original-password")])

        model.addWorksheet(); model.addWorksheet()
        let ids = model.worksheets.map(\.id)
        let selected = model.selectedID
        let texts = model.worksheets.map(\.sql)
        let intents = model.worksheets.map(\.connectionIntent)
        var counts: [Int] = []
        for session in fixture.sessions { counts.append(await session.connections.count) }
        model.sample(in: original)
        XCTAssertEqual(model.worksheets.map(\.id), ids)
        XCTAssertEqual(model.worksheets.map(\.sql), texts)
        XCTAssertEqual(model.worksheets.map(\.connectionIntent), intents)
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertEqual(model.error, model.tabLimitMessage)
        XCTAssertEqual(fixture.sessions.count, 4)
        for (index, session) in fixture.sessions.enumerated() {
            let count = await session.connections.count
            XCTAssertEqual(count, counts[index])
        }
        await model.shutdown()
    }

    func testReorderAndTabNavigationPreserveDocumentIdentity() async {
        let fixture = WorkbenchFixture(); let model = fixture.model
        model.addWorksheet(); model.addWorksheet()
        let original = model.worksheets
        original[0].sql = "SELECT 'one'"
        original[1].sql = "SELECT 'two'"
        original[2].sql = "SELECT 'three'"
        model.selectTab(original[1].id)
        model.moveTab(original[1].id, by: -1)
        XCTAssertEqual(model.worksheets.map(\.id), [original[1].id, original[0].id, original[2].id])
        XCTAssertEqual(model.selectedID, original[1].id)
        XCTAssertTrue(model.active === original[1])
        model.reorderTab(original[2].id, before: original[1].id)
        XCTAssertEqual(model.worksheets.map(\.id), [original[2].id, original[1].id, original[0].id])
        model.selectTab(at: 0)
        XCTAssertTrue(model.active === original[2])
        model.selectTab(at: 1)
        XCTAssertTrue(model.active === original[1])
        model.selectTab(at: 2)
        XCTAssertTrue(model.active === original[0])
        model.selectTab(at: 3)
        model.selectTab(at: -1)
        XCTAssertTrue(model.active === original[0])
        XCTAssertEqual(model.worksheets.count, 3)
        model.selectTab(original[0].id); model.selectAdjacentTab(1)
        XCTAssertEqual(model.selectedID, original[2].id)
        model.selectAdjacentTab(-1)
        XCTAssertEqual(model.selectedID, original[0].id)
        XCTAssertEqual(original.map(\.sql), ["SELECT 'one'", "SELECT 'two'", "SELECT 'three'"])
        await model.shutdown()
    }

    func testDirtyStateDependsOnlyOnSavedSQLAndInspectorSelectionBelongsToDocument() async {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let sheet = model.active; let baseline = sheet.sql
        XCTAssertFalse(sheet.isDirty)
        sheet.sql += "\n-- edited"
        XCTAssertTrue(sheet.isDirty)
        sheet.sql = baseline // Native editor undo publishes the baseline text.
        XCTAssertFalse(sheet.isDirty)
        sheet.rowCount = 9; sheet.resultTab = 1; sheet.selection = NSRange(location: 3, length: 4)
        sheet.status = "Complete"; sheet.transaction = .idle
        sheet.selectedValue = "long inspector value"
        sheet.inspectorSelection = NSRange(location: 5, length: 3)
        XCTAssertFalse(sheet.isDirty)
        model.addWorksheet(); model.active.selectedValue = "another value"
        model.selectTab(sheet.id)
        XCTAssertEqual(sheet.inspectorSelection, NSRange(location: 5, length: 3))
        sheet.selectedValue = "replacement"
        XCTAssertEqual(sheet.inspectorSelection, NSRange(location: 0, length: 0))
        sheet.setGeneratedSQL("SELECT 2;")
        XCTAssertTrue(sheet.isDirty)
        await model.shutdown()
    }

    func testSaveCapturesTabAndContentBeforePanelAndPreservesLaterEdits() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active; first.sql = "SELECT 'captured';"
        fixture.dialogs.holdSavePanel = true
        let save = Task { await model.saveSQL(sheet: first) }
        try await eventually { fixture.dialogs.savePanelTitles.count == 1 }
        model.addWorksheet(); let second = model.active; second.sql = "SELECT 'second';"
        first.sql = "SELECT 'later edit';"
        let destination = virtualURL("captured.sql")
        fixture.dialogs.finishSavePanel(destination)
        let saved = await save.value
        XCTAssertTrue(saved)
        let writes = await fixture.persistence.writes
        XCTAssertEqual(writes, [.init(sql: "SELECT 'captured';", url: destination)])
        XCTAssertEqual(first.fileURL, destination)
        XCTAssertEqual(first.savedSQL, "SELECT 'captured';")
        XCTAssertEqual(first.sql, "SELECT 'later edit';")
        XCTAssertTrue(first.isDirty)
        XCTAssertNil(second.fileURL)
        XCTAssertEqual(second.sql, "SELECT 'second';")
        XCTAssertTrue(model.active === second)
        await model.shutdown()
    }

    func testEditsDuringWriteRemainDirtyAndDuplicateFileSaveIsRejected() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let sheet = model.active; sheet.sql = "SELECT 'saved revision';"
        let destination = virtualURL("write.sql")
        await fixture.persistence.holdWrites()
        let save = Task { await model.saveSQL(sheet: sheet, to: destination) }
        try await eventually { await fixture.persistence.writes.count == 1 }
        sheet.sql = "SELECT 'new revision';"
        await fixture.persistence.finishWrites()
        let saved = await save.value
        XCTAssertTrue(saved)
        XCTAssertTrue(sheet.isDirty)
        sheet.sql = "SELECT 'saved revision';"
        XCTAssertFalse(sheet.isDirty)
        model.addWorksheet(); let second = model.active; second.sql = "SELECT 'other';"
        let duplicateSave = await model.saveSQL(sheet: second, to: destination)
        XCTAssertFalse(duplicateSave)
        XCTAssertNil(second.fileURL)
        let writes = await fixture.persistence.writes
        XCTAssertEqual(writes.count, 1)
        await model.shutdown()
    }

    func testOpenCreatesDocumentAndExistingFileSelectsAtCapacity() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active; first.sql = "SELECT 'keep me';"
        let file = virtualURL("open.sql")
        await fixture.persistence.setFile("SELECT 'from file';", at: file)
        let openedResult = await model.openSQL(at: file)
        let opened = try XCTUnwrap(openedResult)
        XCTAssertNotEqual(opened.id, first.id)
        XCTAssertEqual(first.sql, "SELECT 'keep me';")
        XCTAssertEqual(opened.sql, "SELECT 'from file';")
        XCTAssertFalse(opened.isDirty)
        XCTAssertEqual(opened.title, "open.sql")
        model.addWorksheet(); model.addWorksheet()
        let before = model.worksheets.map(\.id)
        let same = await model.openSQL(at: file.deletingLastPathComponent().appendingPathComponent("./open.sql"))
        XCTAssertTrue(same === opened)
        XCTAssertEqual(model.selectedID, opened.id)
        XCTAssertEqual(model.worksheets.map(\.id), before)
        let refused = await model.openSQL(at: virtualURL("overflow.sql"))
        XCTAssertNil(refused)
        let reads = await fixture.persistence.reads
        XCTAssertEqual(reads, [file])
        XCTAssertEqual(model.worksheets.map(\.id), before)
        await model.shutdown()
    }

    func testLateReadCannotPopulateClosedTabOrOverwriteChangedDocument() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active
        let closedFile = virtualURL("closed.sql")
        await fixture.persistence.holdRead(at: closedFile)
        let closedLoad = Task { await model.openSQL(at: closedFile) }
        try await eventually { await fixture.persistence.reads.contains(closedFile) }
        let loading = model.active
        XCTAssertTrue(loading.isLoading)
        XCTAssertFalse(loading.canIssueCommands)
        let closed = await model.closeTab(id: loading.id)
        XCTAssertTrue(closed)
        await fixture.persistence.finishRead(at: closedFile, text: "SELECT 'too late';")
        let discarded = await closedLoad.value
        XCTAssertNil(discarded)
        XCTAssertTrue(model.active === first)
        XCTAssertEqual(first.sql, Worksheet.starterSQL)

        let changedFile = virtualURL("changed.sql")
        await fixture.persistence.holdRead(at: changedFile)
        let changedLoad = Task { await model.openSQL(at: changedFile) }
        try await eventually { await fixture.persistence.reads.contains(changedFile) }
        let changed = model.active; changed.sql = "SELECT 'new local edit';"
        await fixture.persistence.finishRead(at: changedFile, text: "SELECT 'stale load';")
        _ = await changedLoad.value
        XCTAssertEqual(changed.sql, "SELECT 'new local edit';")
        XCTAssertTrue(changed.isDirty)
        XCTAssertFalse(changed.isLoading)
        XCTAssertNotNil(changed.error)
        XCTAssertNil(changed.fileURL)
        await model.shutdown()
    }

    func testReadFailureLeavesExistingSQLIntactAndLoadingSlotUsable() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let original = model.active; original.sql = "SELECT 'original';"
        let failedResult = await model.openSQL(at: virtualURL("missing.sql"))
        let failed = try XCTUnwrap(failedResult)
        XCTAssertEqual(original.sql, "SELECT 'original';")
        XCTAssertFalse(failed.isLoading)
        XCTAssertTrue(failed.canIssueCommands)
        XCTAssertNotNil(failed.error)
        XCTAssertNil(failed.fileURL)
        await model.shutdown()
    }

    func testNewerCredentialIntentSupersedesEarlierLookupOnSameTab() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let target = model.active
        let oldProfile = ConnectionProfile(name: "Old", host: "old.example")
        let newProfile = ConnectionProfile(name: "New", host: "new.example")
        await fixture.persistence.holdPassword(for: oldProfile.id)
        await fixture.persistence.holdPassword(for: newProfile.id)
        model.connectSaved(oldProfile, in: target)
        try await eventually { await fixture.persistence.passwordReads.contains(oldProfile.id) }
        model.connectSaved(newProfile, in: target)
        try await eventually { await fixture.persistence.passwordReads.contains(newProfile.id) }
        model.addWorksheet(); let other = model.active
        await fixture.persistence.finishPassword(for: newProfile.id, value: "new-password")
        try await eventually { target.isConnected && !target.isBusy }
        await fixture.persistence.finishPassword(for: oldProfile.id, value: "old-password")
        try await Task.sleep(for: .milliseconds(20))
        let connections = await fixture.sessions[0].connections
        XCTAssertEqual(connections, [.init(profile: newProfile, password: "new-password")])
        XCTAssertEqual(target.profile, newProfile)
        XCTAssertNil(other.profile)
        XCTAssertFalse(other.isConnected)
        XCTAssertTrue(model.active === other)
        await model.shutdown()
    }

    func testClosingDuringCredentialLookupPreventsLateConnection() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let sheet = model.active; let profile = ConnectionProfile(name: "Pending")
        await fixture.persistence.holdPassword(for: profile.id)
        model.connectSaved(profile, in: sheet)
        try await eventually { await fixture.persistence.passwordReads.contains(profile.id) }
        let closed = await model.closeTab(id: sheet.id)
        XCTAssertTrue(closed)
        await fixture.persistence.finishPassword(for: profile.id, value: "late-password")
        try await Task.sleep(for: .milliseconds(20))
        let connections = await fixture.sessions[0].connections
        XCTAssertTrue(connections.isEmpty)
        XCTAssertTrue(sheet.isClosed)
        XCTAssertNotEqual(model.active.id, sheet.id)
        XCTAssertFalse(model.active.isConnected)
        await model.shutdown()
    }

    func testConnectionEditorCapturesItsTabAndRejectsSupersededIntent() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let original = model.active
        let profile = ConnectionProfile(name: "Edited profile", host: "captured.example")
        model.editConnection(profile, in: original)
        let captured = try XCTUnwrap(model.connectionEditTarget)
        model.addWorksheet(); let other = model.active
        try await model.saveAndConnect(profile: profile, password: "captured-password", remember: false, target: captured)
        try await eventually { original.isConnected && !original.isBusy }
        XCTAssertEqual(original.profile, profile)
        XCTAssertNil(other.profile)
        XCTAssertFalse(other.isConnected)
        XCTAssertTrue(model.active === other)
        model.editConnection(profile, in: original)
        let superseded = try XCTUnwrap(model.connectionEditTarget)
        model.newConnection(in: original)
        do {
            try await model.saveAndConnect(profile: profile, password: "obsolete", remember: false, target: superseded)
            XCTFail("A superseded connection editor must not connect its old intent.")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
        let connections = await fixture.sessions[0].connections
        XCTAssertEqual(connections, [.init(profile: profile, password: "captured-password")])
        await model.shutdown()
    }

    func testCloseSelectsRightThenLeftAndFinalTabCreatesFreshDisconnectedQuery() async {
        let fixture = WorkbenchFixture(); let model = fixture.model
        model.addWorksheet(); model.addWorksheet(); model.addWorksheet()
        let sheets = model.worksheets
        model.selectTab(sheets[1].id)
        let inactiveClosed = await model.closeTab(id: sheets[0].id)
        XCTAssertTrue(inactiveClosed)
        XCTAssertEqual(model.selectedID, sheets[1].id)
        let middleClosed = await model.closeTab(id: sheets[1].id)
        XCTAssertTrue(middleClosed)
        XCTAssertEqual(model.selectedID, sheets[2].id)
        model.selectTab(sheets[3].id)
        let lastClosed = await model.closeTab(id: sheets[3].id)
        XCTAssertTrue(lastClosed)
        XCTAssertEqual(model.selectedID, sheets[2].id)
        let finalClosed = await model.closeTab(id: sheets[2].id)
        XCTAssertTrue(finalClosed)
        XCTAssertEqual(model.worksheets.count, 1)
        XCTAssertEqual(model.active.title, "Query 5")
        XCTAssertFalse(model.active.isConnected)
        XCTAssertNil(model.active.profile)
        XCTAssertFalse(model.active.isDirty)
        XCTAssertEqual(fixture.dialogs.snapshots.count, 0)
        await model.shutdown()
    }

    func testSaveCancellationAndFailureKeepDirtyTabAndSessionOpen() async {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let sheet = model.active; sheet.sql = "SELECT 'unsaved';"
        fixture.dialogs.closeDecisions = [.save]
        let cancelled = await model.closeTab(id: sheet.id)
        XCTAssertFalse(cancelled)
        XCTAssertTrue(model.active === sheet)
        XCTAssertFalse(sheet.isClosed)
        XCTAssertTrue(sheet.isDirty)
        XCTAssertFalse(sheet.isClosePending)
        fixture.dialogs.closeDecisions = [.save]
        fixture.dialogs.saveURL = virtualURL("failed-save.sql")
        await fixture.persistence.failWrites()
        let failed = await model.closeTab(id: sheet.id)
        XCTAssertFalse(failed)
        XCTAssertTrue(model.active === sheet)
        XCTAssertTrue(sheet.isDirty)
        XCTAssertNil(sheet.fileURL)
        XCTAssertFalse(sheet.isClosed)
        let disconnectCount = await fixture.sessions[0].disconnectCount
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertEqual(model.error, "Simulated write failure")
        await model.shutdown()
    }

    func testCloseRevalidatesEditsAndRejectsDuplicateCloseRequests() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let sheet = model.active; sheet.sql = "SELECT 'first draft';"
        fixture.dialogs.holdCloseDecision = true
        let close = Task { await model.closeTab(id: sheet.id) }
        try await eventually { fixture.dialogs.snapshots.count == 1 }
        XCTAssertTrue(sheet.isClosePending)
        XCTAssertFalse(sheet.canIssueCommands)
        let duplicate = await model.closeTab(id: sheet.id)
        XCTAssertFalse(duplicate)
        sheet.sql = "SELECT 'new draft';"
        fixture.dialogs.closeDecisions = [.keepOpen]
        fixture.dialogs.finishClose(.discard)
        let closed = await close.value
        XCTAssertFalse(closed)
        XCTAssertEqual(fixture.dialogs.snapshots.count, 2)
        XCTAssertNotEqual(fixture.dialogs.snapshots[0].documentRevision, fixture.dialogs.snapshots[1].documentRevision)
        XCTAssertEqual(sheet.sql, "SELECT 'new draft';")
        XCTAssertFalse(sheet.isClosed)
        XCTAssertFalse(sheet.isClosePending)
        let disconnectCount = await fixture.sessions[0].disconnectCount
        XCTAssertEqual(disconnectCount, 0)
        await model.shutdown()
    }

    func testCloseRechecksSQLChangedWhileItsSaveWasWriting() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let sheet = model.active; sheet.sql = "SELECT 'approved save';"
        fixture.dialogs.closeDecisions = [.save, .keepOpen]
        fixture.dialogs.saveURL = virtualURL("close-save.sql")
        await fixture.persistence.holdWrites()
        let close = Task { await model.closeTab(id: sheet.id) }
        try await eventually { await fixture.persistence.writes.count == 1 }
        XCTAssertTrue(sheet.isSaving)
        sheet.sql = "SELECT 'edit after decision';"
        await fixture.persistence.finishWrites()
        let closed = await close.value
        XCTAssertFalse(closed)
        XCTAssertFalse(sheet.isClosed)
        XCTAssertFalse(sheet.isSaving)
        XCTAssertEqual(sheet.savedSQL, "SELECT 'approved save';")
        XCTAssertEqual(sheet.sql, "SELECT 'edit after decision';")
        XCTAssertTrue(sheet.isDirty)
        XCTAssertEqual(fixture.dialogs.snapshots.count, 2)
        let disconnects = await fixture.sessions[0].disconnectCount
        XCTAssertEqual(disconnects, 0)
        await model.shutdown()
    }

    func testClosingBusyTabCancelsOnlyItsOwnedQueryAndFencesLateResults() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active
        first.connect(ConnectionProfile(name: "Running"), password: "test")
        try await eventually { first.isConnected && !first.isBusy }
        first.sql = "SELECT 'running';"
        await fixture.sessions[0].suspendExecution()
        first.run()
        try await eventually { await fixture.sessions[0].queries.count == 1 }
        model.addWorksheet(); let other = model.active
        fixture.dialogs.closeDecisions = [.discard]
        let closed = await model.closeTab(id: first.id)
        XCTAssertTrue(closed)
        XCTAssertTrue(first.isClosed)
        XCTAssertFalse(first.isConnected)
        XCTAssertFalse(first.isBusy)
        XCTAssertEqual(first.rowCount, 0)
        XCTAssertTrue(model.active === other)
        XCTAssertEqual(other.sql, Worksheet.starterSQL)
        XCTAssertEqual(other.rowCount, 0)
        XCTAssertEqual(fixture.dialogs.snapshots.count, 1)
        XCTAssertEqual(fixture.dialogs.snapshots[0].isBusy, true)
        let otherDisconnects = await fixture.sessions[1].disconnectCount
        XCTAssertEqual(otherDisconnects, 0)
        await model.shutdown()
    }

    func testWholeWorkspaceCancellationDoesNotPartiallyCloseApprovedTabs() async {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active; first.sql = "SELECT 'first';"; first.transaction = .failed
        model.addWorksheet(); let second = model.active; second.sql = "SELECT 'second';"; second.transaction = .inTransaction
        fixture.dialogs.closeDecisions = [.discard, .keepOpen]
        let cancelled = await model.requestCloseWorkspace()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(model.worksheets.map(\.id), [first.id, second.id])
        XCTAssertFalse(first.isClosed)
        XCTAssertFalse(second.isClosed)
        XCTAssertFalse(first.isClosePending)
        XCTAssertFalse(second.isClosePending)
        XCTAssertEqual(fixture.dialogs.snapshots.first?.transaction, .failed)
        let firstDisconnects = await fixture.sessions[0].disconnectCount
        let secondDisconnects = await fixture.sessions[1].disconnectCount
        XCTAssertEqual(firstDisconnects, 0)
        XCTAssertEqual(secondDisconnects, 0)
        fixture.dialogs.closeDecisions = [.discard, .discard]
        let closed = await model.requestCloseWorkspace()
        XCTAssertTrue(closed)
        XCTAssertTrue(model.worksheets.isEmpty)
        XCTAssertTrue(first.isClosed)
        XCTAssertTrue(second.isClosed)
        XCTAssertFalse(model.isCoordinatingClose)
    }

    func testSelectionDuringAwaitedCloseIsNotOverwrittenByOldSelection() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active
        model.addWorksheet(); let second = model.active
        model.addWorksheet(); let third = model.active
        model.selectTab(first.id)
        await fixture.sessions[0].suspendDisconnect()
        let close = Task { await model.closeTab(id: first.id) }
        try await eventually { first.isClosing }
        model.selectTab(third.id)
        model.moveTab(third.id, by: -1)
        await fixture.sessions[0].finishDisconnect()
        let closed = await close.value
        XCTAssertTrue(closed)
        XCTAssertEqual(model.selectedID, third.id)
        XCTAssertEqual(model.worksheets.map(\.id), [third.id, second.id])
        await model.shutdown()
    }

    func testInactiveQueryCompletesIntoItsOwnResultAndTabSwitchDoesNotReconnect() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active
        let firstProfile = ConnectionProfile(name: "First", host: "first.example")
        first.connect(firstProfile, password: "first-password")
        try await eventually { first.isConnected && !first.isBusy }
        model.addWorksheet(); let second = model.active
        let secondProfile = ConnectionProfile(name: "Second", host: "second.example")
        second.connect(secondProfile, password: "second-password")
        try await eventually { second.isConnected && !second.isBusy }
        let beforeFirstConnections = await fixture.sessions[0].connections
        let beforeSecondConnections = await fixture.sessions[1].connections
        first.sql = "SELECT 'first query';"; second.sql = "SELECT 'second query';"
        await fixture.sessions[0].suspendExecution()
        first.run()
        try await eventually { await fixture.sessions[0].queries.count == 1 }
        second.run()
        try await eventually { second.rowCount == 1 && !second.isBusy }
        for _ in 0..<4 { model.selectTab(first.id); model.selectTab(second.id) }
        XCTAssertTrue(first.isBusy)
        XCTAssertFalse(second.isBusy)
        XCTAssertTrue(model.active === second)
        await fixture.sessions[0].finishExecution()
        try await eventually { first.rowCount == 1 && !first.isBusy }
        let firstConnections = await fixture.sessions[0].connections
        let secondConnections = await fixture.sessions[1].connections
        let firstQueries = await fixture.sessions[0].queries
        let secondQueries = await fixture.sessions[1].queries
        XCTAssertEqual(firstConnections, beforeFirstConnections)
        XCTAssertEqual(secondConnections, beforeSecondConnections)
        XCTAssertEqual(firstQueries, ["SELECT 'first query';"])
        XCTAssertEqual(secondQueries, ["SELECT 'second query';"])
        XCTAssertEqual(first.profile, firstProfile)
        XCTAssertEqual(second.profile, secondProfile)
        XCTAssertTrue(model.active === second)
        XCTAssertEqual(first.status, "Complete")
        XCTAssertEqual(second.status, "Complete")
        await model.shutdown()
    }

    private func virtualURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/db3-lifecycle-tests/\(name)").standardizedFileURL.resolvingSymlinksInPath()
    }

    private func eventually(_ predicate: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Asynchronous model work did not reach its expected state", file: file, line: line)
        throw DatabaseError("Timed out waiting for model work")
    }

}
