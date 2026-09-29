import SwiftUI
import DB3Core
import DB3Editor
import DB3Grid

struct WorksheetView: View {
    @Bindable var sheet: Worksheet
    let model: WorkbenchModel
    private var isActive: Bool { model.selectedID == sheet.id && !sheet.isClosing }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive").foregroundStyle(.teal)
                if let profile = sheet.profile {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sheet.isDemo ? "Sample workspace" : profile.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(sheet.isDemo ? "Generated locally" : "\(profile.database) · \(profile.host):\(profile.port)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.help("\(profile.name) · \(profile.database) · \(profile.host):\(profile.port)")
                    if sheet.isConnected, let saved = model.profiles.first(where: { $0.id == profile.id }), saved != profile {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                            .help("Saved connection settings changed. This tab keeps its current session until you explicitly choose the updated connection.")
                    }
                } else {
                    Text("No connection").font(.callout).foregroundStyle(.secondary)
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
                    .menuStyle(.borderlessButton).fixedSize().disabled(sheet.isBusy || !sheet.canIssueCommands)
                } else if !sheet.isConnected {
                    Button(sheet.profile == nil ? "New Connection…" : "Connect") { model.connectWorksheet(sheet) }
                        .controlSize(.small).disabled(sheet.isBusy || !sheet.canIssueCommands)
                }
                Menu {
                    ForEach(model.profiles) { profile in
                        Button("\(profile.name) — \(profile.database)") { model.connectSaved(profile, in: sheet) }
                    }
                    if !model.profiles.isEmpty { Divider() }
                    Button("New Connection…") { model.newConnection(in: sheet) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(sheet.isBusy || !sheet.canIssueCommands || sheet.transaction == .inTransaction || sheet.transaction == .failed)
                .help("Choose connection for this query tab")
            }.padding(.horizontal, 18).frame(height: 42)
            Divider()
            VSplitView {
                VStack(spacing: 0) {
                    SQLTextEditor(text: $sheet.sql, selection: $sheet.selection,
                                  isEditable: !sheet.isLoading && !sheet.isClosing && !sheet.isClosePending && !model.isRestoringWorkspace,
                                  isActive: isActive)
                        .overlay {
                            if sheet.isLoading { ProgressView("Loading SQL…") }
                        }
                    HStack {
                        Text("SQL").font(.caption.weight(.medium))
                        Spacer()
                        Text(sheet.selection.length > 0 ? "Selection · ⌘↩ to run" : "Statement at cursor · ⌘↩ to run").font(.caption)
                        Text("UTF-8").font(.caption).padding(.leading, 14)
                    }.foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 28)
                }.frame(minHeight: 180, idealHeight: 320)
                VStack(spacing: 0) {
                    HStack {
                        Picker("Output", selection: $sheet.resultTab) { Text("Results").tag(0); Text("Messages").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 184)
                        Spacer()
                        Menu {
                            Toggle("Use temporary disk storage", isOn: $sheet.allowsSpooling)
                            Text("Applies to the next query. Memory-only results stop at 16 MiB.")
                        } label: { Image(systemName: sheet.allowsSpooling ? "externaldrive" : "memorychip") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(sheet.isBusy || !sheet.canIssueCommands).help("Result storage")
                        if sheet.rowCount > 0 {
                            Text("\(sheet.rowCount.formatted()) rows\(sheet.resultIncomplete ? " · partial" : "")").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Button { model.exportCSV(sheet: sheet) } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                            .controlSize(.small).disabled(sheet.isBusy || sheet.columns.isEmpty || !sheet.canIssueCommands)
                    }.padding(.horizontal, 16).frame(height: 44)
                    Divider()
                    ZStack {
                        // Keep the same grid alive when Messages is selected.
                        // A new result revision still resets it deliberately.
                        if !sheet.columns.isEmpty {
                            ResultsGrid(columns: sheet.columns, rowCount: sheet.rowCount, revision: sheet.revision,
                                        isActive: isActive && sheet.resultTab == 0,
                                        loadRows: { [store = sheet.store] range in try await store.rows(in: range) },
                                        onSelect: { _, column, value in
                                guard model.selectedID == sheet.id, !sheet.isClosing else { return }
                                sheet.selectedColumn = column.name
                                sheet.selectedValue = value.displayText
                            })
                            .opacity(sheet.resultTab == 0 ? 1 : 0)
                            .allowsHitTesting(sheet.resultTab == 0)
                            .accessibilityHidden(sheet.resultTab != 0)
                        } else if sheet.resultTab == 0 {
                            emptyResults.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        ScrollView {
                            Text(sheet.message).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        }
                        .opacity(sheet.resultTab == 1 ? 1 : 0)
                        .allowsHitTesting(sheet.resultTab == 1)
                        .accessibilityHidden(sheet.resultTab != 1)
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
                    Button(sheet.profile == nil ? "New PostgreSQL Connection…" : "Connect to PostgreSQL") { model.connectWorksheet(sheet) }
                        .buttonStyle(.borderedProminent)
                    Button("Explore Sample Data") { model.sample(in: sheet) }
                }
                .disabled(!sheet.canIssueCommands || sheet.isBusy)
            }
        }
    }
}
