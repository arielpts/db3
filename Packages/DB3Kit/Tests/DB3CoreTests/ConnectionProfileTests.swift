import Foundation
import XCTest
import DB3Core

final class ConnectionProfileTests: XCTestCase {
    func testDefaultSchemaIsPublicForNewAndPreviouslySavedProfiles() throws {
        let profile = ConnectionProfile(name: "Existing connection", host: "db.example.invalid",
                                        port: 6543, database: "app", username: "reader",
                                        tls: .require, rootCertificate: "/tmp/root.pem")
        XCTAssertEqual(profile.defaultSchema, "public")
        var saved = try savedObject(profile)
        saved.removeValue(forKey: "defaultSchema")

        let restored = try decode(saved)
        XCTAssertEqual(restored, profile, "Adding the browser setting must not prevent loading old connections.")
    }

    func testCustomSchemaRoundTripsWithoutTrimmingOrSQLQuoting() throws {
        for schema in ["analytics", " App Data ", " ", "équipe", "a\"b", ""] {
            let profile = ConnectionProfile(defaultSchema: schema)
            let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(restored, profile)
            XCTAssertEqual(restored.defaultSchema, schema)
        }
    }

    func testOlderRequiredFieldsStillRejectMissingAndNullValues() throws {
        let saved = try savedObject(ConnectionProfile())
        for key in ["id", "name", "host", "port", "database", "username", "tls", "rootCertificate"] {
            var missing = saved
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(missing), "Missing \(key) must still fail.")

            var null = saved
            null[key] = NSNull()
            XCTAssertThrowsError(try decode(null), "Null \(key) must still fail.")
        }
    }

    func testMalformedSchemaDoesNotSilentlyReplaceSavedSettings() throws {
        var saved = try savedObject(ConnectionProfile())
        let invalidValues: [Any] = [NSNull(), 42, ["public"]]
        for invalid in invalidValues {
            saved["defaultSchema"] = invalid
            XCTAssertThrowsError(try decode(saved))
        }
    }

    private func savedObject(_ profile: ConnectionProfile) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    }

    private func decode(_ saved: [String: Any]) throws -> ConnectionProfile {
        try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: saved))
    }
}
