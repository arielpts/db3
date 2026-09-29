import Foundation
import XCTest
import DB3Core
@testable import DB3Workbench

/// Credential recovery uses fake persistence and sessions; it never accesses
/// Keychain, presents native UI, or opens a database connection.
@MainActor
final class WorksheetCredentialTests: XCTestCase {
    func testReadFailurePromptsAndEnteredPasswordConnectsCapturedInactiveTabWithoutPersistence() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let profile = ConnectionProfile(name: "Query connection", host: "captured.invalid", database: "query_db")
        let browserProfile = ConnectionProfile(name: "Browser connection", host: "browser.invalid")
        model.profiles = [profile, browserProfile]
        model.selectedBrowserProfileID = browserProfile.id
        let target = model.active
        target.profile = profile
        target.sql = "SELECT 'keep this draft';"
        await fixture.persistence.failPasswordReads(for: profile.id)

        model.connectSaved(profile, in: target)
        try await eventually { model.worksheetCredentialRequest != nil }
        let request = try XCTUnwrap(model.worksheetCredentialRequest)
        XCTAssertEqual(request.profile, profile)
        XCTAssertEqual(request.target.worksheetID, target.id)
        XCTAssertEqual(request.target.intent, target.connectionIntent)
        XCTAssertNil(model.error)
        XCTAssertFalse(target.isConnected)

        model.addWorksheet(); let other = model.active
        model.profiles[0].host = "subsequently-edited.invalid"
        model.submitWorksheetPassword("temporary-password", for: request.id)
        try await eventually { target.isConnected && !target.isBusy }

