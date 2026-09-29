import AppKit
import SwiftUI

struct QueryTabBar: View {
    @Bindable var model: WorkbenchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var commandHeld = false

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 3) {
                            ForEach(Array(model.worksheets.enumerated()), id: \.element.id) { index, sheet in
                                tab(sheet, position: index + 1).id(sheet.id)
                            }
                        }.padding(.horizontal, 6).padding(.vertical, 5)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                    .onChange(of: model.worksheets.map(\.id)) { _, _ in
                        if let id = model.selectedID { proxy.scrollTo(id) }
                    }
                    .onChange(of: geometry.size.width) { _, _ in
                        if let id = model.selectedID { proxy.scrollTo(id) }
                    }
                }
            }
            Button(action: model.addWorksheet) {
                Image(systemName: "plus").frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!model.canAddWorksheet)
            .accessibilityLabel("New Query Tab")
            .help(model.canAddWorksheet ? "New Query Tab (⌘T)" : "Four query tabs are open. Close a tab to create another.")
            .padding(.trailing, 5)
        }
        .frame(height: 42)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Query tabs")
        .onModifierKeysChanged(mask: .command) { _, modifiers in
            commandHeld = modifiers.contains(.command)
        }
        .onChange(of: scenePhase) { _, phase in
            commandHeld = phase == .active && NSEvent.modifierFlags.contains(.command)
        }
        .onDisappear { commandHeld = false }
    }

    private func tab(_ sheet: Worksheet, position: Int) -> some View {
        let selected = model.selectedID == sheet.id
        return HStack(spacing: 5) {
            Button { model.selectTab(sheet.id) } label: {
                HStack(spacing: 7) {
                    if sheet.isBusy || sheet.isLoading || sheet.isClosing {
                        ProgressView().controlSize(.mini).frame(width: 12)
                    } else if sheet.error != nil {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    } else if sheet.transaction == .inTransaction || sheet.transaction == .failed {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    } else {
                        Image(systemName: "doc.text").foregroundStyle(selected ? .primary : .secondary)
                    }
                    Text(sheet.title).lineLimit(1).truncationMode(.middle)
                    if sheet.isDirty {
                        Circle().fill(.secondary).frame(width: 6, height: 6)
                    }
                    Spacer(minLength: 0)
                    Text("⌘\(position)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        .opacity(commandHeld ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 10)
                .frame(minWidth: 100, maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tabDescription(sheet))
            .accessibilityHint("Press Command-\(position) to select this tab")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { model.requestClose(sheet) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sheet.isClosing)
            .accessibilityLabel("Close \(sheet.title)")
            .help("Close \(sheet.title)")
            .padding(.trailing, 3)
        }
        .frame(width: 190, height: 32)
        .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            if selected { RoundedRectangle(cornerRadius: 1).fill(.tint).frame(height: 2).padding(.horizontal, 9) }
        }
        .overlay {
            MiddleClickTabClose(isEnabled: !sheet.isClosing && !model.isCoordinatingClose && !model.hasConnectionPrompt) {
                model.requestClose(sheet)
            }
            .accessibilityHidden(true)
        }
        .help(tabDescription(sheet))
        .draggable(sheet.id.uuidString)
        .dropDestination(for: String.self) { values, location in
            guard let value = values.first, let id = UUID(uuidString: value),
                  model.worksheets.contains(where: { $0.id == id }) else { return false }
            guard id != sheet.id else { return true }
            model.reorderTab(id, before: sheet.id)
            if location.x > 95 { model.moveTab(id, by: 1) }
            return true
        }
        .contextMenu {
            Button("Save SQL…") { Task { _ = await model.saveSQL(sheet: sheet) } }.disabled(sheet.isLoading || sheet.isClosing)
            Divider()
            Button("Move Tab Left") { model.moveTab(sheet.id, by: -1) }
                .disabled(model.worksheets.first?.id == sheet.id)
            Button("Move Tab Right") { model.moveTab(sheet.id, by: 1) }
                .disabled(model.worksheets.last?.id == sheet.id)
            Divider()
            Button("Close Query Tab") { model.requestClose(sheet) }.disabled(sheet.isClosing)
        }
        .accessibilityAction(named: "Move Tab Left") { model.moveTab(sheet.id, by: -1) }
        .accessibilityAction(named: "Move Tab Right") { model.moveTab(sheet.id, by: 1) }
    }

    private func tabDescription(_ sheet: Worksheet) -> String {
        var parts = [sheet.title, sheet.profile.map { "\($0.name), \($0.database)" } ?? "No connection"]
        if sheet.isDirty { parts.append("Unsaved changes") }
        if sheet.isBusy || sheet.isLoading || sheet.isClosing { parts.append(sheet.status) }
        if sheet.transaction == .inTransaction || sheet.transaction == .failed { parts.append(sheet.transaction.title) }
        if sheet.error != nil { parts.append("Query error") }
        return parts.joined(separator: ". ")
    }
}
