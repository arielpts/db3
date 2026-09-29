import Foundation
import Testing
import Darwin
@testable import DB3Projects

private struct SourceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("db3-source-fixture-" + UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func write(_ path: String, _ value: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }
    func module(_ name: String, depends: [String] = [], files: [String] = ["models"], base: Bool = false) throws {
        let path = (base ? "framework/" : "src/") + name
        try write(path + "/__manifest__.py", "{'name':'Synthetic', 'depends':" + String(describing: depends) + "}")
        try write(path + "/__init__.py", files.map { "from . import " + $0 }.joined(separator: "\n"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Project source inspection", .serialized)
struct SourceInspectionTests {
    @Test func staticChoicesAliasesTupleSemanticsAndComputedFields() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        try fixture.module("sample")
        try fixture.write("src/sample/constants.py", "STATES = [('new','New'), ('done','Done')]")
        try fixture.write("src/sample/models.py", #"""
        from odoo import fields as F, models as M, _
        from .constants import STATES as ITEMS
        from odoo.addons.sample.helpers import EnhancedSelection as Choice
        from odoo.addons.sample.decorators import computed as calculated
        class Record(M.Model):
            _name = 'sample.record'
            SIMPLE = [('a', _('Alpha'))]
            state = F.Selection(ITEMS)
            local = F.Selection(SIMPLE)
            enhanced = Choice([('a','Alpha'), ('b','Beta','red'), ('c','Gamma', COLOR, 'Help'), ('d','Delta','blue','star','Detail'), ('e','Epsilon','green','heart','Long','E')])
            derived = calculated(F.Char(), compute='_compute_value')
            total = F.Float(compute='_compute_total', store=True, inverse='_inverse_total')
            dynamic = F.Selection(lambda self: ITEMS)
            expanded = F.Selection(ITEMS, **OPTIONS)
            filtered = F.Selection([x for x in ITEMS if x[0] != 'done'])
        class Action:
            _name = 'not.a.model'
            state = F.Selection(ITEMS)
        """#)
        let snapshot = try await ProjectSourceInspector().inspect(root: fixture.root)
        #expect(snapshot.models.count == 1)
        let model = try #require(snapshot.models.first)
        #expect(model.name == "sample.record" && model.tableName == "sample_record")
        #expect(model.namespace == "sample" && model.definingModule == "sample" && !model.isBase)
        func field(_ name: String) throws -> ProjectFieldMetadata { try #require(model.fields.first { $0.name == name }) }
        #expect(try field("state").choices.map(\.key) == ["new", "done"])
        #expect(try field("local").choices.map(\.label) == ["Alpha"])
        let enhanced = try field("enhanced")
        #expect(enhanced.choicesResolution == .resolved && enhanced.choices.count == 5)
        #expect(enhanced.choices[2].description == "Help" && enhanced.choices[2].icon == nil)
        #expect(enhanced.choices[2].supplementaryMetadataResolved == false)
        #expect(enhanced.choices[3].icon == "star" && enhanced.choices[3].description == "Detail")
        #expect(enhanced.choices[4].shortLabel == "E")
        #expect(try field("derived").computed == true && field("derived").stored == false)
        #expect(try field("total").isDerived && field("total").stored == true)
        #expect(try field("expanded").resolution == .unresolved && field("expanded").choicesResolution == .unresolved)
        #expect(try field("dynamic").choicesResolution == .unresolved && field("filtered").choices.isEmpty)
        #expect(model.provenance[0].relativePath == "src/sample/models.py")
    }

    @Test func ownershipExtensionsRelatedAndDelegatedFields() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        try fixture.write("odoo_repositories.json", #"{"odoo_version":"18.0","repositories":[{"active":true,"path":"framework","core":true},{"active":true,"path":"src"}]}"#)
        try fixture.module("base", base: true)
        try fixture.write("framework/base/models.py", """
        from odoo import fields, models
        class Partner(models.Model):
            _name = 'res.partner'
            state = fields.Selection([('new', 'New')])
        """)
        try fixture.module("sample", depends: ["base"])
        try fixture.write("src/sample/models.py", """
        from odoo import fields, models
        class PartnerExtension(models.Model):
            _inherit = 'res.partner'
            state = fields.Selection(selection_add=[('done', 'Done')])
        class Record(models.Model):
            _name = 'sample.record'
            partner_id = fields.Many2one('res.partner')
            related_state = fields.Selection(related='partner_id.state', store=True)
        class Delegated(models.Model):
            _name = 'sample.delegate'
            _inherits = {'res.partner': 'partner_id'}
            partner_id = fields.Many2one('res.partner')
        class Abstract(models.AbstractModel):
            _name = 'sample.abstract'
        class View(models.Model):
            _name = 'sample.view'
            _auto = False
            _table = 'explicit_view'
        """)
        let snapshot = try await ProjectSourceInspector().inspect(root: fixture.root)
        let base = try #require(snapshot.models.first { $0.name == "res.partner" })
        #expect(base.namespace == "base" && base.isBase && base.definingModule == "base")
        #expect(base.fields.first?.choices.map(\.key) == ["new", "done"])
        let record = try #require(snapshot.models.first { $0.name == "sample.record" })
        #expect(record.fields.first { $0.name == "related_state" }?.choices.map(\.key) == ["new", "done"])
        #expect(snapshot.models.first { $0.name == "sample.delegate" }?.fields.count == 1)
        #expect(snapshot.models.first { $0.name == "sample.abstract" }?.tableName == nil)
        #expect(snapshot.models.first { $0.name == "sample.view" }?.requiresExplicitMapping == true)
    }

    @Test func incrementalStaleRecoveryAndStableDigest() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        try fixture.module("sample")
        let path = "src/sample/models.py"
        let source = "from odoo import fields, models\nclass Record(models.Model):\n    _name='sample.record'\n    state=fields.Selection([('new','New')])\n"
        try fixture.write(path, source)
        let inspector = ProjectSourceInspector()
        let first = try await inspector.inspect(root: fixture.root)
        let unchanged = try await inspector.inspect(root: fixture.root)
        #expect(unchanged.parsedFileCount == 0 && first.rootDigest == unchanged.rootDigest)
        try fixture.write(path, source + "def incomplete(")
        let stale = try await inspector.inspect(root: fixture.root, changedPaths: [path])
        #expect(stale.models.first?.resolution == .stale)
        #expect(stale.models.first?.fields.first?.choicesResolution == .stale)
        #expect(stale.completeness == .partial && first.rootDigest != stale.rootDigest)
        try fixture.write(path, source.replacingOccurrences(of: "'new','New'", with: "'old','Old'"))
        let recovered = try await inspector.inspect(root: fixture.root, changedPaths: [path])
        #expect(recovered.parsedFileCount == 1 && recovered.models.first?.resolution == .resolved)
        #expect(recovered.models.first?.fields.first?.choices.first?.key == "old")
    }

    @Test func anchorsSelfInheritanceAndStaleImportedConstants() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        try fixture.module("sample")
        try fixture.write("src/sample/constants.py", "STATES=[('a','Alpha'),('z','Omega')]\n")
        try fixture.write("src/sample/models.py", """
        from odoo import fields, models
        from .constants import STATES
        class Original(models.Model):
            _name = 'sample.record'
            state = fields.Selection(STATES, compute='_compute_state', store=True)
        class Extension(models.Model):
            _name = 'sample.record'
            _inherit = 'sample.record'
            state = fields.Selection(selection_add=[('b','Beta'),('z',)])
        """)
        let inspector = ProjectSourceInspector()
        let first = try await inspector.inspect(root: fixture.root)
        let field = try #require(first.models.first?.fields.first)
        #expect(first.models.first?.namespace == "sample" && first.models.first?.resolution == .resolved)
        #expect(field.choices.map(\.key) == ["a", "b", "z"] && field.computed == true && field.stored == true)
        try fixture.write("src/sample/constants.py", "STATES=[('a',")
        let stale = try await inspector.inspect(root: fixture.root, changedPaths: ["src/sample/constants.py"])
        #expect(stale.models.first?.fields.first?.choicesResolution != .resolved)
        let unchanged = try await inspector.inspect(root: fixture.root)
        #expect(unchanged.parsedFileCount == 0 && unchanged.rootDigest == stale.rootDigest)
    }

    @Test func genericFolderAndRepositoryChangeDigest() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        let inspector = ProjectSourceInspector()
        let generic = try await inspector.inspect(root: fixture.root)
        #expect(generic.adapterID == "generic" && generic.completeness == .complete)
        #expect(generic.diagnostics.allSatisfy { $0.severity == .information })
        try fixture.module("sample")
        try fixture.write("src/sample/models.py", "from odoo import models\nclass Record(models.Model):\n    _name='sample.record'\n")
        let config = #"{"odoo_version":"18.0","repositories":[{"active":true,"path":"src","core":false}]}"#
        try fixture.write("odoo_repositories.json", config)
        let first = try await inspector.inspect(root: fixture.root)
        try fixture.write("odoo_repositories.json", config.replacingOccurrences(of: "false", with: "true"))
        let second = try await inspector.inspect(root: fixture.root)
        #expect(second.models.first?.isBase == true && second.rootDigest != first.rootDigest)
    }

    @Test func concurrentInspectionAndCancellationAreFenced() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        try fixture.module("sample")
        try fixture.write("src/sample/models.py", "from odoo import models\nclass Record(models.Model):\n    _name='sample.record'\n")
        let inspector = ProjectSourceInspector()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    if i % 3 == 0 { await inspector.cancel() }
                    else { do { _ = try await inspector.inspect(root: fixture.root) } catch is CancellationError {} }
                }
            }
            try await group.waitForAll()
        }
        let final = try await inspector.inspect(root: fixture.root)
        #expect(final.models.first?.name == "sample.record")
    }

    @Test func repeatedChoiceReferencesRespectGlobalMetadataBudget() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        try fixture.module("sample")
        let choices = (0..<20).map { "('k\($0)','Label \($0)')" }.joined(separator: ",")
        let fields = (0..<24).map { "    field_\($0)=fields.Selection(CHOICES)" }.joined(separator: "\n")
        try fixture.write("src/sample/models.py", "from odoo import fields, models\nCHOICES=[" + choices + "]\nclass Record(models.Model):\n    _name='sample.record'\n" + fields)
        var limits = ProjectInspectionLimits(); limits.maximumMetadataBytes = 128 * 1024
        let snapshot = try await ProjectSourceInspector(limits: limits).inspect(root: fixture.root)
        #expect(snapshot.metadataBytes <= limits.maximumMetadataBytes)
        #expect(snapshot.completeness == .partial)
        #expect(snapshot.diagnostics.contains { $0.code == "extraction-budget" })
    }

    @Test func optInPrivateProjectMeasurement() async throws {
        guard let path = ProcessInfo.processInfo.environment["DB3_INSPECTION_BENCH_ROOT"] else { return }
        let inspector = ProjectSourceInspector()
        let cold = try await inspector.inspect(root: URL(fileURLWithPath: path))
        let changed = cold.models.flatMap(\.provenance).first { $0.relativePath.hasPrefix("src/") }?.relativePath
        let unchanged = try await inspector.inspect(root: URL(fileURLWithPath: path))
        let warm = try await inspector.inspect(root: URL(fileURLWithPath: path), changedPaths: changed.map { [$0] } ?? [])
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("Inspection measurement: files=\(cold.sourceFileCount), parsed=\(cold.parsedFileCount), models=\(cold.models.count), fields=\(cold.models.reduce(0) { $0 + $1.fields.count }), choices=\(cold.models.flatMap(\.fields).reduce(0) { $0 + $1.choices.count }), coldSeconds=\(cold.elapsed), unchangedSeconds=\(unchanged.elapsed), changedSeconds=\(warm.elapsed), changedParsed=\(warm.parsedFileCount), metadataBytes=\(warm.metadataBytes), processPeakRSS=\(usage.ru_maxrss), diagnosticCount=\(cold.diagnostics.count)")
        print("Inspection diagnostic aggregate: \(Dictionary(grouping: cold.diagnostics, by: \.code).mapValues(\.count))")
        #expect(!cold.models.isEmpty)
        #expect(warm.parsedFileCount <= cold.diagnostics.filter { $0.code == "source-parse-failed" || $0.code == "metadata-budget" }.count + 1)
    }

    @Test func boundsSymlinksAndUnimportedModels() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        try fixture.module("sample")
        try fixture.write("src/sample/models.py", "from odoo import models\nclass Record(models.Model):\n    _name='sample.record'\n")
        try fixture.write("src/sample/unused.py", "from odoo import models\nclass Unused(models.Model):\n    _name='sample.unused'\n")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("src/sample/outside.py").path, withDestinationPath: "/etc/passwd")
        try fixture.write("src/sample/large.py", String(repeating: "#", count: 4096))
        var limits = ProjectInspectionLimits(); limits.maximumFileBytes = 1024
        let snapshot = try await ProjectSourceInspector(limits: limits).inspect(root: fixture.root)
        #expect(snapshot.models.first { $0.name == "sample.unused" }?.resolution == .unresolved)
        #expect(snapshot.diagnostics.contains { $0.code == "skipped-symlink" })
        #expect(snapshot.diagnostics.contains { $0.code == "large-source-file" })
        #expect(snapshot.completeness == .partial)
    }
}
