import SwiftUI
import DB3Core
import DB3Postgres
import DB3Projects

struct ConnectionSheet: View {
    private enum InputMethod: String, CaseIterable {
        case url = "Connection URL"
        case manual = "Manual Input"
    }

    let model: WorkbenchModel
    @State private var target: ConnectionEditTarget?
    private let candidate: ProjectConnectionCandidate?
    private let projectReview: ProjectConnectionReview?
    @State private var reviewedProjectCandidate = false
    @State private var bindProject = false
    private let catalogIntent: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ConnectionProfile
    @State private var inputMethod: InputMethod
    @State private var password = ""
    @State private var connectionURL = ""
    @State private var urlPassword = ""
    @State private var showingURL = false
    @State private var parsedURL: ParsedPostgresConnectionURL?
    @State private var parsedSource: String?
    @State private var parsingURL = false
    @State private var urlFailure: String?
    @State private var manualURLSnapshot: String?
    @State private var remember = true
    @State private var saving = false
    @State private var loadingCredentials = false
    @State private var failure: String?

    init(model: WorkbenchModel, profile: ConnectionProfile?) {
        self.model = model
        candidate = model.projectConnectionCandidate
        projectReview = model.projectConnectionCandidate.map { model.project.captureReview($0) }
        _password = State(initialValue: model.projectConnectionCandidate?.password.string ?? "")
        catalogIntent = model.catalogConnectionEditIntent
        _target = State(initialValue: model.connectionEditTarget)
        _profile = State(initialValue: profile ?? ConnectionProfile())
        _inputMethod = State(initialValue: profile == nil ? .url : .manual)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 28)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("PostgreSQL connection").font(.title2.bold())
                    Text(catalogIntent == nil ? "A dedicated session for your worksheet." : "Connection settings for the objects browser.").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Picker("Connection method", selection: Binding(get: { inputMethod }, set: { changeInputMethod($0) })) {
                ForEach(InputMethod.allCases, id: \.self) { method in Text(method.rawValue).tag(method) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .disabled(saving || loadingCredentials || parsingURL)
            Form {
                if let candidate {
                    Section("Project connection review") {
                        Text(candidate.sourceGroup + " · " + candidate.environment.title)
                        Text(candidate.environmentEvidence).font(.caption).foregroundStyle(.secondary)
                        Text(candidate.tls.explanation).font(.caption).foregroundStyle(.secondary)
                        if candidate.hasUnresolvedRequirements { Text("Some source values are missing or unresolved. Complete the fields below.").font(.caption) }
                        Text("Password: " + candidate.password.status).font(.caption)
                        Toggle("I reviewed the endpoint, environment, credentials and TLS", isOn: $reviewedProjectCandidate)
                        Toggle("Bind this connection to the open project", isOn: $bindProject)
                    }
                }
                Section {
                    TextField("Name", text: $profile.name)
                    if inputMethod == .url {
                        urlFields
                    } else {
                        TextField("Host", text: $profile.host)
                        TextField("Port", value: $profile.port, format: .number.grouping(.never))
                        TextField("Database", text: $profile.database)
                        TextField("Username", text: $profile.username)
                        SecureField("Password", text: $password)
                    }
                    Toggle("Save password in Keychain", isOn: $remember)
                }
                Section("Objects browser") {
                    TextField("Default schema", text: $profile.defaultSchema, prompt: Text("public"))
                        .autocorrectionDisabled()
                    Text("Enter the exact schema name, without SQL identifier quotes. Leave empty for public. This sets the Objects filter; it does not change the SQL search path.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Environment") {
                    Picker("Environment", selection: $profile.environment) {
                        Text("Unclassified").tag(ConnectionEnvironment.unknown)
                        Text("Development").tag(ConnectionEnvironment.development)
                        Text("Production").tag(ConnectionEnvironment.production)
                    }
                    .disabled(candidate?.environment == .production)
                    Text("Connections start in Manual mode. Only development connections can opt into Auto mode for a query tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if inputMethod == .manual {
                    Section("Transport security") {
                        Picker("TLS", selection: $profile.tls) { ForEach(TLSMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                        if profile.tls == .verifyFull {
                            TextField("CA certificate path", text: $profile.rootCertificate, prompt: Text("/etc/ssl/cert.pem"))
                            Text("Leave empty for the macOS PEM trust bundle, or provide your server's CA certificate. Keychain trust overrides are not used.").font(.caption).foregroundStyle(.secondary)
                        } else if profile.tls == .require {
                            Text("Encryption is required; hostname verification is not enabled.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).disabled(saving || loadingCredentials)
            HStack {
                if saving || loadingCredentials { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.dismissConnectionEditor(); dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(catalogIntent == nil ? "Save & Connect" : "Save & Load Objects") {
                    guard let connection = resolvedConnection else { return }
                    let savePassword = remember
                    saving = true; failure = nil
                    Task {
                        do {
                            if let catalogIntent {
                                try await model.saveCatalogConnection(profile: connection.profile, password: connection.password, remember: savePassword, intent: catalogIntent, loadObjects: false)
                            } else {
                                try await model.saveAndConnect(profile: connection.profile, password: connection.password, remember: savePassword, target: target)
                            }
                            if bindProject, let candidate {
                                let bound = await model.project.bind(profile: connection.profile, key: candidate.sourceGroup.lowercased().replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-")),
                                    schema: connection.profile.defaultSchema, candidateID: candidate.id, expectedReview: projectReview)
                                if !bound { model.error = model.project.error ?? "The connection was saved. Review its project binding again." }
                            }
                            if catalogIntent != nil {
                                model.loadCatalogConnection(connection.profile, password: connection.password)
                            }
                            model.dismissConnectionEditor()
                            dismiss()
                        }
                        catch { failure = error.localizedDescription; saving = false }
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || loadingCredentials || resolvedConnection == nil || (candidate != nil && !reviewedProjectCandidate))
            }.padding(20)
        }
        .frame(width: 560, height: 680)
        .task {
            guard editorIsCurrent, model.profiles.contains(where: { $0.id == profile.id }) else { return }
            loadingCredentials = true
            defer { loadingCredentials = false }
            do {
                let value = try await model.persistence.password(for: profile.id)
                guard editorIsCurrent else { return }
                password = value
            }
            catch { failure = error.localizedDescription }
        }
    }

    private var editorIsCurrent: Bool {
        if let catalogIntent { return model.catalogConnectionEditIntent == catalogIntent }
        guard let target else { return false }
        return model.worksheet(id: target.worksheetID)?.acceptsConnectionIntent(target.intent) == true
    }

    private var currentParsedURL: ParsedPostgresConnectionURL? {
        parsedSource == connectionURL && !parsingURL ? parsedURL : nil
    }

    private var resolvedConnection: (profile: ConnectionProfile, password: String)? {
        if inputMethod == .url {
            guard let parsed = currentParsedURL else { return nil }
            var connection = parsed.profile
            connection.id = profile.id
            connection.name = profile.name
            connection.defaultSchema = resolvedDefaultSchema
            connection.environment = profile.environment
            return (connection, parsed.password ?? urlPassword)
        }
        guard !profile.host.isEmpty, !profile.database.isEmpty, !profile.username.isEmpty,
              (1...65535).contains(profile.port) else { return nil }
        var connection = profile
        connection.defaultSchema = resolvedDefaultSchema
        return (connection, password)
    }

    private var resolvedDefaultSchema: String { profile.defaultSchema.isEmpty ? "public" : profile.defaultSchema }

    @ViewBuilder
    private var urlFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection URL")
            HStack(spacing: 10) {
                Group {
                    if showingURL {
                        TextField("Connection URL", text: $connectionURL, prompt: Text("postgresql://user:password@host:5432/database"))
                    } else {
                        SecureField("Connection URL", text: $connectionURL, prompt: Text("postgresql://user:password@host:5432/database"))
                    }
                }
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                Button { showingURL.toggle() } label: {
                    Image(systemName: showingURL ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .help(showingURL ? "Hide connection URL" : "Show connection URL")
                .accessibilityLabel(showingURL ? "Hide connection URL" : "Show connection URL")
            }
            Text("Paste a postgres:// or postgresql:// URL. TLS defaults to certificate and hostname verification.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: connectionURL) { await parseURLDraft() }
        if parsingURL {
            ProgressView("Reading connection URL…").controlSize(.small)
        } else if let urlFailure {
            Text(urlFailure).font(.callout).foregroundStyle(.red)
        }
        if let parsed = currentParsedURL {
            LabeledContent("Host", value: parsed.profile.host)
            LabeledContent("Port", value: String(parsed.profile.port))
            LabeledContent("Database", value: parsed.profile.database)
            LabeledContent("Username", value: parsed.profile.username)
            LabeledContent("TLS", value: parsed.profile.tls.title)
            if !parsed.profile.rootCertificate.isEmpty {
                LabeledContent("CA certificate", value: parsed.profile.rootCertificate)
            }
            if parsed.password == nil {
                SecureField("Password", text: $urlPassword)
                    .help("This URL has no password. Enter one here if your server requires it.")
            }
        }
    }

    private func changeInputMethod(_ method: InputMethod) {
        guard method != inputMethod else { return }
        if method == .manual {
            if let connection = resolvedConnection {
                profile = connection.profile
                password = connection.password
            }
            manualURLSnapshot = PostgresConnectionURL.string(from: profile, password: password)
        } else {
            let updatedURL = PostgresConnectionURL.string(from: profile, password: password)
            // Preserve the original pasted URL unless the manual fields changed.
            if connectionURL.isEmpty || updatedURL != manualURLSnapshot { connectionURL = updatedURL }
            showingURL = false
        }
        parsingURL = false
        failure = nil
        inputMethod = method
    }

    private func parseURLDraft() async {
        let source = connectionURL
        let base = profile
        parsedURL = nil
        parsedSource = nil
        urlFailure = nil
        failure = nil
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsingURL = false
            return
        }
        parsingURL = true
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try PostgresConnectionURL.parse(source, applyingTo: base) }
        }.value
        guard !Task.isCancelled, source == connectionURL, inputMethod == .url else { return }
        parsingURL = false
        parsedSource = source
        switch result {
        case .success(let parsed): parsedURL = parsed
        case .failure(let error): urlFailure = error.localizedDescription
        }
    }
}
