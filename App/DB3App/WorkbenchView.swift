import AppKit
import SwiftUI
import DB3Core

struct WorkbenchView: View {
    @Bindable var model: WorkbenchModel
    @State private var hosts = QueryViewHosts()
    @State private var presentedConnection: ConnectionPresentation?

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                QueryTabBar(model: model)
                Divider()
                GeometryReader { _ in
                    QueryTabContentHost(model: model, hosts: hosts)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420)
            .inspector(isPresented: $model.showingInspector) {
                QueryTabContentHost(model: model, hosts: hosts, kind: .inspector)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.teal)
        .navigationTitle("db3")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.project.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in model.project.refresh(force: true) }
        .disabled(model.isRestoringWorkspace || model.isPreservingWorkspace)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: model.newConnection) { Label("New Connection", systemImage: "plus") }
                    .help("New PostgreSQL connection")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.active.run() } label: { Label("Run", systemImage: "play.fill") }
                    .disabled(!model.active.isConnected || model.active.isBusy || !model.active.canIssueCommands)
                    .help("Run selection or statement at cursor (⌘↩)")
                Button { model.active.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }
                    .disabled(!model.active.isBusy || model.active.isCancelling || model.active.isClosing)
                    .help("Cancel query (⌘.)")
                Button { model.showingInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .onChange(of: connectionPresentations.map(\.id), initial: true) { _, _ in
            let pending = connectionPresentations
            if let presentedConnection, pending.contains(where: { $0.id == presentedConnection.id }) { return }
            presentedConnection = pending.first
        }
        // One presenter serializes editor, query-password, and browser-password
        // requests. A later lookup cannot replace a sheet the user is filling in.
        .sheet(item: Binding(get: { presentedConnection }, set: { _ in })) { presentation in
            Group {
                switch presentation {
                case .project:
                    if let sourceModel = model.project.inspectedModel {
                        ProjectSourceModelView(project: model.project, model: sourceModel)
                    } else { ProjectDetailsSheet(model: model, project: model.project) }
                case .editor:
                    ConnectionSheet(model: model, profile: model.editingProfile)
                case .worksheet(let request):
                    WorksheetCredentialSheet(model: model, request: request)
                case .catalog(let request):
                    CatalogCredentialSheet(browser: model.objectBrowser, request: request)
                }
            }
            .interactiveDismissDisabled()
        }
        .alert("Unable to complete action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var connectionPresentations: [ConnectionPresentation] {
        var pending: [ConnectionPresentation] = []
        if model.showingConnection, let id = model.connectionEditTarget?.intent ?? model.catalogConnectionEditIntent {
            pending.append(.editor(id))
        }
        if let request = model.worksheetCredentialRequest { pending.append(.worksheet(request)) }
        if let request = model.objectBrowser.credentialRequest { pending.append(.catalog(request)) }
        if model.project.showingDetails { pending.append(.project) }
        return pending
    }

    private enum ConnectionPresentation: Identifiable {
        case project
        case editor(UUID)
        case worksheet(WorksheetCredentialRequest)
        case catalog(ObjectBrowserCredentialRequest)

        var id: UUID {
            switch self {
            case .project: UUID(uuidString: "3A43C70C-06D9-43CA-A510-7F1AC0C07BD3")!
            case .editor(let id): id
            case .worksheet(let request): request.id
            case .catalog(let request): request.id
            }
        }
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if model.project.isOpen { ProjectSidebarStatus(project: model.project); Divider() }
                connections.frame(height: 26 + min(
                    CGFloat(max(1, model.visibleProfiles.count)) * 44,
                    max(44, min(176, geometry.size.height * 0.22))
                ))
                Divider()
                ObjectBrowserView(browser: model.objectBrowser, project: model.project, canAddQuery: model.canAddWorksheet,
                    openQuery: model.openSelectedObjectQuery, openEditing: model.openSelectedObjectForEditing,
                    editConnection: model.editBrowserConnection)
                    .frame(maxHeight: .infinity)
                    .disabled(model.isCoordinatingClose)
            }
        }
    }

    private var connections: some View {
        VStack(spacing: 0) {
            Text("Connections")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.visibleProfiles.isEmpty {
                        Button {
                            if model.project.isOpen { model.project.showingDetails = true }
                            else { model.newConnection() }
                        } label: {
                            Label(model.project.isOpen ? "Project Connections…" : "Add PostgreSQL…", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    ForEach(model.visibleProfiles) { profile in
                        Button { model.selectBrowserProfile(profile) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "externaldrive").foregroundStyle(.teal)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).lineLimit(1)
                                    Text("\(profile.host) / \(profile.database)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if model.worksheets.contains(where: { $0.profile?.id == profile.id && $0.isConnected }) {
                                    Circle().fill(.green).frame(width: 6, height: 6)
                                        .accessibilityLabel("Has an open query connection")
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(model.selectedBrowserProfileID == profile.id ? Color.teal.opacity(0.12) : .clear)
                        .accessibilityAddTraits(model.selectedBrowserProfileID == profile.id ? .isSelected : [])
                        .contextMenu {
                            Button("Edit Connection…") { model.editBrowserConnection(profile) }
                        }
                    }
                }
            }
            .contentMargins(0, for: .scrollContent)
            .accessibilityLabel("Connections")
        }
    }
}
