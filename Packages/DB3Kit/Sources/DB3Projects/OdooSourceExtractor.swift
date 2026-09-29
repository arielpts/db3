import Foundation

struct OdooSourceExtractor {
    let files: [PythonFileFacts]
    let generation: UUID
    let limits: ProjectInspectionLimits


    func extract() throws -> (models: [ProjectModelMetadata], diagnostics: [ProjectInspectionDiagnostic], dependencies: [String: [String]]) {
        let grouped = Dictionary(grouping: files, by: \.modulePath)
        let index = grouped.compactMapValues { $0.count == 1 ? $0.first : nil }
        let ambiguousModules = Set(grouped.filter { $0.value.count > 1 }.keys)
        var diagnostics: [ProjectInspectionDiagnostic] = [], definitions: [String: [Declaration]] = [:]
        var dependencies: [String: [String]] = [:]
        var manifestDependencies: [String: Set<String>] = [:]
        for file in files {
            dependencies[file.relativePath] = file.imports.compactMap { imported in
                let target = imported.target
                return index[target]?.relativePath ?? index[target.split(separator: ".").dropLast().joined(separator: ".")]?.relativePath
            }.sorted()
            if case .dictionary(let pairs) = file.manifest {
                let values = pairs.first { $0.key.string == "depends" }?.value.elements ?? []
                manifestDependencies[file.moduleName] = Set(values.compactMap(\.string))
            }
        }
        var staleFiles = Set(files.filter(\.stale).map(\.relativePath))
        for _ in 0..<32 {
            let prior = staleFiles.count
            for (path, imports) in dependencies where imports.contains(where: staleFiles.contains) { staleFiles.insert(path) }
            if staleFiles.count == prior { break }
        }
        for module in ambiguousModules.sorted() {
            diagnostics.append(.init(code: "duplicate-source-module", message: "Multiple source roots provide the same Python module; its facts are ambiguous.", relativePath: grouped[module]?.first?.relativePath))
        }
        var dependencyClosure: [String: Set<String>] = [:]
        func depends(_ module: String, on other: String) -> Bool {
            if let known = dependencyClosure[module] { return known.contains(other) }
            var reached = Set<String>(), pending = Array(manifestDependencies[module] ?? [])
            while let next = pending.popLast() {
                guard reached.insert(next).inserted else { continue }
                pending.append(contentsOf: manifestDependencies[next] ?? [])
            }
            dependencyClosure[module] = reached
            return reached.contains(other)
        }
        // Determine file import order from each module's initializer. Files outside this graph remain visible but unresolved.
        var orderedFiles: [String: Int] = [:], visiting = Set<String>(), nextOrder = 0
        func visit(_ path: String) {
            guard !visiting.contains(path), orderedFiles[path] == nil, let file = index[path] else { return }
            visiting.insert(path)
            for imported in file.imports {
                if index[imported.target] != nil { visit(imported.target) }
                else { visit(imported.target.split(separator: ".").dropLast().joined(separator: ".")) }
            }
            orderedFiles[path] = nextOrder; nextOrder += 1; visiting.remove(path)
        }
        for file in files where file.relativePath.hasSuffix("/__init__.py") && file.modulePath == "odoo.addons." + file.moduleName { visit(file.modulePath) }
        var extractedBytes = 0, extractionBudgetReached = false
        sourceFiles: for file in files {
            try Task.checkCancellation()
            for declaration in file.classes {
                let bases = declaration.bases.map { canonical($0, file: file, index: index) }
                guard let kind = modelKind(bases) else { continue }
                let scope = Dictionary(declaration.assignments.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
                func value(_ name: String) -> PythonExpression { resolve(scope[name] ?? .unknown, file: file, scope: scope, index: index) }
                let explicitName = value("_name").string
                if scope["_name"] != nil && explicitName == nil {
                    diagnostics.append(.init(code: "dynamic-model", message: "A model's identity cannot be resolved statically.", relativePath: file.relativePath, line: declaration.range.startLine)); continue
                }
                let inherited = stringList(value("_inherit"))
                guard let name = explicitName ?? (inherited.count == 1 ? inherited.first : nil), !name.isEmpty else {
                    diagnostics.append(.init(code: "dynamic-model", message: "A model's identity cannot be resolved statically.", relativePath: file.relativePath, line: declaration.range.startLine)); continue
                }
                let defines = explicitName != nil && !inherited.contains(name)
                let loaded = orderedFiles[file.modulePath] != nil
                let inheritValue = value("_inherit")
                let inheritanceResolved = scope["_inherit"] == nil || inheritValue.string != nil || (inheritValue.elements != nil && inheritValue.elements!.allSatisfy { $0.string != nil })
                let tableResolved = scope["_table"] == nil || value("_table").string != nil
                let resolution: ProjectFactResolution = staleFiles.contains(file.relativePath) ? .stale : ambiguousModules.contains(file.modulePath) ? .conflicting : loaded && inheritanceResolved && tableResolved ? .resolved : .unresolved
                if !loaded { diagnostics.append(.init(code: "unimported-model", message: "A model file is not reachable through its module's static imports.", relativePath: file.relativePath, line: declaration.range.startLine)) }
                let provenance = provenance(file, declaration.range, resolution: resolution)
                let explicitTable = value("_table").string
                let auto: Bool? = scope["_auto"] == nil ? kind != .abstract : value("_auto").bool
                let delegated: [String: String]
                if case .dictionary(let pairs) = value("_inherits") { delegated = Dictionary(pairs.compactMap { pair in guard let k = pair.key.string, let v = pair.value.string else { return nil }; return (k, v) }, uniquingKeysWith: { _, last in last }) }
                else { delegated = [:] }
                var fields: [ProjectFieldMetadata] = []
                for assignment in declaration.assignments where !assignment.name.hasPrefix("_") {
                    if let field = extractField(assignment, file: file, scope: scope, index: index, resolution: resolution) {
                        let cost = field.retainedBytes
                        guard extractedBytes + cost <= limits.maximumMetadataBytes else { extractionBudgetReached = true; break }
                        fields.append(field); extractedBytes += cost
                    }
                }
                let model = ProjectModelMetadata(name: name, kind: kind,
                    tableName: kind == .abstract || !tableResolved ? nil : explicitTable ?? name.replacingOccurrences(of: ".", with: "_"),
                    tableIsExplicit: explicitTable != nil, auto: auto, recordName: value("_rec_name").string,
                    namespace: file.moduleName, isBase: file.isBase, definingModule: defines ? file.moduleName : nil,
                    inheritedModels: inherited, delegatedModels: delegated, fields: fields, provenance: [provenance], resolution: extractionBudgetReached ? .unresolved : resolution)
                definitions[name, default: []].append(.init(model: model, defines: defines, file: file.modulePath, order: orderedFiles[file.modulePath].map { $0 * 4_000_000 + declaration.range.startLine }))
                if extractionBudgetReached { break sourceFiles }
            }
        }
        var models: [ProjectModelMetadata] = []
        for name in definitions.keys.sorted() {
            guard let candidates = definitions[name] else { continue }
            let owners = candidates.filter(\.defines)
            guard var base = owners.first?.model else {
                var unresolved = candidates[0].model
                unresolved.namespace = "Unclassified"; unresolved.definingModule = nil; unresolved.resolution = .unresolved
                unresolved.fields = candidates.flatMap(\.model.fields).map { field in var result = field; result.resolution = .unresolved; result.choicesResolution = .unresolved; return result }
                diagnostics.append(.init(code: "missing-base-model", message: "An inherited model's defining module was not found.", relativePath: unresolved.provenance.first?.relativePath))
                models.append(unresolved); continue
            }
            if owners.count != 1 {
                base.resolution = .conflicting; base.namespace = "Unclassified"; base.definingModule = nil
                base.fields = base.fields.map { field in var result = field; result.resolution = .conflicting; result.choicesResolution = .conflicting; return result }
                diagnostics.append(.init(code: "conflicting-model", message: "Multiple declarations define the same model; ownership requires review.", relativePath: base.provenance.first?.relativePath))
            }
            let extensions = candidates.filter { !$0.defines }.sorted { lhs, rhs in
                if lhs.model.namespace == rhs.model.namespace { return (lhs.order ?? Int.max) < (rhs.order ?? Int.max) }
                if depends(lhs.model.namespace, on: rhs.model.namespace) { return false }
                if depends(rhs.model.namespace, on: lhs.model.namespace) { return true }
                return lhs.model.namespace < rhs.model.namespace
            }
            var fieldOwners = Dictionary(base.fields.map { ($0.name, owners[0]) }, uniquingKeysWith: { _, last in last })
            for ext in extensions {
                base.provenance += ext.model.provenance
                if ext.model.resolution == .stale { base.resolution = .stale }
                for field in ext.model.fields {
                    if let offset = base.fields.firstIndex(where: { $0.name == field.name }) {
                        let prior = fieldOwners[field.name]!
                        let ordered = prior.model.namespace == ext.model.namespace
                            ? (prior.order != nil && ext.order != nil && prior.order! < ext.order!)
                            : depends(ext.model.namespace, on: prior.model.namespace)
                        if ordered && field.resolution == .resolved && base.fields[offset].resolution == .resolved {
                            base.fields[offset] = merge(base.fields[offset], field)
                        } else {
                            base.fields[offset].resolution = .conflicting; base.fields[offset].choicesResolution = .conflicting
                            base.fields[offset].choicesDiagnostic = "Field overrides do not have a provable load order."
                            diagnostics.append(.init(code: "ambiguous-field-order", message: "Field overrides have unresolved load order.", relativePath: field.provenance.relativePath, line: field.provenance.range.startLine))
                        }
                    } else { base.fields.append(field) }
                    fieldOwners[field.name] = ext
                }
            }
            models.append(base)
        }
        // Classical inheritance with a new _name copies fields. Delegation deliberately does not: storage remains on the parent.
        for _ in 0..<min(16, models.count) {
            var changed = false
            let lookup = Dictionary(models.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            for i in models.indices where models[i].resolution == .resolved {
                for parentName in models[i].inheritedModels where parentName != models[i].name {
                    guard let parent = lookup[parentName], parent.resolution == .resolved else { continue }
                    for field in parent.fields where !models[i].fields.contains(where: { $0.name == field.name }) {
                        guard extractedBytes + field.retainedBytes <= limits.maximumMetadataBytes else {
                            models[i].resolution = .unresolved; extractionBudgetReached = true; break
                        }
                        models[i].fields.append(field); extractedBytes += field.retainedBytes; changed = true
                    }
                }
            }
            if !changed { break }
        }
        let lookup = Dictionary(models.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for i in models.indices {
            for j in models[i].fields.indices {
                let field = models[i].fields[j]
                guard let related = field.related, !related.isEmpty else { continue }
                var current = models[i], final: ProjectFieldMetadata?, valid = true
                for (step, component) in related.enumerated() {
                    guard let next = current.fields.first(where: { $0.name == component }), next.resolution == .resolved else { valid = false; break }
                    final = next
                    if step < related.count - 1 {
                        guard let target = next.relationModel, let model = lookup[target], model.resolution == .resolved else { valid = false; break }
                        current = model
                    }
                }
                if valid, let final, final.choicesResolution == .resolved {
                    models[i].fields[j].choices = final.choices; models[i].fields[j].choicesResolution = .resolved
                } else {
                    models[i].fields[j].choicesResolution = .unresolved
                    models[i].fields[j].choicesDiagnostic = "The complete related-field path cannot be resolved statically."
                }
            }
            models[i].fields.sort { $0.name < $1.name }
        }
        if extractionBudgetReached {
            diagnostics.insert(.init(code: "extraction-budget", message: "Resolved source facts reached the metadata memory budget; remaining facts are unavailable."), at: 0)
        }
        return (models, Array(diagnostics.prefix(limits.maximumDiagnostics)), dependencies)
    }
    private struct Declaration { var model: ProjectModelMetadata; let defines: Bool, file: String, order: Int? }
    private func modelKind(_ bases: [[String]]) -> ProjectModelMetadata.Kind? {
        for base in bases {
            switch base.joined(separator: ".") {
            case "odoo.models.Model", "odoo.Model": return .regular
            case "odoo.models.TransientModel", "odoo.TransientModel": return .transient
            case "odoo.models.AbstractModel", "odoo.AbstractModel": return .abstract
            default: continue
            }
        }; return nil
    }
    private func provenance(_ file: PythonFileFacts, _ range: ProjectSourceRange, resolution: ProjectFactResolution) -> ProjectFactProvenance {
        .init(relativePath: file.relativePath, range: range, sourceDigest: file.digest, snapshotGeneration: generation, resolution: resolution)
    }
    private func stringList(_ value: PythonExpression) -> [String] { value.string.map { [$0] } ?? value.elements?.compactMap(\.string) ?? [] }
    private func canonical(_ path: [String], file: PythonFileFacts, index: [String: PythonFileFacts], depth: Int = 0) -> [String] {
        guard depth < 16, let first = path.first else { return path }
        let expanded: [String]
        if let imported = file.imports.last(where: { $0.alias == first }) { expanded = imported.target.split(separator: ".").map(String.init) + path.dropFirst() }
        else { expanded = path }
        if expanded.count > 1 {
            let module = expanded.dropLast().joined(separator: ".")
            if let targetFile = index[module], let imported = targetFile.imports.last(where: { $0.alias == expanded.last! }) {
                return canonical(imported.target.split(separator: ".").map(String.init), file: targetFile, index: index, depth: depth + 1)
            }
        }
        return expanded
    }
    private func resolve(_ expression: PythonExpression, file: PythonFileFacts, scope: [String: PythonExpression], index: [String: PythonFileFacts], depth: Int = 0, visited: Set<String> = []) -> PythonExpression {
        guard depth < 32 else { return .unknown }
        func recur(_ value: PythonExpression, _ context: PythonFileFacts = file, _ local: [String: PythonExpression]? = nil, key: String? = nil) -> PythonExpression {
            if let key, visited.contains(key) { return .unknown }
            return resolve(value, file: context, scope: local ?? scope, index: index, depth: depth + 1, visited: key.map { visited.union([$0]) } ?? visited)
        }
        switch expression {
        case .reference(let path):
            guard !path.isEmpty else { return .unknown }
            if path.count == 1, let value = scope[path[0]] ?? file.assignments.last(where: { $0.name == path[0] })?.value { return recur(value, key: file.modulePath + ":" + path[0]) }
            if path.count == 2, let cls = file.classes.first(where: { $0.name == path[0] }), let assignment = cls.assignments.last(where: { $0.name == path[1] }) {
                let local = Dictionary(cls.assignments.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
                return recur(assignment.value, file, local, key: file.modulePath + ":" + path.joined(separator: "."))
            }
            let expanded = canonical(path, file: file, index: index)
            for split in (1..<expanded.count).reversed() {
                let module = expanded.prefix(split).joined(separator: "."), tail = Array(expanded.dropFirst(split))
                if let other = index[module] {
                    let local = Dictionary(other.assignments.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
                    return recur(.reference(tail), other, local, key: expanded.joined(separator: "."))
                }
            }
            return .unknown
        case .sequence(let items): return .sequence(items.map { recur($0) })
        case .dictionary(let pairs): return .dictionary(pairs.map { .init(key: recur($0.key), value: recur($0.value)) })
        case .addition(let lhs, let rhs):
            let l = recur(lhs), r = recur(rhs)
            if let a = l.string, let b = r.string, a.utf8.count + b.utf8.count <= 131_072 { return .string(a + b) }
            if let a = l.elements, let b = r.elements, a.count + b.count <= 10_000 { return .sequence(a + b) }
            return .unknown
        case .call(let function, let args, _):
            let target = canonical(function, file: file, index: index).joined(separator: ".")
            // Translation wrappers carry the exact declared label, not a computed value.
            if ["odoo._", "odoo.tools.translate._"].contains(target), args.count == 1 { return recur(args[0]) }
            return .unknown
        default: return expression
        }
    }
    private func extractField(_ assignment: PythonAssignment, file: PythonFileFacts, scope: [String: PythonExpression], index: [String: PythonFileFacts], resolution: ProjectFactResolution) -> ProjectFieldMetadata? {
        guard case .call(let rawFunction, let rawArgs, let rawKeywords) = assignment.value else { return nil }
        let function = canonical(rawFunction, file: file, index: index), target = function.joined(separator: ".")
        var args = rawArgs, keywords = rawKeywords, name = function.last ?? ""
        var wrapper = false
        if name == "computed", target.hasPrefix("odoo.addons."), case .call(let inner, let innerArgs, let innerKeywords) = rawArgs.first {
            let innerTarget = canonical(inner, file: file, index: index)
            guard innerTarget.starts(with: ["odoo", "fields"]) else { return nil }
            name = innerTarget.last ?? ""; args = innerArgs; keywords = innerKeywords.merging(rawKeywords, uniquingKeysWith: { _, outer in outer }); wrapper = true
        } else {
            let ordinary = function.count == 3 && function.starts(with: ["odoo", "fields"])
            let enhanced = ["EnhancedSelection", "LlmComputed", "ForwardMany2one"].contains(name) && target.hasPrefix("odoo.addons.")
            guard ordinary || enhanced else { return nil }
        }
        func resolved(_ value: PythonExpression?) -> PythonExpression { resolve(value ?? .unknown, file: file, scope: scope, index: index) }
        let related = resolved(keywords["related"]).string.map { $0.split(separator: ".").map(String.init) }
        let computed: Bool? = wrapper || name == "LlmComputed" || keywords["compute"] != nil || related != nil ? true : false
        let stored = keywords["store"] == nil ? !(computed == true && name != "LlmComputed") : resolved(keywords["store"]).bool
        let provenance = provenance(file, assignment.range, resolution: resolution)
        let isSelection = ["Selection", "EnhancedSelection", "LlmComputed"].contains(name)
        let selection = keywords["selection_add"] ?? keywords["selection"] ?? (name == "LlmComputed" ? nil : args.first)
        let choices: ([ProjectValueChoice], ProjectFactResolution, String?)
        if isSelection && selection != nil { choices = extractChoices(resolved(selection), enhanced: name == "EnhancedSelection", extensionMode: keywords["selection_add"] != nil, provenance: provenance) }
        else { choices = ([], related == nil ? .resolved : .unresolved, nil) }
        let relation = ["Many2one", "One2many", "Many2many", "ForwardMany2one"].contains(name) ? resolved(keywords["comodel_name"] ?? args.first).string : nil
        var field = ProjectFieldMetadata(name: assignment.name, declaredType: name, stored: stored, computed: computed, related: related,
            inverse: resolved(keywords["inverse"]).string, relationModel: relation, displayLabel: resolved(keywords["string"]).string,
            choices: choices.0, choicesResolution: resolution == .resolved ? choices.1 : resolution,
            choicesDiagnostic: choices.2, provenance: provenance, resolution: resolution, isSelectionExtension: keywords["selection_add"] != nil,
            declarationAttributes: Set(keywords.keys).union(args.isEmpty ? [] : [isSelection ? "selection" : "comodel_name"]).union(wrapper || name == "LlmComputed" ? ["compute"] : []),
            selectionAdditionOrder: keywords["selection_add"] != nil ? resolved(selection).elements?.compactMap { $0.elements?.first?.string } : nil)
        if keywords["__dynamic_arguments__"] != nil {
            field.resolution = .unresolved; field.choicesResolution = .unresolved; field.choicesDiagnostic = "Dynamic field arguments require runtime evaluation."
        }
        if keywords["inverse"] != nil && resolved(keywords["inverse"]).string == nil && resolved(keywords["inverse"]).bool != false {
            field.resolution = .unresolved
        }
        if keywords["store"] != nil && stored == nil { field.resolution = .unresolved }
        if keywords["related"] != nil && related == nil { field.resolution = .unresolved; field.computed = true; field.choicesResolution = .unresolved; field.choicesDiagnostic = "The related field path is dynamic." }
        return field
    }
    private func extractChoices(_ value: PythonExpression, enhanced: Bool, extensionMode: Bool, provenance: ProjectFactProvenance) -> ([ProjectValueChoice], ProjectFactResolution, String?) {
        guard let items = value.elements else { return ([], .unresolved, "Choices require runtime evaluation.") }
        guard items.count <= limits.maximumChoices else { return ([], .unresolved, "Choice list exceeds the inspection budget.") }
        var choices: [ProjectValueChoice] = [], valid = true, keys = Set<String>()
        for item in items {
            if extensionMode, let tuple = item.elements, tuple.count == 1, let key = tuple[0].string {
                if !keys.insert(key).inserted { valid = false }; continue
            }
            guard let tuple = item.elements, (2...(enhanced ? 6 : 2)).contains(tuple.count),
                  let key = tuple[0].string, let label = tuple[1].string, keys.insert(key).inserted else { valid = false; continue }
            let color = enhanced && tuple.count >= 3 ? tuple[2].string : nil
            let icon = enhanced && tuple.count >= 5 ? tuple[3].string : nil
            let description = enhanced && tuple.count == 4 ? tuple[3].string : enhanced && tuple.count >= 5 ? tuple[4].string : nil
            let short = enhanced && tuple.count >= 6 ? tuple[5].string : nil
            let supplemental = tuple.dropFirst(2).allSatisfy { if case .none = $0 { true } else { $0.string != nil } }
            choices.append(.init(key: key, label: label, color: color, icon: icon, description: description, shortLabel: short, provenance: provenance, supplementaryMetadataResolved: supplemental))
        }
        return (choices, valid ? .resolved : .unresolved, valid ? nil : "Some choices or ordering anchors cannot be resolved statically.")
    }
    private func merge(_ original: ProjectFieldMetadata, _ update: ProjectFieldMetadata) -> ProjectFieldMetadata {
        var result = update
        if !update.declarationAttributes.contains("compute") { result.computed = original.computed }
        if !update.declarationAttributes.contains("store") { result.stored = original.stored }
        if !update.declarationAttributes.contains("related") { result.related = original.related }
        if !update.declarationAttributes.contains("inverse") { result.inverse = original.inverse }
        if !update.declarationAttributes.contains("comodel_name") { result.relationModel = original.relationModel }
        if !update.declarationAttributes.contains("string") { result.displayLabel = original.displayLabel }
        guard update.isSelectionExtension else {
            if !update.declarationAttributes.contains("selection") {
                result.choices = original.choices; result.choicesResolution = original.choicesResolution; result.choicesDiagnostic = original.choicesDiagnostic
            }
            return result
        }
        guard original.choicesResolution == .resolved, update.choicesResolution == .resolved else {
            result.choicesResolution = .unresolved; result.choicesDiagnostic = "The base choices or extension ordering are unresolved."; return result
        }
        var choices = original.choices, pending: [ProjectValueChoice] = [], previousAnchor = -1
        for key in update.selectionAdditionOrder ?? update.choices.map(\.key) {
            let added = update.choices.first { $0.key == key }
            if let originalIndex = original.choices.firstIndex(where: { $0.key == key }) {
                guard originalIndex > previousAnchor, let index = choices.firstIndex(where: { $0.key == key }) else {
                    result.choicesResolution = .unresolved; result.choicesDiagnostic = "Selection extension anchors have conflicting order."; return result
                }
                previousAnchor = originalIndex
                if let added { choices[index] = added }
                choices.insert(contentsOf: pending, at: index); pending.removeAll()
            } else if let added { pending.append(added) }
            else {
                result.choicesResolution = .unresolved; result.choicesDiagnostic = "A selection ordering anchor is absent from the base choices."; return result
            }
        }
        choices.append(contentsOf: pending)
        guard choices.count <= limits.maximumChoices else { result.choices = []; result.choicesResolution = .unresolved; result.choicesDiagnostic = "Merged choices exceed the inspection budget."; return result }
        result.choices = choices; result.isSelectionExtension = false
        return result
    }
}
