import SwiftUI
import DB3Core
import DB3Projects

struct ProjectSidebarStatus: View {
    @Bindable var project: ProjectWorkspaceModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.teal)
            Button { project.showingDetails = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).lineLimit(1)
                    Text(project.unsavedSettings ? "Changes not saved" : project.status.rawValue)
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Project connections, namespaces and inspection")
            if project.status == .inspecting { ProgressView().controlSize(.mini) }
            Menu {
                Button("Project Details…") { project.showingDetails = true }
                Button("Refresh Project") { project.refresh(force: true) }
                Button("Reveal Project Settings File") { project.revealSettings() }
                Divider()
                Button("Close Project") { project.close() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Project actions")
        }.padding(.horizontal, 12).padding(.vertical, 7)
    }
}

struct ProjectDetailsSheet: View {
    let model: WorkbenchModel
    @Bindable var project: ProjectWorkspaceModel
    @State private var selectedProfile: UUID?
    @State private var bindingKey = "local-app"
    @State private var schema = "public"
    @State private var candidateID: String?
    @State private var reviewingBinding = false
    @State private var namespace = ""
    @State private var namespaceLabel = ""
    @State private var namespacePosition = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.isOpen ? project.name : "Projects").font(.title2.bold())
                    Text(project.isOpen ? project.status.rawValue : "Open a folder to inspect configuration and model metadata.").foregroundStyle(.secondary)
                }
                Spacer()
                if project.isOpen { Button("Refresh", systemImage: "arrow.clockwise") { project.refresh(force: true) } }
                Button("Done") { project.showingDetails = false }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            Form {
                if let error = project.error {
                    Section {
                        Text(error).foregroundStyle(.orange)
                        if let missing = project.missingRecent {
                            Button("Locate “\(missing.name)”…") { project.showingDetails = false; project.chooseFolder(relocating: missing) }
                        }
                    }
                }
                if !project.isOpen {
                    Section { Button("Open Project Folder…") { project.showingDetails = false; project.chooseFolder() } }
                } else {
                    overview
                    connections
                    bindings
                    namespaces
                    diagnostics
                }
            }.formStyle(.grouped)
        }.frame(minWidth: 620, idealWidth: 700, maxWidth: .infinity, minHeight: 500, idealHeight: 760, maxHeight: .infinity)
    }
    private var overview: some View {
        Section("Inspection") {
            if let snapshot = project.snapshot {
                LabeledContent("Adapter", value: snapshot.adapterID + " " + (snapshot.detection.frameworkVersion ?? ""))
                LabeledContent("Source coverage", value: "\(snapshot.sourceFileCount) files · \(snapshot.models.count) models · \(snapshot.completeness.rawValue)")
                LabeledContent("Last scan", value: "\(snapshot.elapsed.formatted(.number.precision(.fractionLength(2)))) s · \(snapshot.parsedFileCount) parsed")
            }
            if let date = project.lastSuccess { LabeledContent("Last successful refresh") { Text(date, style: .time) } }
            Text("Inspection reads local files. Bind a saved PostgreSQL connection to use its metadata. Source hints do not prove that a module is installed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var connections: some View {
        Section("Discovered connections") {
            if project.configuration?.candidates.isEmpty != false { Text("No connection candidates found.").foregroundStyle(.secondary) }
            ForEach(project.configuration?.candidates ?? []) { candidate in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.name).font(.headline)
                        Text(candidate.sourceGroup + " · " + candidate.environment.title).font(.caption)
                        Text("Password: " + candidate.password.status + " · " + (candidate.tls.requiresReview ? "TLS review required" : "TLS verified configuration"))
                            .font(.caption).foregroundStyle(.secondary)
                        if candidate.kind == .odooEvidence {
                            Text("Odoo application connection support is planned in task 08.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if candidate.kind == .postgresql { Button("Review…") { model.reviewProjectCandidate(candidate) } }
                }
            }
        }
    }
    private var bindings: some View {
        Section("Project bindings") {
            ForEach(project.bindings.keys.sorted(), id: \.self) { key in
                if let binding = project.bindings[key] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key).font(.headline)
                        Text((model.profiles.first { $0.id == binding.profileID }?.name ?? "Missing saved connection") + " · " + binding.schema).font(.caption)
                        if let change = project.changedCandidates[key] {
                            Label(change + ". Auto-commit suspended; review and bind again.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Button("Review Binding") {
                            selectedProfile = binding.profileID; bindingKey = key; schema = binding.schema; candidateID = binding.candidateID
                            reviewingBinding = true
                        }.controlSize(.small)
                    }
                }
            }
            DisclosureGroup("Bind a saved connection", isExpanded: $reviewingBinding) {
                Picker("Connection", selection: $selectedProfile) {
                    Text("Choose a connection").tag(nil as UUID?)
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("Logical binding name", text: $bindingKey)
                TextField("PostgreSQL schema", text: $schema)
                Picker("Configuration provenance", selection: $candidateID) {
                    Text("Manual binding").tag(nil as String?)
                    ForEach((project.configuration?.candidates ?? []).filter { $0.kind == .postgresql }) { Text($0.sourceGroup).tag(Optional($0.id)) }
                }
                Text("Confirm that this saved connection and schema correspond to these sources. Binding does not connect or change a query. Existing sessions retain any stricter transaction policy until reconnected.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Confirm Binding") {
                    guard let profile = model.profiles.first(where: { $0.id == selectedProfile }) else { return }
                    Task { await project.bind(profile: profile, key: bindingKey, schema: schema, candidateID: candidateID) }
                }.disabled(selectedProfile == nil || bindingKey.isEmpty || schema.isEmpty || project.savingSettings)
            }
        }
    }
    private var namespaces: some View {
        Section("Namespaces") {
            Toggle("Show Base", isOn: Binding(get: { project.showBase }, set: { project.setShowBase($0) })).disabled(project.savingSettings)
            Text("Assign tables using their Objects context menu. Unmatched assignments stay in the project file; a renamed or recreated table must be assigned again.")
                .font(.caption).foregroundStyle(.secondary)
            if !project.namespaceNames.isEmpty {
                Picker("Namespace", selection: $namespace) {
                    Text("Choose a namespace").tag("")
                    ForEach(project.namespaceNames, id: \.self) { Text(project.displayName($0)).tag($0) }
                }.onChange(of: namespace) { _, key in namespaceLabel = project.displayName(key) }
                TextField("Display name", text: $namespaceLabel)
                Stepper("Position: \(namespacePosition + 1)", value: $namespacePosition, in: 0...max(0, project.namespaceNames.count - 1))
                Button("Save Namespace") { project.setNamespace(namespace, displayName: namespaceLabel, position: namespacePosition) }
                    .disabled(namespace.isEmpty || namespaceLabel.isEmpty || project.savingSettings)
            }
            Button("Reveal .db3/project.json") { project.revealSettings() }
            if let message = project.settingsError {
                Text(message).foregroundStyle(.orange)
                HStack {
                    Button("Retry Save") { project.retrySettings() }.disabled(!project.unsavedSettings || project.savingSettings)
                    Button("Reload / Revert") { project.reloadSettings() }.disabled(project.savingSettings)
                }
            }
        }
    }
    private var diagnostics: some View {
        Section("Diagnostics") {
            ForEach(project.configuration?.diagnostics ?? []) { diagnostic in
                Text("\(diagnostic.source.relativePath):\(diagnostic.source.line) · \(diagnostic.message)").font(.caption).textSelection(.enabled)
            }
            ForEach(project.snapshot?.diagnostics ?? []) { diagnostic in
                Text((diagnostic.relativePath.map { $0 + ":\(diagnostic.line ?? 0) · " } ?? "") + diagnostic.message)
                    .font(.caption).textSelection(.enabled)
            }
            if project.snapshot?.diagnostics.isEmpty == true && project.configuration?.diagnostics.isEmpty == true { Text("No inspection diagnostics.").foregroundStyle(.secondary) }
        }
    }
}

