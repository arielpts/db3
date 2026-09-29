import Foundation
import XCTest
import DB3Core
import DB3Postgres

final class PostgresConnectionURLTests: XCTestCase {
    func testManualSettingsRoundTripSpecialCharactersIPv6AndSockets() throws {
        for host in ["db.example.com", "2001:db8::1234", "fe80::1%en0", "/tmp/postgresql sockets", "höst.example"] {
            for password in ["", "p@ss:/%#?&+= ça🐘"] {
                let profile = ConnectionProfile(name: "Round trip", host: host, port: 6543,
                                                database: "db/%#?&+=ação🐘", username: "user@team:%/#?&+=ça🐘",
                                                tls: .require, rootCertificate: "/tmp/root #?&+%🐘.pem",
                                                defaultSchema: " App Data ")
                let url = PostgresConnectionURL.string(from: profile, password: password)
                let parsed = try PostgresConnectionURL.parse(url, applyingTo: profile)
                XCTAssertEqual(parsed.profile, profile)
                XCTAssertEqual(parsed.password, password)
                XCTAssertFalse(url.contains("#"), "URI delimiters inside values must be encoded.")
                XCTAssertFalse(url.contains("🐘"))
            }
        }
    }

    func testParsesBothSchemesAndCompleteConnection() throws {
        for scheme in ["postgres", "postgresql"] {
            let parsed = try PostgresConnectionURL.parse("\(scheme)://alice:secret@db.example.com:6543/workbench?sslmode=require&sslrootcert=%2Ftmp%2Froot.pem")
            XCTAssertEqual(parsed.profile.host, "db.example.com")
            XCTAssertEqual(parsed.profile.port, 6543)
            XCTAssertEqual(parsed.profile.database, "workbench")
            XCTAssertEqual(parsed.profile.username, "alice")
            XCTAssertEqual(parsed.profile.tls, .require)
            XCTAssertEqual(parsed.profile.rootCertificate, "/tmp/root.pem")
            XCTAssertEqual(parsed.password, "secret")
        }
    }

    func testOmittedFieldsUseDefaultsWithoutInheritingProfileSettings() throws {
        let original = ConnectionProfile(name: "Saved label", host: "old.example.com", port: 9000,
                                         database: "old_database", username: "old_user", tls: .disable,
                                         rootCertificate: "/old/root.pem", defaultSchema: "reporting")
        let parsed = try PostgresConnectionURL.parse("postgresql://", applyingTo: original)
        XCTAssertEqual(parsed.profile.id, original.id)
        XCTAssertEqual(parsed.profile.name, original.name)
        XCTAssertEqual(parsed.profile.defaultSchema, "reporting")
        XCTAssertEqual(parsed.profile.host, "localhost")
        XCTAssertEqual(parsed.profile.port, 5432)
        XCTAssertEqual(parsed.profile.username, NSUserName())
        XCTAssertEqual(parsed.profile.database, NSUserName())
        XCTAssertEqual(parsed.profile.tls, .verifyFull)
        XCTAssertEqual(parsed.profile.rootCertificate, "")
        XCTAssertNil(parsed.password)
        XCTAssertEqual(try PostgresConnectionURL.parse("postgres://alice@localhost").profile.database, "alice")
    }

    func testSchemaPreferenceIsSeparateFromTheConnectionURL() throws {
        let schema = "browser only schema"
        let original = ConnectionProfile(defaultSchema: schema)
        let url = PostgresConnectionURL.string(from: original, password: "")
        XCTAssertFalse(url.contains("schema"))
        XCTAssertFalse(url.contains("search_path"))
        XCTAssertEqual(try PostgresConnectionURL.parse(url).profile.defaultSchema, "public")
        XCTAssertEqual(try PostgresConnectionURL.parse(url, applyingTo: original).profile.defaultSchema, schema)

        let changedURL = try PostgresConnectionURL.parse("postgresql://reader@other.invalid/other_db", applyingTo: original)
        XCTAssertEqual(changedURL.profile.defaultSchema, schema)
        XCTAssertEqual(changedURL.profile.host, "other.invalid")
    }

    func testEmptyDefaultableParametersDoNotInheritPreviousValues() throws {
        let parsed = try PostgresConnectionURL.parse("postgresql://old:secret@oldhost/olddb?host=&port=&user=&dbname=&password=&sslrootcert=")
        XCTAssertEqual(parsed.profile.host, "localhost")
        XCTAssertEqual(parsed.profile.port, 5432)
        XCTAssertEqual(parsed.profile.username, NSUserName())
        XCTAssertEqual(parsed.profile.database, NSUserName())
        XCTAssertEqual(parsed.profile.rootCertificate, "")
        XCTAssertEqual(parsed.password, "")
    }

    func testPercentEncodedCredentialsAndDatabaseAreDecodedExactlyOnce() throws {
        let parsed = try PostgresConnectionURL.parse("postgresql://user%40team:p%40ss%3A%2F%25%252F%2B@host/db%2Fname%20%C3%A7")
        XCTAssertEqual(parsed.profile.username, "user@team")
        XCTAssertEqual(parsed.profile.database, "db/name ç")
        XCTAssertEqual(parsed.password, "p@ss:/%%2F+")
        let plus = try PostgresConnectionURL.parse("postgresql://host/db?password=a+b%2Bc")
        XCTAssertEqual(plus.password, "a+b+c", "A URL query uses URI encoding, not form encoding.")
    }

    func testIPv6AndSocketPathHostsArePreserved() throws {
        let ipv6 = try PostgresConnectionURL.parse("postgresql://alice:secret@[2001:db8::1234]:6543/db")
        XCTAssertEqual(ipv6.profile.host, "2001:db8::1234")
        XCTAssertEqual(ipv6.profile.port, 6543)
        XCTAssertEqual(try PostgresConnectionURL.parse("postgresql://%2Ftmp/db?sslmode=disable").profile.host, "/tmp")
    }

