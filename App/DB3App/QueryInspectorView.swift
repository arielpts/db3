import SwiftUI
import DB3Editor

struct QueryInspectorView: View {
    @Bindable var sheet: Worksheet
    let model: WorkbenchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Inspector").font(.headline)
            if let value = sheet.selectedValue {
                Label(sheet.selectedColumn ?? "Value", systemImage: "rectangle.split.3x1").font(.callout.bold())
                SQLTextEditor(text: .constant(value), selection: $sheet.inspectorSelection,
                              fontSize: 12, isEditable: false,
                              isActive: model.selectedID == sheet.id && model.showingInspector)
            } else {
                Label("Session", systemImage: "network").font(.callout.bold())
                LabeledContent("Status", value: sheet.status)
                LabeledContent("Transaction", value: sheet.transaction.title)
                if !sheet.serverVersion.isEmpty { Text(sheet.serverVersion).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Divider()
                Text("Select a result cell to inspect its value.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(20)
    }
}
