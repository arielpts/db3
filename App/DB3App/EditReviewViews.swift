import AppKit
import SwiftUI
import DB3Core

struct EditPreviewView: View {
    @Bindable var sheet: Worksheet
    let plan: EditPlan
    @State private var search = ""
    @State private var visible: [Int] = []
    @State private var selected: Int? = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview Changes").font(.title2.bold())
                Spacer()
                Text("\(plan.environment.title) · \(plan.mode.title)").font(.headline)
            }
            Text("\(sheet.profile?.name ?? "Connection") · \(sheet.profile?.database ?? "") · \(plan.table.quotedName)")
                .foregroundStyle(.secondary).lineLimit(1)
            Text("\(plan.statements.filter { !$0.isInsert }.count) row updates · \(plan.statements.filter(\.isInsert).count) new rows. Applying includes every change, even those hidden by search.")
                .font(.callout)
            TextField("Find a row or changed column", text: $search).textFieldStyle(.roundedBorder)
            HSplitView {
                List(visible, id: \.self, selection: $selected) { index in
                    let statement = plan.statements[index]
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statement.isInsert ? "New row" : "Row \(statement.rowIndex + 1)").font(.headline)
                        Text(plan.table.primaryKeyColumns.map { column in
                            let value = statement.row?.original.values[column.index] ?? statement.insertedRow?.values[column.index]
                            return "\(column.name): \(String((value?.displayText ?? "DEFAULT").prefix(100)))"
                        }.joined(separator: " · ")).font(.caption).lineLimit(2)
                        Text(statement.isInsert ? "\(statement.insertedRow?.values.count ?? 0) supplied values" : "\(statement.row?.replacements.count ?? 0) changed values").font(.caption).foregroundStyle(.secondary)
                    }.tag(index)
                }.frame(minWidth: 190, idealWidth: 220)
                ScrollView {
                    if let selected, plan.statements.indices.contains(selected) {
                        let statement = plan.statements[selected]
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(statement.isInsert ? plan.table.columns.map(\.index) : (statement.row?.replacements.keys.sorted() ?? []), id: \.self) { index in
                                let column = plan.table.columns[index]
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(column.name).font(.headline)
                                    HStack(alignment: .top) {
                                        if let row = statement.row, let replacement = row.replacements[index] {
                                            EditValueText(value: row.original.values[index]).frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: "arrow.right")
                                            EditValueText(value: replacement).frame(maxWidth: .infinity, alignment: .leading)
                                        } else if let value = statement.insertedRow?.values[index] {
                                            EditValueText(value: value)
                                        } else {
                                            Text(column.hasDefault ? "DEFAULT — supplied by PostgreSQL" : column.nullable ? "DEFAULT — NULL" : "DEFAULT")
                                                .italic().foregroundStyle(.secondary)
                                        }
                                    }
                                    if let metadata = column.applicationMetadata, metadata.requiresWarning,
                                       statement.row?.replacements[index] != nil || statement.insertedRow?.values[index] != nil {
                                        Label(FieldEditorMetadata.directSQLWarning, systemImage: "exclamationmark.triangle")
                                            .font(.caption).foregroundStyle(.orange)
                                        Text("\(metadata.modelField) · \(metadata.source)").font(.caption)
                                    }
                                }
                                Divider()
                            }
                            HStack {
                                Text("SQL").font(.headline)
                                Spacer()
                                Button("Copy SQL") { copy(statement.sql) }.controlSize(.small)
                            }
                            Text(statement.sql).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Text("Bound parameters").font(.headline)
                            ForEach(statement.parameters.indices, id: \.self) { index in
                                let parameter = statement.parameters[index]
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("$\(index + 1) · \(parameter.typeSQL)").font(.caption.weight(.semibold))
                                    EditValueText(value: parameter.value)
                                }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(minWidth: 420)
            }
            Text("The preview describes submitted commands. Database triggers may cause additional changes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if sheet.isBusy {
                    ProgressView().controlSize(.small); Text(sheet.status)
                    Button("Cancel Apply") { sheet.cancel() }.disabled(sheet.isCancelling)
                }
                Spacer()
                Button("Cancel") { sheet.previewPlan = nil }.keyboardShortcut(.cancelAction).disabled(sheet.isBusy)
                Button(plan.mode == .auto ? "Apply & Commit \(plan.statements.count) Rows" : "Apply \(plan.statements.count) Rows") {
                    sheet.applyPreview(plan)
                }.buttonStyle(.borderedProminent).disabled(sheet.isBusy || !sheet.editBaselineValid || sheet.draftRevision != plan.draftRevision)
            }
        }.padding(20).frame(minWidth: 780, idealWidth: 900, minHeight: 600, idealHeight: 700)
        .interactiveDismissDisabled()
        .task(id: search) {
            let needle = search, statements = plan.statements, table = plan.table
            let matches = await Task.detached(priority: .userInitiated) {
                statements.indices.filter { index in
                    if needle.isEmpty { return true }
                    let statement = statements[index]
                    if let row = statement.row {
                        return String(row.id + 1).contains(needle)
                            || table.primaryKeyColumns.contains { row.original.values[$0.index].displayText.localizedCaseInsensitiveContains(needle) }
                            || row.replacements.keys.contains { table.columns[$0].name.localizedCaseInsensitiveContains(needle) }
                    }
                    return "new row insert".localizedCaseInsensitiveContains(needle)
                        || statement.insertedRow?.values.contains { table.columns[$0.key].name.localizedCaseInsensitiveContains(needle) || $0.value.displayText.localizedCaseInsensitiveContains(needle) } == true
                }
            }.value
            if !Task.isCancelled { visible = matches }
        }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

