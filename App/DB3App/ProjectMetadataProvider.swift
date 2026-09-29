import Foundation
import DB3Core
import DB3Projects

/// One provider belongs to one explicitly bound, captured profile. It receives
/// actual catalog columns before matching any source field, never bare OIDs.
actor ProjectMetadataProvider: FieldEditorMetadataProvider {
    private var snapshot: ProjectInspectionSnapshot?
    private let schema: String
    private var databaseOID: UInt32?
    private var active = true
    private var exhausted = false
    private var revision = UUID().uuidString
    private var models: [String: [ProjectModelMetadata]] = [:]
    private var verified: [UInt32: [Int: ProjectFieldMetadata]] = [:]
    private var preparedRevision: [UInt32: String] = [:]
    private var preparedActive: [UInt32: Bool] = [:]
    private var names: [UInt32: String] = [:]
    private var columnKinds: [UInt32: [Int: ScalarEditorKind]] = [:]

    init(schema: String, databaseOID: UInt32? = nil) { self.schema = schema; self.databaseOID = databaseOID }

    func update(_ snapshot: ProjectInspectionSnapshot?) {
        self.snapshot = snapshot; revision = UUID().uuidString
        guard let snapshot else { active = false; return }
        active = snapshot.completeness != .unavailable
        models = Dictionary(grouping: snapshot.models.filter { $0.tableName != nil }, by: { $0.tableName! })
        // Retain cautions for previously seen columns that vanished from a bad
        // parse. New metadata will replace them only after a fresh catalog read.
    }
    func suspend() { active = false; revision = UUID().uuidString }

    func prepare(databaseOID: UInt32, schemaOID: UInt32, relationOID: UInt32, schema: String, table: String, columns: [EditableColumn]) async {
        preparedRevision[relationOID] = revision
        preparedActive[relationOID] = active && schema.utf8.elementsEqual(self.schema.utf8)
        guard active, schema.utf8.elementsEqual(self.schema.utf8) else { return }
        if let expected = self.databaseOID, expected != databaseOID { active = false; revision = UUID().uuidString; preparedActive[relationOID] = false; return }
        self.databaseOID = databaseOID
        guard let candidates = models[table], let model = candidates.first, model.tableName?.utf8.elementsEqual(table.utf8) == true else { preparedActive[relationOID] = false; return }
        let ambiguous = candidates.count != 1 || model.requiresExplicitMapping || model.resolution == .stale
        let fields = Dictionary(grouping: candidates.flatMap(\.fields), by: \.name)
        if verified.count >= 32, verified[relationOID] == nil {
            exhausted = true; active = false; preparedActive[relationOID] = false
            return
        }
        var matched: [Int: ProjectFieldMetadata] = [:], kinds: [Int: ScalarEditorKind] = [:]
        for column in columns {
            guard let candidates = fields[column.name], let field = candidates.first else {
                if var prior = verified[relationOID]?[column.attributeNumber], prior.name == column.name {
                    prior.resolution = .unresolved; prior.choicesResolution = .unresolved
                    matched[column.attributeNumber] = prior
                    if let kind = column.kind { kinds[column.attributeNumber] = kind }
                }
                else if ambiguous, let provenance = model.provenance.first {
                    matched[column.attributeNumber] = ProjectFieldMetadata(name: column.name, declaredType: "Unknown", stored: nil, computed: nil,
                        provenance: provenance, resolution: .unresolved)
                }
                continue
            }
            var checked = field
            let compatible: Bool
            switch field.declaredType {
            case "Char", "Text", "Html", "Selection", "EnhancedSelection": compatible = column.kind == .text || column.kind == .enumeration
            case "Many2one", "ForwardMany2one", "Integer": compatible = column.kind == .integer
            case "Float", "Monetary": compatible = [.decimal, .floatingPoint, .integer].contains(column.kind)
            case "Boolean": compatible = column.kind == .boolean
            case "Date": compatible = column.kind == .date
            case "Datetime": compatible = column.kind == .timestamp
            case "Json", "Properties": compatible = column.kind == .json
            case "LlmComputed": compatible = column.kind == .text || column.kind == .enumeration
            default: compatible = false
            }
            if ambiguous || !compatible || candidates.count != 1 || !field.name.utf8.elementsEqual(column.name.utf8) { checked.resolution = .unresolved; checked.choicesResolution = .unresolved }
            matched[column.attributeNumber] = checked
            if let kind = column.kind { kinds[column.attributeNumber] = kind }
        }
        verified[relationOID] = matched; names[relationOID] = model.name; columnKinds[relationOID] = kinds
    }
    func metadata(relationOID: UInt32, attributeNumber: Int) async -> FieldEditorMetadata? {
        if exhausted { return FieldEditorMetadata(classification: .unresolved, modelField: "Column \(attributeNumber)", source: "Project metadata binding limit reached. Rebind the project to revalidate.", revision: revision) }
        guard let field = verified[relationOID]?[attributeNumber] else { return nil }
        let classification: FieldEditorMetadata.Classification
        let active = preparedActive[relationOID] == true
        let revision = preparedRevision[relationOID] ?? revision
        if !active || field.resolution == .unresolved || field.resolution == .conflicting || field.resolution == .stale {
            classification = .unresolved
        } else if field.stored == false { classification = .nonstoredComputed }
        else if field.computed == true { classification = field.stored == true ? .storedComputed : .unresolved }
        else if field.related != nil || field.inverse != nil { classification = field.stored == true ? .storedDerived : .unresolved }
        else { classification = .ordinary }
        return FieldEditorMetadata(classification: classification, modelField: (names[relationOID] ?? "") + "." + field.name,
            source: field.provenance.sourceLabel + (active ? "" : " · Stale; refresh project"),
            revision: revision + ":" + field.provenance.sourceDigest)
    }
    func validatePreparedMetadata(relationOID: UInt32) async throws {
        guard !exhausted, preparedRevision[relationOID] == revision else {
            throw DatabaseError("Project metadata changed while applying edits. Refresh and preview the edits again.")
        }
        if verified[relationOID]?.isEmpty != false { return }
        guard active else { throw DatabaseError("Project metadata is unavailable. Refresh and preview the edits again.") }
    }
    func choices(relationOID: UInt32, attributeNumber: Int) async -> ValueChoiceSet? {
        guard let field = verified[relationOID]?[attributeNumber],
              columnKinds[relationOID]?[attributeNumber] == .text || columnKinds[relationOID]?[attributeNumber] == .enumeration,
              !field.choices.isEmpty || field.declaredType.localizedCaseInsensitiveContains("selection") else { return nil }
        let revision = preparedRevision[relationOID] ?? revision
        let resolved = preparedActive[relationOID] == true && field.choicesResolution == .resolved
        do { return try ValueChoiceSet(choices: resolved ? field.choices.map {
            ValueChoice(key: $0.key, label: $0.label, description: $0.description, color: $0.color, icon: $0.icon, shortLabel: $0.shortLabel)
        } : [], source: field.provenance.sourceLabel, revision: revision + ":" + field.provenance.sourceDigest,
            status: resolved ? .resolved : .unresolved(field.choicesDiagnostic ?? "Refresh or resolve the source declaration."))
        } catch {
            return try? ValueChoiceSet(choices: [], source: field.provenance.sourceLabel, revision: revision,
                status: .unresolved("The source vocabulary exceeds a limit or contains invalid keys."))
        }
    }
}