struct ProjectSourceModelView: View {
    let project: ProjectWorkspaceModel
    let model: ProjectModelMetadata
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.title2.bold())
                    Text("Source model · " + model.namespace).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Project") { project.inspectedModel = nil }
                Button("Done") { project.showingDetails = false; project.inspectedModel = nil }.keyboardShortcut(.cancelAction)
            }.padding([.horizontal, .top], 20)
            Text("Source hints are advisory. PostgreSQL columns, types and constraints remain authoritative. Direct SQL does not invoke the application's ORM.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            List {
                ForEach(Array(model.fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(field.name).font(.headline); Spacer(); Text(field.declaredType).foregroundStyle(.secondary) }
                        if let label = field.displayLabel { Text(label) }
                        Text((field.stored == true ? "Stored" : field.stored == false ? "Not stored" : "Storage unresolved")
                             + (field.isDerived ? " · Computed / derived" : "") + " · " + field.resolution.rawValue).font(.caption)
                        if let target = field.relationModel { Text("Related model: " + target + " (source hint)").font(.caption) }
                        if let related = field.related { Text("Related path: " + related.joined(separator: ".")).font(.caption) }
                        if let inverse = field.inverse { Text("Inverse: " + inverse).font(.caption) }
                        if !field.choices.isEmpty || field.choicesResolution == .unresolved {
                            Text("Choices: \(field.choices.count) · \(field.choicesResolution.rawValue)").font(.caption)
                        }
                        Text(field.provenance.sourceLabel).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }
        }.frame(minWidth: 550, idealWidth: 640, minHeight: 420, idealHeight: 680)
    }
}