private struct EditValueText: View {
    let value: DatabaseValue
    var body: some View {
        Group {
            switch value {
            case .null: Text("SQL NULL").italic().foregroundStyle(.secondary)
            case .text(let text):
                let preview = String(text.prefix(4097))
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.isEmpty ? "Empty text (\"\")" : String(preview.prefix(4096))).textSelection(.enabled)
                    if preview.count > 4096 { Text("Preview shortened — copy for the complete value").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .font(.system(.callout, design: .monospaced))
        .contextMenu {
            Button("Copy Exact Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value.displayText, forType: .string)
            }
        }
    }
}

struct ForeignKeyLookupView: View {
    @Bindable var sheet: Worksheet
    @Bindable var picker: ForeignKeyLookupModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Referenced Row").font(.title2.bold())
            Text("\(picker.foreignKey.targetSchema).\(picker.foreignKey.targetTable) · \(picker.foreignKey.name)")
                .font(.callout).foregroundStyle(.secondary)
            Text("Current key: " + picker.foreignKey.localAttributes.compactMap { attribute in
                picker.table.columns.first { $0.attributeNumber == attribute }.map { column in
                    if let rowID = picker.insertRowID {
                        return sheet.insertRows.first { $0.id == rowID }?.values[column.index]?.displayText ?? "DEFAULT"
                    }
                    return (sheet.draftRows.first { $0.id == picker.row.rowIndex }?.replacements[column.index] ?? picker.row.values[column.index]).displayText
                }
            }.joined(separator: " · "))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            TextField("Search key or label", text: $picker.search).textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit { chooseSelected() }
            if let error = picker.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            List(picker.candidates, selection: $picker.selectedID) { candidate in
                VStack(alignment: .leading, spacing: 3) {
                    if let label = candidate.label { Text(label).lineLimit(2) }
                    Text(candidate.key.map(\.displayText).joined(separator: " · "))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }.tag(candidate.id).contentShape(Rectangle())
                    .onTapGesture(count: 2) { sheet.stageReference(candidate, from: picker) }
            }
            if picker.busy { ProgressView("Searching…").controlSize(.small) }
            else if picker.candidates.isEmpty && picker.error == nil { Text("No matching visible rows").foregroundStyle(.secondary) }
            if picker.limited { Text("Narrow the search to see more rows.").font(.caption).foregroundStyle(.secondary) }
            else if picker.hasMore { Button("Load More") { picker.load(append: true) }.disabled(picker.busy) }
            HStack {
                if picker.nullable { Button("No value (NULL)") { sheet.stageReference(nil, from: picker) } }
                Spacer()
                Button("Cancel") { sheet.closeLookup() }.keyboardShortcut(.cancelAction)
                Button("Choose") { chooseSelected() }.buttonStyle(.borderedProminent)
                    .disabled(picker.selectedID == nil || picker.busy)
            }
        }.padding(20).frame(width: 540, height: 500).interactiveDismissDisabled()
        .onAppear { searchFocused = true }
    }
    private func chooseSelected() {
        if let selected = picker.candidates.first(where: { $0.id == picker.selectedID }) { sheet.stageReference(selected, from: picker) }
    }
}

struct EditConflictView: View {
    @Bindable var sheet: Worksheet
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Row Changed").font(.title2.bold())
            Text("The entire Apply batch was rolled back. Compare the values before deciding how to continue.")
            if let conflict = sheet.editConflict, let table = sheet.editableTable {
                if let reason = conflict.comparisonUnavailableReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow { Text("Column"); Text("Original"); Text("Draft"); Text("Current") }.font(.headline)
                        ForEach(conflict.row.replacements.keys.sorted(), id: \.self) { index in
                            GridRow {
                                Text(table.columns[index].name)
                                EditValueText(value: conflict.row.original.values[index])
                                EditValueText(value: conflict.row.replacements[index]!)
                                if let values = conflict.freshValues { EditValueText(value: values[index]) }
                                else { Text("Unavailable").foregroundStyle(.secondary) }
                            }
                        }
                    }.padding(8)
                }
            }
            HStack {
                Button("Discard Drafts") { sheet.discardGridDrafts(); sheet.error = nil; sheet.showingConflict = false }.disabled(sheet.isBusy)
                Spacer()
                Button("Keep Drafts") { sheet.error = nil; sheet.showingConflict = false }.keyboardShortcut(.cancelAction).disabled(sheet.isBusy)
                Button("Rebase and Review Again") { sheet.rebaseConflict() }
                    .disabled(sheet.isBusy || sheet.editConflict?.freshRow == nil || !sheet.editBaselineValid)
            }
        }.padding(20).frame(minWidth: 750, minHeight: 430)
    }
}