        XCTAssertNil(model.worksheetCredentialRequest)
        XCTAssertTrue(model.active === other)
        XCTAssertFalse(other.isConnected)
        XCTAssertEqual(target.profile, profile)
        XCTAssertEqual(target.sql, "SELECT 'keep this draft';")
        XCTAssertEqual(model.objectBrowser.selectedProfile, browserProfile)
        XCTAssertEqual(model.objectBrowser.phase, .notLoaded)
        let connections = await fixture.sessions[0].connections
        XCTAssertEqual(connections, [.init(profile: profile, password: "temporary-password")])
        let reads = await fixture.persistence.passwordReads
        XCTAssertEqual(reads, [profile.id], "Submitting the entered password must not retry Keychain.")
        await assertNoCredentialPersistence(fixture)
        await model.shutdown()
    }

    func testCancelInvalidatesPendingIntentAndIgnoresLateSubmit() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let target = model.active
        let profile = ConnectionProfile(name: "Cancelled")
        await fixture.persistence.failPasswordReads(for: profile.id)
        model.connectSaved(profile, in: target)
        try await eventually { model.worksheetCredentialRequest != nil }
        let request = try XCTUnwrap(model.worksheetCredentialRequest)

        model.dismissWorksheetCredentialRequest(request.id)
        XCTAssertNil(model.worksheetCredentialRequest)
        XCTAssertNotEqual(target.connectionIntent, request.target.intent)
        model.submitWorksheetPassword("ignored-password", for: request.id)
        let connections = await fixture.sessions[0].connections
        XCTAssertTrue(connections.isEmpty)
        XCTAssertFalse(target.isConnected)
        XCTAssertNil(model.error)
        await assertNoCredentialPersistence(fixture)
        await model.shutdown()
    }

    func testOldSubmitAndDismissCannotReplaceNewerCredentialRequest() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let target = model.active
        let oldProfile = ConnectionProfile(name: "Old", host: "old.invalid")
        let newProfile = ConnectionProfile(name: "New", host: "new.invalid")
        await fixture.persistence.failPasswordReads(for: oldProfile.id)
        await fixture.persistence.failPasswordReads(for: newProfile.id)
        model.connectSaved(oldProfile, in: target)
        try await eventually { model.worksheetCredentialRequest != nil }
        let old = try XCTUnwrap(model.worksheetCredentialRequest)

        model.connectSaved(newProfile, in: target)
        try await eventually { model.worksheetCredentialRequest?.profile == newProfile }
        let current = try XCTUnwrap(model.worksheetCredentialRequest)
        model.submitWorksheetPassword("obsolete-password", for: old.id)
        model.dismissWorksheetCredentialRequest(old.id)
        XCTAssertEqual(model.worksheetCredentialRequest?.id, current.id)
        XCTAssertEqual(target.connectionIntent, current.target.intent)

        model.submitWorksheetPassword("current-password", for: current.id)
        try await eventually { target.isConnected && !target.isBusy }
        let connections = await fixture.sessions[0].connections
        XCTAssertEqual(connections, [.init(profile: newProfile, password: "current-password")])
        await assertNoCredentialPersistence(fixture)
        await model.shutdown()
    }

    func testConcurrentReadFailuresKeepActivePromptAndConnectEachCapturedTab() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active
        model.addWorksheet(); let second = model.active
        let firstProfile = ConnectionProfile(name: "First", host: "first.invalid")
        let secondProfile = ConnectionProfile(name: "Second", host: "second.invalid")
        await fixture.persistence.holdPassword(for: firstProfile.id)
        await fixture.persistence.holdPassword(for: secondProfile.id)
        model.connectSaved(firstProfile, in: first)
        model.connectSaved(secondProfile, in: second)
        try await eventually { await fixture.persistence.passwordReads.count == 2 }

        await fixture.persistence.failPendingPassword(for: firstProfile.id)
        try await eventually { model.worksheetCredentialRequest?.profile == firstProfile }
        let firstRequest = try XCTUnwrap(model.worksheetCredentialRequest)
        await fixture.persistence.failPendingPassword(for: secondProfile.id)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.worksheetCredentialRequest?.id, firstRequest.id,
                       "A later failure must not replace the password prompt being filled in.")

        model.submitWorksheetPassword("first-temporary", for: firstRequest.id)
        try await eventually { model.worksheetCredentialRequest?.profile == secondProfile }
        let secondRequest = try XCTUnwrap(model.worksheetCredentialRequest)
        XCTAssertEqual(secondRequest.target.worksheetID, second.id)
        model.dismissWorksheetCredentialRequest(firstRequest.id)
        XCTAssertEqual(model.worksheetCredentialRequest?.id, secondRequest.id)
        model.submitWorksheetPassword("second-temporary", for: secondRequest.id)
        try await eventually { first.isConnected && !first.isBusy && second.isConnected && !second.isBusy }

        XCTAssertNil(model.worksheetCredentialRequest)
        XCTAssertTrue(model.active === second)
        let firstConnections = await fixture.sessions[0].connections
        let secondConnections = await fixture.sessions[1].connections
        XCTAssertEqual(firstConnections, [.init(profile: firstProfile, password: "first-temporary")])
        XCTAssertEqual(secondConnections, [.init(profile: secondProfile, password: "second-temporary")])
        let reads = await fixture.persistence.passwordReads
        XCTAssertEqual(reads.count, 2)
        await assertNoCredentialPersistence(fixture)
        await model.shutdown()
    }

    func testClosingQueuedTargetKeepsActivePromptAndDoesNotPresentClosedTabLater() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let first = model.active
        model.addWorksheet(); let queued = model.active
        let firstProfile = ConnectionProfile(name: "Active prompt", host: "active.invalid")
        let queuedProfile = ConnectionProfile(name: "Queued prompt", host: "queued.invalid")
        await fixture.persistence.holdPassword(for: firstProfile.id)
        await fixture.persistence.holdPassword(for: queuedProfile.id)
        model.connectSaved(firstProfile, in: first)
        model.connectSaved(queuedProfile, in: queued)
        try await eventually { await fixture.persistence.passwordReads.count == 2 }
        await fixture.persistence.failPendingPassword(for: firstProfile.id)
        try await eventually { model.worksheetCredentialRequest?.profile == firstProfile }
        let firstRequest = try XCTUnwrap(model.worksheetCredentialRequest)
        await fixture.persistence.failPendingPassword(for: queuedProfile.id)
        try await Task.sleep(for: .milliseconds(20))

        let closed = await model.closeTab(id: queued.id)
        XCTAssertTrue(closed)
        XCTAssertEqual(model.worksheetCredentialRequest?.id, firstRequest.id)
        model.submitWorksheetPassword("first-temporary", for: firstRequest.id)
        try await eventually { first.isConnected && !first.isBusy }
        XCTAssertNil(model.worksheetCredentialRequest)
        XCTAssertTrue(queued.isClosed)
        let queuedConnections = await fixture.sessions[1].connections
        XCTAssertTrue(queuedConnections.isEmpty)
        await assertNoCredentialPersistence(fixture)
        await model.shutdown()
    }

    func testClosingTargetClearsPromptAndRejectsOldPassword() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let target = model.active
        let profile = ConnectionProfile(name: "Closing")
        await fixture.persistence.failPasswordReads(for: profile.id)
        model.connectSaved(profile, in: target)
        try await eventually { model.worksheetCredentialRequest != nil }
        let request = try XCTUnwrap(model.worksheetCredentialRequest)

        let closed = await model.closeTab(id: target.id)
        XCTAssertTrue(closed)
        XCTAssertNil(model.worksheetCredentialRequest)
        model.submitWorksheetPassword("late-password", for: request.id)
        model.dismissWorksheetCredentialRequest(request.id)
        let connections = await fixture.sessions[0].connections
        XCTAssertTrue(connections.isEmpty)
        XCTAssertTrue(target.isClosed)
        XCTAssertNotEqual(model.active.id, target.id)
        XCTAssertFalse(model.active.isConnected)
        await assertNoCredentialPersistence(fixture)
        await model.shutdown()
    }

    func testReadFailureArrivingAfterTargetClosedDoesNotPresentPrompt() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let target = model.active
        let profile = ConnectionProfile(name: "Late read failure")
        await fixture.persistence.holdPassword(for: profile.id)
        model.connectSaved(profile, in: target)
        try await eventually { await fixture.persistence.passwordReads == [profile.id] }
        let closed = await model.closeTab(id: target.id)
        XCTAssertTrue(closed)
        await fixture.persistence.failPendingPassword(for: profile.id)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(model.worksheetCredentialRequest)
        XCTAssertNil(model.error)
        let connections = await fixture.sessions[0].connections
        XCTAssertTrue(connections.isEmpty)
        await model.shutdown()
    }

    func testNewConnectionEditorClearsPromptWithoutOldDismissalAffectingEditor() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let target = model.active
        let profile = ConnectionProfile(name: "Failed read")
        await fixture.persistence.failPasswordReads(for: profile.id)
        model.connectSaved(profile, in: target)
        try await eventually { model.worksheetCredentialRequest != nil }
        let request = try XCTUnwrap(model.worksheetCredentialRequest)

        model.newConnection(in: target)
        let editorTarget = try XCTUnwrap(model.connectionEditTarget)
        XCTAssertNil(model.worksheetCredentialRequest)
        model.dismissWorksheetCredentialRequest(request.id)
        model.submitWorksheetPassword("obsolete-password", for: request.id)
        XCTAssertTrue(model.showingConnection)
        XCTAssertEqual(model.connectionEditTarget, editorTarget)
        XCTAssertEqual(target.connectionIntent, editorTarget.intent)
        let connections = await fixture.sessions[0].connections
        XCTAssertTrue(connections.isEmpty)
        model.dismissConnectionEditor()
        await model.shutdown()
    }

    func testSuccessfulSavedAndEmptyPasswordsConnectWithoutPrompt() async throws {
        for password in ["saved-password", ""] {
            let fixture = WorkbenchFixture(); let model = fixture.model
            let target = model.active
            let profile = ConnectionProfile(name: "Saved or trust authentication")
            await fixture.persistence.setPassword(password, for: profile.id)
            model.connectSaved(profile, in: target)
            try await eventually { target.isConnected && !target.isBusy }

            XCTAssertNil(model.worksheetCredentialRequest)
            XCTAssertNil(model.error)
            let connections = await fixture.sessions[0].connections
            XCTAssertEqual(connections, [.init(profile: profile, password: password)])
            await assertNoCredentialPersistence(fixture)
            await model.shutdown()
        }
    }

    func testShutdownClearsRequestAndRejectsPassword() async throws {
        let fixture = WorkbenchFixture(); let model = fixture.model
        let target = model.active
        let profile = ConnectionProfile(name: "Shutdown")
        await fixture.persistence.failPasswordReads(for: profile.id)
        model.connectSaved(profile, in: target)
        try await eventually { model.worksheetCredentialRequest != nil }
        let request = try XCTUnwrap(model.worksheetCredentialRequest)

        await model.shutdown()
        XCTAssertNil(model.worksheetCredentialRequest)
        model.submitWorksheetPassword("late-password", for: request.id)
        let connections = await fixture.sessions[0].connections
        XCTAssertTrue(connections.isEmpty)
        XCTAssertTrue(target.isClosed)
        await assertNoCredentialPersistence(fixture)
    }

    private func assertNoCredentialPersistence(_ fixture: WorkbenchFixture,
                                               file: StaticString = #filePath, line: UInt = #line) async {
        let passwordWrites = await fixture.persistence.passwordWrites
        let profileWrites = await fixture.persistence.profileWrites
        XCTAssertTrue(passwordWrites.isEmpty, "Recovery must not save or delete Keychain credentials.", file: file, line: line)
        XCTAssertTrue(profileWrites.isEmpty, "Recovery must not overwrite connection profiles.", file: file, line: line)
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DatabaseError("Timed out waiting for worksheet credential recovery")
    }
}
