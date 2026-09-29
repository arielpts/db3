import Foundation
import Darwin
import DB3Core

public enum ProjectConfigurationDiscovery {
    public static func discover(root: URL) async throws -> ProjectConfigurationSnapshot {
        let work = Task.detached(priority: .utility) { try inspect(root: root.standardizedFileURL) }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func inspect(root: URL) throws -> ProjectConfigurationSnapshot {
        try Task.checkCancellation()
        var diagnostics: [ProjectConfigDiagnostic] = [], evidence: [ProjectConfigEvidence] = []
        let envURL = root.appendingPathComponent(".env")
        let contents: String
        do {
            if let bytes = try ProjectFileIO.readIfPresent(envURL, maximumBytes: ProjectDotEnvParser.maximumBytes) {
                guard let text = String(data: bytes, encoding: .utf8) else { throw ProjectConfigurationError.invalidLiteral }
                contents = text
            } else { contents = "" }
        } catch is CancellationError { throw CancellationError() }
        catch {
            return ProjectConfigurationSnapshot(candidates: [], diagnostics: [.init(source: .init(relativePath: ".env", line: 0, key: ""), message: error is ProjectConfigurationError ? error.localizedDescription : "The environment file could not be read safely.")], revision: ProjectFingerprint.digest(["unavailable-env"]), evidence: [], complete: false)
        }
        // Explicitly allow project connection keys, not arbitrary process or
        // shell variables such as HOME/PATH. Only earlier assignments resolve.
        let declaredKeys = contents.split(separator: "\n").compactMap { line -> String? in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("export ") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = text.firstIndex(of: "=") else { return nil }
            let key = text[..<equals].trimmingCharacters(in: .whitespaces)
            return ProjectDotEnvParser.validKey(key) && isConnectionKey(key) ? key : nil
        }
        let parsed = try ProjectDotEnvParser.parse(contents, allowedVariables: Set(declaredKeys))
        diagnostics += parsed.diagnostics
        let entries = parsed.entries
        let odoo = FileManager.default.fileExists(atPath: root.appendingPathComponent("odoo_repositories.json").path)
        var groups = Set<String>()
        for key in entries.keys {
            for suffix in ["HOST", "PORT", "NAME", "DATABASE", "USER", "USERNAME", "PASSWORD", "SSLMODE", "SSLROOTCERT"] where key.hasSuffix("DB_" + suffix) {
                groups.insert(String(key.dropLast(suffix.count)))
            }
        }
        var candidates: [ProjectConnectionCandidate] = []
        for group in groups.sorted() {
            func value(_ suffix: String, alternative: String? = nil) -> ProjectConfigValue {
                entries[group + suffix]?.value ?? alternative.flatMap { entries[group + $0]?.value } ?? .missing
            }
            let sources = entries.filter { $0.key.hasPrefix(group) && ["HOST", "PORT", "NAME", "DATABASE", "USER", "USERNAME", "PASSWORD", "SSLMODE", "SSLROOTCERT"].contains(String($0.key.dropFirst(group.count))) }.values.map(\.source).sorted { $0.line < $1.line }
            let (environment, environmentEvidence) = classification(group: group, isOdoo: odoo)
            candidates.append(candidate(id: ".env:" + group, name: label(group), kind: .postgresql, group: group,
                environment: environment, environmentEvidence: environmentEvidence,
                host: value("HOST"), port: value("PORT"), database: value("NAME", alternative: "DATABASE"), username: value("USER", alternative: "USERNAME"),
                password: value("PASSWORD"), certificate: value("SSLROOTCERT"), tls: tls(value("SSLMODE")), sources: sources,
                secretRevision: entries[group + "PASSWORD"]?.secretRevision))
        }
        for key in entries.keys.sorted() where key == "DATABASE_URL" || key.hasSuffix("_DATABASE_URL") {
            let entry = entries[key]!
            let (environment, environmentEvidence) = classification(group: key, isOdoo: false)
            if let url = entry.value.string, !url.isEmpty {
                do {
                    let fields = try parseURL(url)
                    candidates.append(candidate(id: ".env:" + key, name: label(key), kind: .postgresql, group: key,
                        environment: environment, environmentEvidence: environmentEvidence,
                        host: fields["host"] ?? .missing, port: fields["port"] ?? .missing, database: fields["dbname"] ?? .missing,
                        username: fields["user"] ?? .missing, password: fields["password"] ?? .missing, certificate: fields["sslrootcert"] ?? .missing,
                        tls: tls(fields["sslmode"] ?? .missing), sources: [entry.source]))
                } catch {
                    diagnostics.append(.init(source: entry.source, message: "This PostgreSQL URL is unresolved or uses unsupported options. Review it in the connection editor."))
                    candidates.append(unresolvedURL(key: key, entry: entry, environment: environment, evidence: environmentEvidence))
                }
            } else { candidates.append(unresolvedURL(key: key, entry: entry, environment: environment, evidence: environmentEvidence)) }
        }
        if let application = entries["ODOO_BASE_URL"] {
            let token = entries["ODOO_API_KEY"] ?? entries["ODOO_API_TOKEN"] ?? entries["ODOO_TOKEN"]
            let database = entries["ODOO_DB_NAME"]?.value ?? entries["ODOO_DATABASE"]?.value ?? entries["DB_NAME"]?.value ?? .missing
            candidates.append(candidate(id: ".env:ODOO", name: "Odoo application", kind: .odooEvidence, group: "ODOO_", environment: .unknown,
                environmentEvidence: "Application transport is reviewed separately in task 08.", host: application.value, port: .missing,
                database: database, username: .missing, password: token?.value ?? .missing, certificate: .missing, tls: .unresolved,
                sources: [application.source], secretRevision: token?.secretRevision))
            evidence.append(.init(kind: .odooApplication, source: application.source, detail: "Odoo endpoint evidence; RPC credentials and transport are deferred to task 08."))
        }
        let makefile: String?
        do {
            if let bytes = try ProjectFileIO.readIfPresent(root.appendingPathComponent("Makefile"), maximumBytes: ProjectDotEnvParser.maximumBytes) {
                guard let text = String(data: bytes, encoding: .utf8) else { throw ProjectConfigurationError.invalidLiteral }
                makefile = text
            } else { makefile = nil }
        } catch is CancellationError { throw CancellationError() }
        catch {
            makefile = nil
            diagnostics.append(.init(source: .init(relativePath: "Makefile", line: 0, key: ""), message: "This optional configuration source could not be inspected safely."))
        }
        if let text = makefile {
            let expression = try NSRegularExpression(pattern: #"\bPGSSLMODE[ \t]*[:?+]?=[ \t]*(prefer|require|verify-full|verify-ca|disable|allow)\b"#)
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(32) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let line = text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                evidence.append(.init(kind: .tlsSetting, source: .init(relativePath: "Makefile", line: line, key: "PGSSLMODE"), detail: String(text[range])))
            }
        }
        let config = root.appendingPathComponent("config")
        do {
            let names = try ProjectFileIO.safeDirectoryNames(config)
            for name in names.filter({ $0.hasPrefix("odoo-") && $0.hasSuffix(".conf") }).sorted().prefix(64) {
                try Task.checkCancellation()
                do {
                    guard let bytes = try ProjectFileIO.readIfPresent(config.appendingPathComponent(name), maximumBytes: ProjectDotEnvParser.maximumBytes) else { continue }
                    guard let text = String(data: bytes, encoding: .utf8) else { throw ProjectConfigurationError.invalidLiteral }
                    if text.contains("${") || text.contains("%(") {
                        evidence.append(.init(kind: .odooPlaceholderConfiguration, source: .init(relativePath: "config/" + name, line: 0, key: ""), detail: "Placeholder configuration; no shell or inherited environment was evaluated."))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    diagnostics.append(.init(source: .init(relativePath: "config/" + name, line: 0, key: ""), message: "This optional configuration source could not be inspected safely."))
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            var info = stat()
            if lstat(config.path, &info) == 0 || errno != ENOENT {
                diagnostics.append(.init(source: .init(relativePath: "config", line: 0, key: ""), message: "The configuration directory could not be inspected safely or exceeded its entry limit."))
            }
        }
        let revision = ProjectFingerprint.digest(candidates.flatMap { [$0.id, $0.nonsecretFingerprint, $0.secretRevision] } + evidence.map { $0.source.relativePath + $0.detail } + diagnostics.map(\.id))
        return ProjectConfigurationSnapshot(candidates: candidates, diagnostics: diagnostics, revision: revision, evidence: evidence,
                                            complete: diagnostics.isEmpty)
    }

    private static func isConnectionKey(_ key: String) -> Bool {
        key.hasPrefix("DB_") || key.contains("_DB_") || key.hasSuffix("DATABASE_URL") || key.hasPrefix("ODOO_") || ["ENVIRONMENT", "APP_ENV", "PGSSLMODE"].contains(key)
    }
    private static func classification(group: String, isOdoo: Bool) -> (ConnectionEnvironment, String) {
        if group.hasPrefix("PRODUCTION_") || group.hasPrefix("PROD_") { return (.production, "Production-prefixed configuration group.") }
        if group.hasPrefix("DEVELOPMENT_") || group.hasPrefix("DEV_") || (isOdoo && group == "DB_") { return (.development, "Development configuration group; endpoint names were not used to infer environment.") }
        return (.unknown, "This source does not establish an environment; review it explicitly.")
    }
    private static func label(_ group: String) -> String {
        if group == "DB_" { return "PostgreSQL (DB_)" }
        return group.trimmingCharacters(in: CharacterSet(charactersIn: "_")).replacingOccurrences(of: "_", with: " ").capitalized
    }
    private static func tls(_ value: ProjectConfigValue) -> ProjectTLSReview {
        if value == .missing || value == .empty { return .missing }
        guard let text = value.string else { return .unresolved }
        if let mode = TLSMode(rawValue: text) { return .specified(mode) }
        return .unsupported(["prefer", "allow", "verify-ca"].contains(text) ? text : "unrecognized")
    }
    private static func candidate(id: String, name: String, kind: ProjectConnectionCandidate.Kind, group: String,
        environment: ConnectionEnvironment, environmentEvidence: String, host: ProjectConfigValue, port: ProjectConfigValue,
        database: ProjectConfigValue, username: ProjectConfigValue, password: ProjectConfigValue, certificate: ProjectConfigValue,
        tls: ProjectTLSReview, sources: [ProjectConfigProvenance], secretRevision: String? = nil) -> ProjectConnectionCandidate {
        let components = [id, kind.rawValue, environment.rawValue] + [host, port, database, username, certificate].map { $0.string ?? $0.status }
            + [String(describing: tls)] + sources.map { "\($0.relativePath):\($0.key)" }
        return ProjectConnectionCandidate(id: id, name: name, kind: kind, sourceGroup: group, environment: environment,
            environmentEvidence: environmentEvidence, host: host, port: port, database: database, username: username,
            password: password, rootCertificate: certificate, tls: tls, provenance: sources,
            nonsecretFingerprint: ProjectFingerprint.digest(components), secretRevision: secretRevision ?? ProjectFingerprint.secret(password))
    }
    private static func unresolvedURL(key: String, entry: ProjectDotEnvEntry, environment: ConnectionEnvironment, evidence: String) -> ProjectConnectionCandidate {
        let unresolved = ProjectConfigValue.unresolved(["connection URL requires review"])
        return candidate(id: ".env:" + key, name: label(key), kind: .postgresql, group: key, environment: environment, environmentEvidence: evidence,
            host: unresolved, port: .missing, database: unresolved, username: unresolved, password: .missing, certificate: .missing, tls: .unresolved, sources: [entry.source], secretRevision: entry.secretRevision)
    }

    private static func parseURL(_ text: String) throws -> [String: ProjectConfigValue] {
        guard text.utf8.count <= 16 * 1024, !text.utf8.contains(0), let url = URLComponents(string: text),
              ["postgres", "postgresql"].contains(url.scheme ?? ""), url.fragment == nil else { throw ProjectConfigurationError.invalidLiteral }
        var result: [String: ProjectConfigValue] = [:]
        func put(_ name: String, _ value: String?) { if let value { result[name] = .resolved(value) } }
        put("host", url.host); put("port", url.port.map(String.init)); put("user", url.user); put("password", url.password)
        if !url.path.isEmpty { put("dbname", url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path) }
        var seen = Set<String>()
        for item in url.queryItems ?? [] {
            guard ["host", "port", "dbname", "user", "password", "sslmode", "sslrootcert"].contains(item.name), seen.insert(item.name).inserted else { throw ProjectConfigurationError.invalidLiteral }
            put(item.name, item.value ?? "")
        }
        guard result["host"]?.string?.contains(",") != true, result["port"]?.string?.contains(",") != true else { throw ProjectConfigurationError.invalidLiteral }
        return result
    }
}

/// Shared safe, bounded project reads. Symlink config files/directories are
/// deliberately not followed; inspection reports partial coverage instead.
enum ProjectFileIO {
    static func readIfPresent(_ url: URL, maximumBytes: Int) throws -> Data? {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if parent < 0 { if errno == ENOENT { return nil }; throw ProjectConfigurationError.unavailable }
        defer { close(parent) }
        return try readIfPresent(url.lastPathComponent, relativeTo: parent, maximumBytes: maximumBytes)
    }
    static func readIfPresent(_ name: String, relativeTo parent: Int32, maximumBytes: Int) throws -> Data? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw ProjectConfigurationError.unavailable }
        let descriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 { if errno == ENOENT { return nil }; throw ProjectConfigurationError.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ProjectConfigurationError.unavailable }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw ProjectConfigurationError.fileTooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; throw ProjectConfigurationError.unavailable }
            data.append(buffer, count: count)
            guard data.count <= maximumBytes else { throw ProjectConfigurationError.fileTooLarge }
        }
    }
    static func safeDirectoryNames(_ url: URL) throws -> [String] {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProjectConfigurationError.unavailable }
        guard let directory = fdopendir(descriptor) else { close(descriptor); throw ProjectConfigurationError.unavailable }
        defer { closedir(directory) }
        var result: [String] = []
        while let entry = readdir(directory) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard result.count < 4096 else { throw ProjectConfigurationError.fileTooLarge }
            result.append(name)
        }
        return result
    }
}
