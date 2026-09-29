import Foundation
import DB3Core
import CLibPQ

public struct ParsedPostgresConnectionURL: Sendable {
    public var profile: ConnectionProfile
    /// `nil` means no password was supplied; an empty string is an explicit empty password.
    public var password: String?
}

/// Converts a PostgreSQL URI into the settings the workbench can represent.
/// This only parses: it performs no connection, DNS lookup, or service-file lookup.
public enum PostgresConnectionURL {
    /// Formats the workbench's supported settings, percent-encoding every value.
    /// The returned URL contains the password and must not be logged or persisted.
    public static func string(from profile: ConnectionProfile, password: String) -> String {
        let host: String
        if profile.host.contains(":") && !profile.host.hasPrefix("/") {
            host = "[" + encode(profile.host, allowingColon: true) + "]"
        } else {
            host = encode(profile.host)
        }
        var url = "postgresql://\(encode(profile.username)):\(encode(password))@\(host):\(profile.port)/\(encode(profile.database))?sslmode=\(profile.tls.rawValue)"
        if !profile.rootCertificate.isEmpty {
            url += "&sslrootcert=" + encode(profile.rootCertificate)
        }
        return url
    }

    public static func parse(_ url: String, applyingTo profile: ConnectionProfile = ConnectionProfile()) throws -> ParsedPostgresConnectionURL {
        guard url.utf8.count <= 16 * 1024 else {
            throw DatabaseError("Connection URLs must be 16 KiB or less.")
        }
        guard !url.utf8.contains(0) else {
            throw DatabaseError("Connection URLs cannot contain NUL characters.")
        }
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw DatabaseError("Enter a PostgreSQL connection URL.") }
        guard url.hasPrefix("postgres://") || url.hasPrefix("postgresql://") else {
            throw DatabaseError("Use a URL beginning with postgres:// or postgresql://.")
        }

        // Do not request libpq's error text: it can repeat credentials or the URL.
        guard let options = url.withCString({ PQconninfoParse($0, nil) }) else {
            throw invalidURL()
        }
        defer { PQconninfoFree(options) }
        let supported: Set<String> = ["host", "port", "dbname", "user", "password", "sslmode", "sslrootcert"]
        var values: [String: String] = [:]
        var option = options
        while let keyword = option.pointee.keyword {
            if let value = option.pointee.val {
                let key = String(cString: keyword)
                guard supported.contains(key) else {
                    throw DatabaseError("This URL contains an unsupported connection option. Supported query parameters are host, port, dbname, user, password, sslmode, and sslrootcert.")
                }
                guard let text = String(validatingCString: value) else { throw invalidURL() }
                values[key] = text
            }
            option = option.advanced(by: 1)
        }

        guard !(values["host"]?.contains(",") ?? false), !(values["port"]?.contains(",") ?? false) else {
            throw DatabaseError("URLs with multiple hosts or ports are not supported. Use one host and one port.")
        }
        let port: Int
        if let portValue = nonempty(values["port"]) {
            guard portValue.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(portValue), (1...65535).contains(number) else {
                throw DatabaseError("The connection URL port must be a number from 1 to 65535.")
            }
            port = number
        } else {
            port = 5432
        }
        let tls: TLSMode
        if let mode = values["sslmode"] {
            guard let supportedMode = TLSMode(rawValue: mode) else {
                throw DatabaseError("The connection URL TLS mode must be verify-full, require, or disable.")
            }
            tls = supportedMode
        } else {
            tls = .verifyFull
        }

        // Identity, label, and the Objects browser preference carry over from an
        // existing profile. Omitted URL fields must not inherit server settings.
        let username = nonempty(values["user"]) ?? NSUserName()
        let parsedProfile = ConnectionProfile(
            id: profile.id,
            name: profile.name,
            host: nonempty(values["host"]) ?? "localhost",
            port: port,
            database: nonempty(values["dbname"]) ?? username,
            username: username,
            tls: tls,
            rootCertificate: values["sslrootcert"] ?? "",
            defaultSchema: profile.defaultSchema
        )

        // libpq omits the password option for `user:@host`. Preserve the user's
        // explicit empty password so callers never reuse a previous secret.
        let authority = url.dropFirst(url.hasPrefix("postgresql://") ? 13 : 11)
            .prefix { $0 != "/" && $0 != "?" }
        let hasPasswordSeparator = authority.firstIndex(of: "@").map {
            authority[..<$0].contains(":")
        } ?? false
        let password = values["password"] ?? (hasPasswordSeparator ? "" : nil)
        return ParsedPostgresConnectionURL(profile: parsedProfile, password: password)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func encode(_ value: String, allowingColon: Bool = false) -> String {
        // RFC 3986 unreserved characters. Encoding delimiters independently
        // prevents credentials and database names from becoming URI structure.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" + (allowingColon ? ":" : ""))
        return value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    private static func invalidURL() -> DatabaseError {
        DatabaseError("The PostgreSQL connection URL is invalid. Check its format and percent encoding.")
    }
}
