import AppKit
import SwiftUI
import DB3Core

/// The browser owns only catalog selection. Preparing SQL crosses into a new tab
/// through a value snapshot; neither row selection nor double-click executes it.
struct ObjectBrowserView: View {
    @Bindable var browser: ObjectBrowserModel
    var project: ProjectWorkspaceModel? = nil
    @State private var namespaceTarget: DatabaseObject?
    @State private var newNamespace = ""
    let canAddQuery: Bool
    let openQuery: () -> Void
    var openEditing: (() -> Void)? = nil
    let editConnection: (ConnectionProfile) -> Void
    @FocusState private var searchFocused: Bool

    private let catalogHelp = "Objects reflect committed database structure in a separate connection. Query tabs keep their own transactions, temporary tables, role, and search path. Refresh reads metadata only; it never refreshes a materialized view. Access labels are advisory."

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Objects").font(.headline)
                    Spacer(minLength: 4)
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                        .help(catalogHelp).accessibilityLabel(catalogHelp)
                    Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Search objects (⌥⌘F)")
                        .accessibilityLabel("Search objects")
                        .keyboardShortcut("f", modifiers: [.command, .option])
                        .disabled(browser.selectedProfile == nil)
                    Menu {
                        Button("Refresh Objects", systemImage: "arrow.clockwise") { browser.refresh() }
                            .disabled(browser.selectedProfile == nil || browser.isBusy)
                        Button("Disconnect Browser", systemImage: "network.slash") { browser.disconnect() }
                            .disabled(browser.selectedProfile == nil)
                        if let profile = browser.selectedProfile {
                            Button("Enter Password…", systemImage: "key") { browser.requestCredentials() }
                            Button("Connection Settings…", systemImage: "slider.horizontal.3") { editConnection(profile) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Object browser actions")
                }
                if let profile = browser.selectedProfile {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Label(profile.database, systemImage: "cylinder.split.1x2")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help("\(profile.name) · \(profile.database) · \(profile.host)")
                }
                TextField("Search objects", text: $browser.searchText)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .autocorrectionDisabled()
                    .onExitCommand {
                        if !browser.searchText.isEmpty { browser.searchText = "" }
                        else { searchFocused = false }
                    }
                    .disabled(browser.selectedProfile == nil)
                    .accessibilityLabel("Search objects")
                HStack(spacing: 6) {
                    Picker("Schema", selection: $browser.schema) {
                        Text("All Schemas").tag(nil as String?)
                        ForEach(browser.schemaOptions, id: \.self) { schema in
                            Text(schema).tag(Optional(schema))
                        }
                    }
                    .accessibilityLabel("Filter schema")
                    .help("Filter objects by schema. Set the default in Connection Settings.")
                    Picker("Object kind", selection: $browser.kind) {
                        Text("All Objects").tag(nil as DatabaseObjectKind?)
                        ForEach(DatabaseObjectKind.allCases, id: \.self) { kind in
                            Text(kind.pluralTitle).tag(Optional(kind))
                        }
                    }
                    .accessibilityLabel("Filter object kind")
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                .disabled(browser.selectedProfile == nil)
                if let project, project.binding(for: browser.selectedProfile ?? ConnectionProfile()) != nil {
                    HStack(spacing: 6) {
                        Picker("Namespace", selection: Binding(get: { project.selectedNamespace }, set: { project.selectedNamespace = $0 })) {
                            Text("All Namespaces").tag(nil as String?)
                            ForEach(project.namespaceNames, id: \.self) { Text(project.displayName($0)).tag(Optional($0)) }
                            Text("Unclassified").tag(Optional("unclassified"))
                        }.labelsHidden().controlSize(.small)
                        Toggle("Base", isOn: Binding(get: { project.showBase }, set: { project.setShowBase($0) }))
                            .toggleStyle(.checkbox).controlSize(.small).help("Show framework Base objects")
                            .disabled(project.savingSettings)
                    }
                    if project.status == .partial || project.status == .unavailable {
                        Text("Project coverage is incomplete; unmatched objects are Unclassified.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if browser.schemasTruncated {
                    Text("Schema list limited. Set another schema in Connection Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)

            if browser.isBusy || browser.isOutOfDate || browser.errorMessage != nil || browser.phase == .cancelled || browser.phase == .disconnected {
                status.padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            if browser.objects.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $browser.selectedObjectID) {
                    if let project, let profile = browser.selectedProfile, project.binding(for: profile) != nil {
                        ForEach(project.groups(browser.objects)) { group in
                            Section(group.title) { ForEach(group.objects) { object in objectRow(object) } }
                        }
                    } else { ForEach(browser.objects) { object in objectRow(object) } }
                }
                .listStyle(.sidebar)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .opacity(browser.isOutOfDate ? 0.65 : 1)
                .accessibilityLabel("Database objects")
            }
            footer
        }
        .alert("Assign Namespace", isPresented: Binding(get: { namespaceTarget != nil }, set: { if !$0 { namespaceTarget = nil } })) {
            TextField("Namespace", text: $newNamespace)
            Button("Cancel", role: .cancel) { namespaceTarget = nil }
            Button("Save") {
                if let object = namespaceTarget { Task { await project?.assign(object, namespace: newNamespace) } }
                namespaceTarget = nil
            }.disabled(newNamespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("The assignment is saved in this project's .db3/project.json.") }
    }

    private func objectRow(_ object: DatabaseObject) -> some View {
        ObjectBrowserRow(object: object, showsSchemaAndKind: browser.schema == nil,
                         modelName: project?.sourceModel(for: object)?.name)
            .tag(object.id)
            .simultaneousGesture(TapGesture(count: 2).onEnded { openObject(object) })
            .accessibilityAction(.default) { openObject(object) }
            .contextMenu {
                if let openEditing {
                    Button("Edit Table Data", systemImage: "square.and.pencil") {
                        browser.selectedObjectID = object.id; openEditing()
                    }.disabled(!browser.canUseObjects || !canAddQuery || object.kind != .table || object.isPartition || object.isPartitioned)
                }
                Button("New SELECT Query", systemImage: "doc.badge.plus") {
                    browser.selectedObjectID = object.id; openQuery()
                }.disabled(!browser.canUseObjects || !canAddQuery)
                Button("Copy Qualified Name", systemImage: "doc.on.doc") { copyName(object) }.disabled(!browser.canUseObjects)
                if let project, project.binding(for: object.id.source.profile) != nil {
                    if project.sourceModel(for: object) != nil { Button("Model Metadata…") { project.inspectModel(for: object) } }
                    Menu("Assign Namespace") {
                        ForEach(project.namespaceNames, id: \.self) { namespace in
                            Button(project.displayName(namespace)) { Task { await project.assign(object, namespace: namespace) } }
                        }
                        Button("New Namespace…") { namespaceTarget = object; newNamespace = "" }
                    }.disabled(!browser.canUseObjects || project.savingSettings)
                }
            }
            .accessibilityAddTraits(browser.selectedObjectID == object.id ? .isSelected : [])
    }

    private func openObject(_ object: DatabaseObject) {
        guard browser.canUseObjects, canAddQuery,
              browser.objects.contains(where: { $0.id == object.id }) else { return }
        browser.selectedObjectID = object.id
        if object.kind == .table, !object.isPartition, !object.isPartitioned, let openEditing {
            openEditing()
        } else {
            openQuery()
        }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            if browser.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(browser.phase == .refreshing ? "Refreshing…" : browser.phase == .loadingMore ? "Loading more…" : "Loading objects…")
                        .font(.caption)
                    Spacer(minLength: 0)
                    Button("Cancel") { browser.cancel() }.controlSize(.small)
                }
            }
            if browser.isOutOfDate && !browser.objects.isEmpty {
                Label("Out of date", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = browser.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(4).help(error).textSelection(.enabled)
                if !browser.isBusy {
                    HStack {
                        Button("Retry") { browser.load() }
                        if let profile = browser.selectedProfile {
                            Menu("Connection…") {
                                Button("Enter Password…") { browser.requestCredentials() }
                                Button("Settings…") { editConnection(profile) }
                            }
                        }
                    }.controlSize(.small)
                }
            } else if browser.phase == .cancelled || browser.phase == .disconnected {
                HStack {
                    Text(browser.phase == .cancelled ? "Loading cancelled" : "Browser disconnected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Retry") { browser.load() }.controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            switch browser.phase {
            case .noSelection:
                Text("Select a connection to browse objects")
            case .notLoaded:
                Text("Browse tables, views, and materialized views")
                Button("Load Objects") { browser.load() }
            case .loaded:
                if browser.searchText.isEmpty && browser.kind == nil {
                    Text(browser.schema.map { "No objects found in schema \($0)" }
                        ?? "No tables, views, or materialized views found")
                    Button("Refresh") { browser.refresh() }
                } else {
                    Text("No objects match your search")
                    Button("Clear Search") { browser.searchText = ""; browser.kind = nil }
                }
            case .loading, .refreshing, .loadingMore:
                Text("Reading database objects…")
            case .credentialsRequired:
                Text("Credentials are needed to browse objects")
            case .failed:
                Text("Objects could not be loaded")
            case .cancelled:
                Text("Choose Retry when you’re ready")
            case .disconnected:
                Text("Your query connections are independent of this browser")
            }
        }
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .padding(16)
    }

    @ViewBuilder private var footer: some View {
        if !browser.objects.isEmpty || browser.phase == .loaded {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(browser.objects.count) loaded").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(browser.isBusy)
                        .accessibilityLabel("Refresh objects").help("Refresh objects")
                }
                if browser.reachedDisplayLimit {
                    Text("Narrow your search to see more objects")
                        .font(.caption).foregroundStyle(.secondary)
                } else if browser.hasMore {
                    Button("Load More") { browser.loadMore() }
                        .controlSize(.small).disabled(browser.isBusy || !browser.canUseObjects)
                }
                HStack(spacing: 6) {
                    Button(action: openQuery) { Label("New SELECT Query", systemImage: "doc.badge.plus") }
                        .disabled(!browser.canUseObjects || browser.selectedObject == nil || !canAddQuery)
                        .help(canAddQuery ? "Prepare a new query tab; SQL runs only when you choose Run" : "Close a query tab to open another (maximum four)")
                    Spacer(minLength: 0)
                    Button {
                        if let object = browser.selectedObject { copyName(object) }
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .disabled(!browser.canUseObjects || browser.selectedObject == nil)
                    .accessibilityLabel("Copy qualified name").help("Copy qualified name")
                }.controlSize(.small)
                if let openEditing {
                    Button("Edit Table Data", systemImage: "square.and.pencil", action: openEditing)
                        .controlSize(.small)
                        .disabled(!browser.canUseObjects || !canAddQuery || browser.selectedObject?.kind != .table
                                  || browser.selectedObject?.isPartition != false || browser.selectedObject?.isPartitioned != false)
                        .help("Open an editable table query using this object's connection. Choose Run to load rows.")
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func copyName(_ object: DatabaseObject) {
        guard browser.canUseObjects, let current = browser.objects.first(where: { $0.id == object.id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.quotedQualifiedName, forType: .string)
    }
}

private struct ObjectBrowserRow: View {
    let object: DatabaseObject
    let showsSchemaAndKind: Bool
    var modelName: String? = nil
    private var symbol: String {
        switch object.kind {
        case .table: "tablecells"
        case .view: "eye"
        case .materializedView: "square.stack.3d.up"
        }
    }
    private var statusLabels: [String] {
        var labels: [String] = []
        if object.isPartitioned { labels.append("Partitioned") }
        if object.isPartition { labels.append("Partition") }
        if object.isPopulated == false { labels.append("Not populated") }
        if !object.hasSchemaUsage { labels.append("No schema access") }
        else if !object.hasTableSelect {
            labels.append(object.hasAnyColumnSelect ? "Column access only" : "No SELECT grant")
        }
        return labels
    }
    private var details: String {
        ([object.schema, object.kind.title] + statusLabels).joined(separator: " · ")
    }
    private var subtitle: String {
        ((showsSchemaAndKind ? [object.schema, object.kind.title] : []) + statusLabels)
            .joined(separator: " · ")
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(object.name).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if let modelName { Text(modelName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()).help("\(object.quotedQualifiedName)\n\(details)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(object.name), \(details)")
    }
}

struct CatalogCredentialSheet: View {
    let browser: ObjectBrowserModel
    let request: ObjectBrowserCredentialRequest
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browse \(request.profile.name)").font(.title2.bold()).lineLimit(2)
            Text("\(request.profile.username) · \(request.profile.database) · \(request.profile.host)")
                .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            ScrollView {
                Text(request.message).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).focused($passwordFocused)
            Text("This password is used for the browser session. Use Connection Settings to save it in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { password = ""; browser.dismissCredentialRequest(request.id) }
                    .keyboardShortcut(.cancelAction)
                Button("Load Objects") {
                    let value = password; password = ""
                    browser.submitPassword(value, for: request.id)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 420)
        .onAppear { passwordFocused = true }
        .onDisappear { password = "" }
    }
}
