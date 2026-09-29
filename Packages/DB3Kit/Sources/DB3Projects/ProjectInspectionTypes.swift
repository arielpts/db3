import Foundation

public enum ProjectFactResolution: String, Codable, Sendable { case resolved, inferred, unresolved, conflicting, stale }
public enum ProjectInspectionCompleteness: String, Codable, Sendable { case complete, partial, unavailable }
public enum ProjectAdapterCapability: String, Codable, Sendable { case models, fields, choices, relationships, computedFields, namespaces, sourceDependencies }
public struct ProjectSourceRange: Hashable, Codable, Sendable {
    public let startLine: Int, startColumn: Int, endLine: Int, endColumn: Int
    public init(startLine: Int, startColumn: Int = 1, endLine: Int, endColumn: Int = 1) {
        self.startLine = startLine; self.startColumn = startColumn; self.endLine = endLine; self.endColumn = endColumn
    }
}
public struct ProjectFactProvenance: Hashable, Codable, Sendable {
    public let adapterID: String, adapterVersion: String, relativePath: String, sourceDigest: String
    public let range: ProjectSourceRange
    public let snapshotGeneration: UUID
    public var resolution: ProjectFactResolution
    public init(adapterID: String = "odoo", adapterVersion: String = "1", relativePath: String, range: ProjectSourceRange,
                sourceDigest: String, snapshotGeneration: UUID, resolution: ProjectFactResolution = .resolved) {
        self.adapterID = adapterID; self.adapterVersion = adapterVersion; self.relativePath = relativePath; self.range = range
        self.sourceDigest = sourceDigest; self.snapshotGeneration = snapshotGeneration; self.resolution = resolution
    }
    public var sourceLabel: String { "\(relativePath):\(range.startLine)" }
}
public struct ProjectInspectionDiagnostic: Hashable, Codable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable { case information, warning, error }
    public var id: String { code + ":" + (relativePath ?? "") + ":" + String(line ?? 0) + ":" + message }
    public let code: String, message: String
    public let severity: Severity
    public let relativePath: String?
    public let line: Int?
    public init(code: String, message: String, severity: Severity = .warning, relativePath: String? = nil, line: Int? = nil) {
        self.code = code; self.message = message; self.severity = severity; self.relativePath = relativePath; self.line = line
    }
}
public struct ProjectValueChoice: Hashable, Codable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String, label: String
    public let color: String?, icon: String?, description: String?, shortLabel: String?
    public let provenance: ProjectFactProvenance
    public let supplementaryMetadataResolved: Bool
    public init(key: String, label: String, color: String? = nil, icon: String? = nil, description: String? = nil,
                shortLabel: String? = nil, provenance: ProjectFactProvenance, supplementaryMetadataResolved: Bool = true) {
        self.key = key; self.label = label; self.color = color; self.icon = icon; self.description = description
        self.shortLabel = shortLabel; self.provenance = provenance; self.supplementaryMetadataResolved = supplementaryMetadataResolved
    }
}
public struct ProjectFieldMetadata: Hashable, Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public var declaredType: String
    public var stored: Bool?, computed: Bool?
    public var related: [String]?
    public var inverse: String?
    public var relationModel: String?
    public var displayLabel: String?
    public var choices: [ProjectValueChoice]
    public var choicesResolution: ProjectFactResolution
    public var choicesDiagnostic: String?
    public var provenance: ProjectFactProvenance
    public var resolution: ProjectFactResolution
    public var isSelectionExtension: Bool
    public var declarationAttributes: Set<String>
    public var selectionAdditionOrder: [String]?
    public init(name: String, declaredType: String, stored: Bool?, computed: Bool?, related: [String]? = nil,
                inverse: String? = nil, relationModel: String? = nil, displayLabel: String? = nil,
                choices: [ProjectValueChoice] = [], choicesResolution: ProjectFactResolution = .unresolved,
                choicesDiagnostic: String? = nil, provenance: ProjectFactProvenance, resolution: ProjectFactResolution = .resolved,
                isSelectionExtension: Bool = false, declarationAttributes: Set<String> = [], selectionAdditionOrder: [String]? = nil) {
        self.name = name; self.declaredType = declaredType; self.stored = stored; self.computed = computed
        self.related = related; self.inverse = inverse; self.relationModel = relationModel; self.displayLabel = displayLabel
        self.choices = choices; self.choicesResolution = choicesResolution; self.choicesDiagnostic = choicesDiagnostic
        self.provenance = provenance; self.resolution = resolution; self.isSelectionExtension = isSelectionExtension
        self.declarationAttributes = declarationAttributes; self.selectionAdditionOrder = selectionAdditionOrder
    }
    public var isDerived: Bool { computed == true || related != nil || inverse != nil }
}
public struct ProjectModelMetadata: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case regular, transient, abstract, unresolved }
    public var id: String { name }
    public let name: String
    public var kind: Kind
    public var tableName: String?
    public var tableIsExplicit: Bool
    public var auto: Bool?
    public var recordName: String?
    public var namespace: String
    public var isBase: Bool
    public var definingModule: String?
    public var inheritedModels: [String]
    public var delegatedModels: [String: String]
    public var fields: [ProjectFieldMetadata]
    public var provenance: [ProjectFactProvenance]
    public var resolution: ProjectFactResolution
    public init(name: String, kind: Kind, tableName: String?, tableIsExplicit: Bool = false, auto: Bool? = true,
                recordName: String? = nil, namespace: String, isBase: Bool = false, definingModule: String? = nil,
                inheritedModels: [String] = [], delegatedModels: [String: String] = [:], fields: [ProjectFieldMetadata],
                provenance: [ProjectFactProvenance], resolution: ProjectFactResolution = .resolved) {
        self.name = name; self.kind = kind; self.tableName = tableName; self.tableIsExplicit = tableIsExplicit; self.auto = auto
        self.recordName = recordName; self.namespace = namespace; self.isBase = isBase; self.definingModule = definingModule
        self.inheritedModels = inheritedModels; self.delegatedModels = delegatedModels; self.fields = fields
        self.provenance = provenance; self.resolution = resolution
    }
    public var requiresExplicitMapping: Bool { kind == .abstract || auto != true || resolution == .conflicting || resolution == .unresolved }
}
public struct ProjectSourceRoot: Hashable, Codable, Sendable {
    public let relativePath: String
    public let isBase: Bool
    public let priority: Int
    public init(relativePath: String, isBase: Bool, priority: Int) { self.relativePath = relativePath; self.isBase = isBase; self.priority = priority }
}
public struct ProjectAdapterDetection: Hashable, Codable, Sendable {
    public let adapterID: String, adapterVersion: String
    public let frameworkVersion: String?
    public let evidence: [String]
    public let resolution: ProjectFactResolution
    public init(adapterID: String, adapterVersion: String, frameworkVersion: String? = nil, evidence: [String], resolution: ProjectFactResolution) {
        self.adapterID = adapterID; self.adapterVersion = adapterVersion; self.frameworkVersion = frameworkVersion
        self.evidence = evidence; self.resolution = resolution
    }
}
public struct ProjectInspectionSnapshot: Codable, Sendable {
    public let generation: UUID
    public let rootDigest: String
    public let adapterID: String, adapterVersion: String
    public let detection: ProjectAdapterDetection
    public let roots: [ProjectSourceRoot]
    public let models: [ProjectModelMetadata]
    public let diagnostics: [ProjectInspectionDiagnostic]
    public let completeness: ProjectInspectionCompleteness
    public let sourceFileCount: Int, parsedFileCount: Int, metadataBytes: Int
    public let elapsed: TimeInterval
    public let inspectedAt: Date
    public let sourceDependencies: [String: [String]]
    public init(generation: UUID, rootDigest: String, adapterID: String = "odoo", adapterVersion: String = "1", detection: ProjectAdapterDetection,
                roots: [ProjectSourceRoot], models: [ProjectModelMetadata], diagnostics: [ProjectInspectionDiagnostic],
                completeness: ProjectInspectionCompleteness, sourceFileCount: Int, parsedFileCount: Int, metadataBytes: Int,
                elapsed: TimeInterval, inspectedAt: Date = Date(), sourceDependencies: [String: [String]] = [:]) {
        self.generation = generation; self.rootDigest = rootDigest; self.adapterID = adapterID; self.adapterVersion = adapterVersion
        self.detection = detection; self.roots = roots; self.models = models; self.diagnostics = diagnostics; self.completeness = completeness
        self.sourceFileCount = sourceFileCount; self.parsedFileCount = parsedFileCount; self.metadataBytes = metadataBytes
        self.elapsed = elapsed; self.inspectedAt = inspectedAt; self.sourceDependencies = sourceDependencies
    }
}
public struct ProjectInspectionLimits: Sendable {
    public var maximumFileBytes = 2 * 1024 * 1024
    public var maximumFiles = 50_000
    public var maximumMetadataBytes = 64 * 1024 * 1024
    public var maximumChoices = 5_000
    public var maximumSourceRoots = 64
    public var maximumDiagnostics = 2_000
    public init() {}
}
public protocol ProjectInspectionAdapter: Sendable {
    var adapterID: String { get }
    var adapterVersion: String { get }
    var capabilities: Set<ProjectAdapterCapability> { get }
    func inspect(root: URL, generation: UUID, changedPaths: Set<String>, force: Bool) async throws -> ProjectInspectionSnapshot
    func cancel() async
}
