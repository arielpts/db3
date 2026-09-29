import SwiftUI
import DB3Core
import DB3Editor
import DB3Grid

struct WorkbenchView: View {
    @Bindable var model: WorkbenchModel
    @State private var inspectorSelection = NSRange(location: 0, length: 0)
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            // The nested editor/results split must fit its allotted space without
            // feeding its current AppKit size back into the outer split's minimum.
            GeometryReader { _ in
                WorksheetView(sheet: model.active, model: model)
                    .id(model.active.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 420)
            // Keep inspector resizing inside the detail column, independent of the sidebar.
            .inspector(isPresented: $model.showingInspector) {
                inspector.inspectorColumnWidth(min: 240, ideal: 280, max: 400)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.teal)
        .navigationTitle("db3")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: model.newConnection) { Label("New Connection", systemImage: "plus") }.help("New PostgreSQL connection")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.active.run() } label: { Label("Run", systemImage: "play.fill") }
                    .disabled(!model.active.isConnected || model.active.isBusy).help("Run selection or statement (⌘↩)")
                Button { model.active.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }
                    .disabled(!model.active.isBusy || model.active.isCancelling).help("Cancel query (⌘.)")
                Button { model.showingInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .sheet(isPresented: $model.showingConnection) { ConnectionSheet(model: model, profile: model.editingProfile) }
        .alert("Unable to complete action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Close this database session?", isPresented: Binding(get: { model.closingWorksheet != nil }, set: { if !$0 { model.closingWorksheet = nil } })) {
            Button("Keep Working", role: .cancel) { model.closingWorksheet = nil }
            Button("Close Session", role: .destructive) { if let sheet = model.closingWorksheet { model.close(sheet) }; model.closingWorksheet = nil }
        } message: { Text("Running work will be interrupted. Uncommitted transactions are rolled back when the connection closes.") }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section("Connections") {
                    if model.profiles.isEmpty {
                        Button(action: model.newConnection) { Label("Add PostgreSQL…", systemImage: "plus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    ForEach(model.profiles) { profile in
                        Button { model.connectSaved(profile) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "externaldrive").foregroundStyle(.teal)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).lineLimit(1)
                                    Text("\(profile.host) / \(profile.database)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if model.active.profile?.id == profile.id, model.active.isConnected { Circle().fill(.green).frame(width: 6, height: 6) }
                            }.padding(.vertical, 3)
                        }.buttonStyle(.plain).disabled(model.active.isBusy)
                            .contextMenu { Button("Edit Connection…") { model.editConnection(profile) } }
                    }
                }
                Section {
                    ForEach(model.worksheets) { sheet in
                        Button { model.selectedID = sheet.id } label: {
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(model.selectedID == sheet.id ? Color.teal : .secondary)
                                Text(sheet.title).lineLimit(1)
                                Spacer()
                                if sheet.isBusy { ProgressView().controlSize(.mini) }
                            }.padding(.vertical, 4)
                        }.buttonStyle(.plain)
                            .listRowBackground(model.selectedID == sheet.id ? Color.teal.opacity(0.11) : Color.clear)
                            .contextMenu { Button("Close Worksheet") { model.requestClose(sheet) } }
                    }
                    Button(action: model.addWorksheet) { Label("New Worksheet", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
                } header: { Text("Worksheets") }
            }.listStyle(.sidebar)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.teal)
                Text("PostgreSQL workbench").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(14)
        }
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Inspector").font(.headline)
            if let value = model.active.selectedValue {
                Label(model.active.selectedColumn ?? "Value", systemImage: "rectangle.split.3x1").font(.callout.bold())
                SQLTextEditor(text: .constant(value), selection: $inspectorSelection, fontSize: 12, isEditable: false)
            } else {
                Label("Session", systemImage: "network").font(.callout.bold())
                LabeledContent("Status", value: model.active.status)
                LabeledContent("Transaction", value: model.active.transaction.title)
                if !model.active.serverVersion.isEmpty { Text(model.active.serverVersion).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Divider()
                Text("Select a result cell to inspect its value.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(20)
    }
}

private struct WorksheetView: View {
    @Bindable var sheet: Worksheet
    let model: WorkbenchModel
    @State private var resultTab = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.teal)
                Text(sheet.title).font(.callout.weight(.medium))
                if let profile = sheet.profile {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(sheet.isDemo ? "Sample workspace" : profile.database).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if sheet.isConnected, !sheet.isDemo {
                    Menu {
                        Button("Begin Transaction") { sheet.run(sql: "BEGIN") }.disabled(sheet.transaction != .idle)
                        Button("Commit") { sheet.run(sql: "COMMIT") }.disabled(sheet.transaction != .inTransaction)
                        Button("Rollback") { sheet.run(sql: "ROLLBACK") }.disabled(sheet.transaction == .idle)
                        Divider()
                        Button("Disconnect") { sheet.disconnect() }.disabled(sheet.transaction != .idle)
                    } label: { Label(sheet.transaction.title, systemImage: sheet.transaction == .idle ? "checkmark.circle" : "arrow.triangle.2.circlepath") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(sheet.isBusy)
                } else if !sheet.isConnected {
                    Button("Connect…", action: model.newConnection).controlSize(.small)
                }
            }.padding(.horizontal, 18).frame(height: 42)
            Divider()
            VSplitView {
                VStack(spacing: 0) {
                    SQLTextEditor(text: $sheet.sql, selection: $sheet.selection)
                    HStack {
                        Text("SQL").font(.caption.weight(.medium))
                        Spacer()
                        Text(sheet.selection.length > 0 ? "Selection · ⌘↩ to run" : "One statement · ⌘↩ to run").font(.caption)
                        Text("UTF-8").font(.caption).padding(.leading, 14)
                    }.foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 28)
                }.frame(minHeight: 180, idealHeight: 320)
                VStack(spacing: 0) {
                    HStack {
                        Picker("Output", selection: $resultTab) { Text("Results").tag(0); Text("Messages").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 184)
                        Spacer()
                        Menu {
                            Toggle("Use temporary disk storage", isOn: $sheet.allowsSpooling)
                            Text("Applies to the next query. Memory-only results stop at 16 MiB.")
                        } label: { Image(systemName: sheet.allowsSpooling ? "externaldrive" : "memorychip") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(sheet.isBusy).help("Result storage")
                        if sheet.rowCount > 0 {
                            Text("\(sheet.rowCount.formatted()) rows\(sheet.resultIncomplete ? " · partial" : "")").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Button(action: model.exportCSV) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                            .controlSize(.small).disabled(sheet.isBusy || sheet.columns.isEmpty)
                    }.padding(.horizontal, 16).frame(height: 44)
                    Divider()
                    if resultTab == 1 {
                        ScrollView { Text(sheet.message).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                    } else if !sheet.columns.isEmpty {
                        ResultsGrid(columns: sheet.columns, rowCount: sheet.rowCount, revision: sheet.revision, loadRows: { [store = sheet.store] range in
                            try await store.rows(in: range)
                        }, onSelect: { _, column, value in
                            sheet.selectedColumn = column.name
                            sheet.selectedValue = value.displayText
                            model.showingInspector = true
                        })
                    } else {
                        emptyResults.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minHeight: 220, idealHeight: 390)
            }
            Divider()
            HStack(spacing: 8) {
                if sheet.isBusy { ProgressView().controlSize(.mini) }
                else { Circle().fill(sheet.error != nil ? Color.orange : sheet.isConnected ? .green : .secondary).frame(width: 6, height: 6) }
                Text(sheet.status).font(.caption.weight(.medium))
                if !sheet.isBusy, sheet.elapsed > 0 { Text("· \(sheet.elapsed, specifier: "%.3f") s").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                if sheet.resultIncomplete, sheet.rowCount > 0 { Text("Incomplete result").font(.caption).foregroundStyle(.orange) }
                Text(sheet.isDemo ? "LOCAL SAMPLE" : "POSTGRESQL").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 16).frame(height: 30)
        }
    }
    @ViewBuilder private var emptyResults: some View {
        if let error = sheet.error {
            ContentUnavailableView { Label(sheet.status, systemImage: "exclamationmark.bubble") } description: { Text(error).textSelection(.enabled) }
        } else if sheet.isBusy {
            ContentUnavailableView("Running your query", systemImage: "waveform.path", description: Text("Results will appear as PostgreSQL returns them."))
        } else if sheet.isConnected {
            ContentUnavailableView("Ready when you are", systemImage: "tablecells", description: Text("Run a statement to explore its results here."))
        } else {
            ContentUnavailableView {
                Label("Your database, at your fingertips", systemImage: "tablecells")
            } description: {
                Text("Connect to PostgreSQL and start exploring.")
            } actions: {
                HStack {
                    Button("Connect to PostgreSQL…", action: model.newConnection).buttonStyle(.borderedProminent)
                    Button("Explore Sample Data", action: model.sample)
                }
            }
        }
    }
}