    func testQueryParametersOverrideAuthorityAndPath() throws {
        let parsed = try PostgresConnectionURL.parse("postgresql://original:old@oldhost:5433/olddb?host=newhost&port=6543&dbname=newdb&user=newuser&password=newpass&sslmode=disable")
        XCTAssertEqual(parsed.profile.host, "newhost")
        XCTAssertEqual(parsed.profile.port, 6543)
        XCTAssertEqual(parsed.profile.database, "newdb")
        XCTAssertEqual(parsed.profile.username, "newuser")
        XCTAssertEqual(parsed.profile.tls, .disable)
        XCTAssertEqual(parsed.password, "newpass")
    }

    func testPasswordOmissionAndExplicitEmptyPasswordsRemainDistinct() throws {
        XCTAssertNil(try PostgresConnectionURL.parse("postgresql://alice@localhost/db").password)
        XCTAssertEqual(try PostgresConnectionURL.parse("postgresql://alice:@localhost/db").password, "")
        XCTAssertEqual(try PostgresConnectionURL.parse("postgresql://alice@localhost/db?password=").password, "")
        XCTAssertEqual(try PostgresConnectionURL.parse("postgresql://alice:old@localhost/db?password=").password, "")
        XCTAssertNil(try PostgresConnectionURL.parse("postgresql://[::1]/db").password)
        XCTAssertNil(try PostgresConnectionURL.parse("postgresql://alice%3A@localhost/db").password)
    }

    func testPasteWhitespaceAndTLSAlias() throws {
        let parsed = try PostgresConnectionURL.parse(" \npostgresql://localhost/db?ssl=true\r\n ")
        XCTAssertEqual(parsed.profile.tls, .require)
        XCTAssertEqual(try PostgresConnectionURL.parse("postgresql://localhost/db?sslmode=verify-full").profile.tls, .verifyFull)
    }

    func testUnsupportedOptionsAndTLSModesAreRejected() {
        for query in ["application_name=db3", "connect_timeout=10", "options=-c%20search_path%3Dpublic", "service=production", "hostaddr=127.0.0.1", "sslcert=%2Fclient.pem", "application_name=", "unknown=value", "sslmode=prefer", "sslmode=allow", "sslmode=verify-ca", "sslmode=", "ssl=false"] {
            XCTAssertThrowsError(try PostgresConnectionURL.parse("postgresql://localhost/db?\(query)"))
        }
    }

    func testMultipleHostsAndPortsAreRejected() {
        for url in ["postgresql://one,two/db", "postgresql://one:5432,two:5433/db", "postgresql://[::1],[::2]/db", "postgresql://localhost/db?host=one%2Ctwo", "postgresql://localhost/db?port=5432%2C5433"] {
            XCTAssertThrowsError(try PostgresConnectionURL.parse(url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("multiple hosts or ports"))
            }
        }
    }

    func testPortsRejectZeroNegativeOverflowAndNonNumericValues() {
        for port in ["0", "65536", "-1", "+5432", "5432x", "99999999999999999999999999", "%205432", "%EF%BC%95%EF%BC%94%EF%BC%93%EF%BC%92"] {
            XCTAssertThrowsError(try PostgresConnectionURL.parse("postgresql://localhost/db?port=\(port)")) { error in
                XCTAssertTrue(error.localizedDescription.contains("port"))
            }
        }
    }

    func testMalformedURLsAndInvalidEncodingAreRejected() {
        for url in ["", "   ", "https://localhost/db", "host=localhost", "postgresql:/localhost", "postgresql://[::1/db", "postgresql://localhost/db?user", "postgresql://localhost/db?password=%", "postgresql://localhost/db?password=%ZZ", "postgresql://localhost/db?password=%00", "postgresql://localhost/db?password=%FF", "postgresql://localhost/db\0?password=secret"] {
            XCTAssertThrowsError(try PostgresConnectionURL.parse(url))
        }
    }

    func testLengthLimitCountsUTF8BytesBeforeTrimming() throws {
        let prefix = "postgresql://localhost/db?password="
        XCTAssertNotNil(try PostgresConnectionURL.parse(prefix + String(repeating: "x", count: 16 * 1024 - prefix.utf8.count)))
        XCTAssertThrowsError(try PostgresConnectionURL.parse(prefix + String(repeating: "x", count: 16 * 1024)))
        XCTAssertThrowsError(try PostgresConnectionURL.parse(prefix + String(repeating: "🐘", count: 5_000)))
        XCTAssertThrowsError(try PostgresConnectionURL.parse(String(repeating: " ", count: 16 * 1024) + "postgresql://"))
    }

    func testErrorsNeverEchoURLCredentialsOrUnsupportedValues() {
        let secret = "private_secret_9f213"
        let urls = [
            "postgresql://alice:\(secret)@localhost/db?password=%ZZ",
            "postgresql://alice:\(secret)@localhost/db?sslmode=\(secret)",
            "postgresql://alice:\(secret)@localhost/db?application_name=\(secret)",
            "postgresql://alice:\(secret)@localhost/db?port=\(secret)",
            "postgresql://alice:\(secret)@one,two/private_database",
            "postgresql://alice:\(secret)@localhost/db?\(secret)=secret",
        ]
        for url in urls {
            XCTAssertThrowsError(try PostgresConnectionURL.parse(url)) { error in
                XCTAssertFalse(error.localizedDescription.contains(secret))
                XCTAssertFalse(error.localizedDescription.contains("alice"))
                XCTAssertFalse(error.localizedDescription.contains("private_database"))
                XCTAssertFalse(error.localizedDescription.contains(url))
            }
        }
    }
}
