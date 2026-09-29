import Foundation
import CTreeSitter
import CTreeSitterPython

/// Only declarative expressions are retained. Functions and executable statements are never evaluated.
indirect enum PythonExpression: Codable, Sendable {
    case string(String), boolean(Bool), number(String), none
    case sequence([PythonExpression]), dictionary([PythonPair]), reference([String])
    case call([String], [PythonExpression], [String: PythonExpression])
    case addition(PythonExpression, PythonExpression), unknown
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .boolean(let value) = self { value } else { nil } }
    var elements: [PythonExpression]? { if case .sequence(let value) = self { value } else { nil } }
}
struct PythonPair: Codable, Sendable { let key: PythonExpression, value: PythonExpression }
struct PythonAssignment: Codable, Sendable { let name: String, value: PythonExpression, range: ProjectSourceRange }
struct PythonClass: Codable, Sendable { let name: String, bases: [[String]], assignments: [PythonAssignment], range: ProjectSourceRange }
struct PythonImport: Codable, Sendable { let alias: String, target: String }
struct PythonFileFacts: Codable, Sendable {
    let relativePath: String, modulePath: String, moduleName: String, digest: String
    let isBase: Bool
    let imports: [PythonImport], assignments: [PythonAssignment], classes: [PythonClass]
    let manifest: PythonExpression?
    var stale = false
}
enum PythonSyntaxError: Error { case parserUnavailable, invalidSyntax, budget }

struct PythonSyntax {
    let bytes: [UInt8]
    private func type(_ node: TSNode) -> String { ts_node_is_null(node) ? "" : String(cString: ts_node_type(node)) }
    private func children(_ node: TSNode) -> [TSNode] { ts_node_is_null(node) ? [] : (0..<ts_node_named_child_count(node)).map { ts_node_named_child(node, $0) } }
    private func field(_ node: TSNode, _ name: String) -> TSNode { name.withCString { ts_node_child_by_field_name(node, $0, UInt32(name.utf8.count)) } }
    private func text(_ node: TSNode) -> String {
        guard !ts_node_is_null(node) else { return "" }
        let start = Int(ts_node_start_byte(node)), end = min(bytes.count, Int(ts_node_end_byte(node)))
        guard start <= end, end - start <= 131_072 else { return "" }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
    private func range(_ node: TSNode) -> ProjectSourceRange {
        let start = ts_node_start_point(node), end = ts_node_end_point(node)
        return .init(startLine: Int(start.row) + 1, startColumn: Int(start.column) + 1, endLine: Int(end.row) + 1, endColumn: Int(end.column) + 1)
    }
    private func path(_ node: TSNode) -> [String] {
        switch type(node) {
        case "identifier": return [text(node)]
        case "attribute": return path(field(node, "object")) + path(field(node, "attribute"))
        default: return []
        }
    }
    private func expression(_ node: TSNode, depth: Int = 0) -> PythonExpression {
        guard depth < 32, !ts_node_is_null(node), ts_node_end_byte(node) - ts_node_start_byte(node) <= 131_072 else { return .unknown }
        let next = depth + 1
        switch type(node) {
        case "string": return decodeString(text(node)).map(PythonExpression.string) ?? .unknown
        case "concatenated_string":
            let pieces = children(node).map { expression($0, depth: next).string }
            guard pieces.allSatisfy({ $0 != nil }) else { return .unknown }
            return .string(pieces.compactMap { $0 }.joined())
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "none": return .none
        case "integer", "float": return .number(text(node))
        case "identifier", "attribute": return .reference(path(node))
        case "list", "tuple", "expression_list": return .sequence(children(node).prefix(10_001).map { expression($0, depth: next) })
        case "parenthesized_expression": return children(node).first.map { expression($0, depth: next) } ?? .unknown
        case "dictionary":
            return .dictionary(children(node).prefix(10_001).compactMap { child in
                guard type(child) == "pair" else { return PythonPair(key: .unknown, value: .unknown) }
                return PythonPair(key: expression(field(child, "key"), depth: next), value: expression(field(child, "value"), depth: next))
            })
        case "call":
            let function = path(field(node, "function")); guard !function.isEmpty else { return .unknown }
            var positional: [PythonExpression] = [], keywords: [String: PythonExpression] = [:]
            for child in children(field(node, "arguments")).prefix(1_000) {
                if type(child) == "keyword_argument" {
                    let name = text(field(child, "name"))
                    if ["selection", "selection_add", "related", "compute", "store", "inverse", "comodel_name", "string", "output_type"].contains(name) {
                        keywords[name] = expression(field(child, "value"), depth: next)
                    }
                } else if ["dictionary_splat", "list_splat"].contains(type(child)) {
                    keywords["__dynamic_arguments__"] = .unknown
                    positional.append(.unknown)
                } else { positional.append(expression(child, depth: next)) }
            }
            return .call(function, positional, keywords)
        case "binary_operator":
            guard text(field(node, "operator")) == "+" else { return .unknown }
            return .addition(expression(field(node, "left"), depth: next), expression(field(node, "right"), depth: next))
        default: return .unknown
        }
    }
    private func assignment(_ node: TSNode) -> PythonAssignment? {
        let actual = type(node) == "expression_statement" ? children(node).first ?? node : node
        guard type(actual) == "assignment", type(field(actual, "left")) == "identifier" else { return nil }
        let name = text(field(actual, "left"))
        if ["_sql_constraints", "_description", "_order", "_parent_name", "_parent_store", "_sequence", "_log_access", "_check_company_auto", "_fold_name", "_date_name", "_active_name", "_rec_names_search"].contains(name) { return nil }
        return .init(name: name, value: expression(field(actual, "right")), range: range(actual))
    }
    func parse(relativePath: String, modulePath: String, moduleName: String, isBase: Bool, digest: String) throws -> PythonFileFacts {
        guard String(bytes: bytes, encoding: .utf8) != nil else { throw PythonSyntaxError.invalidSyntax }
        guard let parser = ts_parser_new() else { throw PythonSyntaxError.parserUnavailable }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, tree_sitter_python()) else { throw PythonSyntaxError.parserUnavailable }
        ts_parser_set_timeout_micros(parser, 100_000)
        let tree = bytes.withUnsafeBytes { raw in ts_parser_parse_string(parser, nil, raw.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(bytes.count)) }
        guard let tree else { throw PythonSyntaxError.budget }; defer { ts_tree_delete(tree) }
        let root = ts_tree_root_node(tree)
        guard !ts_node_has_error(root) else { throw PythonSyntaxError.invalidSyntax }
        var imports: [PythonImport] = [], assignments: [PythonAssignment] = [], classes: [PythonClass] = []
        var manifest: PythonExpression?
        for node in children(root) {
            if let value = assignment(node) { assignments.append(value) }
            switch type(node) {
            case "import_statement":
                for child in children(node) {
                    let aliased = type(child) == "aliased_import"
                    let target = text(aliased ? field(child, "name") : child)
                    let alias = aliased ? text(field(child, "alias")) : target.split(separator: ".").first.map(String.init) ?? target
                    imports.append(.init(alias: alias, target: aliased ? target : alias))
                }
            case "import_from_statement":
                let moduleNode = field(node, "module_name"), rawModule = text(moduleNode)
                let leading = rawModule.prefix(while: { $0 == "." }).count
                var prefix = rawModule
                if leading > 0 {
                    var components = modulePath.split(separator: ".").map(String.init)
                    if !relativePath.hasSuffix("/__init__.py") { _ = components.popLast() }
                    for _ in 1..<leading { if !components.isEmpty { components.removeLast() } }
                    let suffix = String(rawModule.dropFirst(leading))
                    prefix = (components + (suffix.isEmpty ? [] : [suffix])).joined(separator: ".")
                }
                for child in children(node) where ts_node_start_byte(child) != ts_node_start_byte(moduleNode) {
                    guard ["dotted_name", "aliased_import", "identifier"].contains(type(child)) else { continue }
                    let aliased = type(child) == "aliased_import", imported = text(aliased ? field(child, "name") : child)
                    let alias = aliased ? text(field(child, "alias")) : imported
                    imports.append(.init(alias: alias, target: prefix + "." + imported))
                }
            case "class_definition", "decorated_definition":
                let declaration = type(node) == "decorated_definition" ? field(node, "definition") : node
                guard type(declaration) == "class_definition" else { continue }
                classes.append(.init(name: text(field(declaration, "name")), bases: children(field(declaration, "superclasses")).map(path),
                    assignments: children(field(declaration, "body")).compactMap(assignment), range: range(declaration)))
            case "expression_statement":
                if relativePath.hasSuffix("__manifest__.py"), let child = children(node).first, type(child) == "dictionary" { manifest = expression(child) }
            default: break
            }
        }
        return .init(relativePath: relativePath, modulePath: modulePath, moduleName: moduleName, digest: digest, isBase: isBase,
                     imports: imports, assignments: assignments, classes: classes, manifest: manifest)
    }

    private func decodeString(_ source: String) -> String? {
        guard let first = source.firstIndex(where: { $0 == "'" || $0 == "\"" }) else { return nil }
        let prefix = source[..<first].lowercased()
        guard !prefix.contains("f"), !prefix.contains("b") else { return nil }
        let quote = source[first], after = source[first...], delimiter = after.hasPrefix(String(repeating: String(quote), count: 3)) ? 3 : 1
        guard after.count >= delimiter * 2 else { return nil }
        let content = String(after.dropFirst(delimiter).dropLast(delimiter))
        if prefix.contains("r") { return content }
        let chars = Array(content.unicodeScalars); var result = String.UnicodeScalarView(), index = 0
        while index < chars.count {
            let char = chars[index]; index += 1
            guard char == "\\" else { result.append(char); continue }
            guard index < chars.count else { return nil }
            let escaped = chars[index]; index += 1
            switch escaped {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "b": result.append("\u{8}")
            case "f": result.append("\u{c}")
            case "v": result.append("\u{b}")
            case "a": result.append("\u{7}")
            case "\n": break
            case "\r":
                if index < chars.count, chars[index] == "\n" { index += 1 }
            case "N": return nil
            case "\\", "'", "\"": result.append(escaped)
            case "x", "u", "U":
                let count = escaped == "x" ? 2 : escaped == "u" ? 4 : 8
                guard index + count <= chars.count,
                      let number = UInt32(String(String.UnicodeScalarView(chars[index..<(index + count)])), radix: 16), let scalar = UnicodeScalar(number) else { return nil }
                result.append(scalar); index += count
            case "0"..."7":
                var digits = String(escaped)
                while digits.count < 3, index < chars.count, chars[index] >= "0", chars[index] <= "7" { digits.unicodeScalars.append(chars[index]); index += 1 }
                guard let number = UInt32(digits, radix: 8), let scalar = UnicodeScalar(number) else { return nil }; result.append(scalar)
            default: result.append("\\"); result.append(escaped)
            }
        }
        return String(result)
    }
}

extension PythonExpression {
    /// Conservative retained-allocation estimate, including enum boxes, collection storage and String payloads.
    var retainedBytes: Int {
        switch self {
        case .string(let value), .number(let value): return 64 + value.utf8.count
        case .boolean, .none, .unknown: return 32
        case .reference(let parts): return 80 + parts.reduce(0) { $0 + 48 + $1.utf8.count }
        case .sequence(let values): return 96 + values.reduce(0) { $0 + 16 + $1.retainedBytes }
        case .dictionary(let pairs): return 96 + pairs.reduce(0) { $0 + 32 + $1.key.retainedBytes + $1.value.retainedBytes }
        case .addition(let lhs, let rhs): return 64 + lhs.retainedBytes + rhs.retainedBytes
        case .call(let path, let args, let keywords):
            return 128 + path.reduce(0) { $0 + 64 + $1.utf8.count } + args.reduce(0) { $0 + 16 + $1.retainedBytes }
                + keywords.reduce(0) { $0 + 96 + $1.key.utf8.count + $1.value.retainedBytes }
        }
    }
}
extension PythonFileFacts {
    var retainedBytes: Int {
        func assignmentSize(_ value: PythonAssignment) -> Int { 160 + value.name.utf8.count + value.value.retainedBytes }
        return 512 + relativePath.utf8.count + modulePath.utf8.count + moduleName.utf8.count + digest.utf8.count
            + imports.reduce(0) { $0 + 128 + $1.alias.utf8.count + $1.target.utf8.count }
            + assignments.reduce(0) { $0 + assignmentSize($1) }
            + classes.reduce(0) { total, cls in total + 256 + cls.name.utf8.count
                + cls.bases.flatMap { $0 }.reduce(0) { $0 + 64 + $1.utf8.count }
                + cls.assignments.reduce(0) { $0 + assignmentSize($1) } }
            + (manifest?.retainedBytes ?? 0)
    }
}
extension ProjectFactProvenance {
    var retainedBytes: Int { 256 + relativePath.utf8.count + sourceDigest.utf8.count }
}
extension ProjectFieldMetadata {
    var retainedBytes: Int {
        640 + name.utf8.count + provenance.retainedBytes
            + choices.reduce(0) { sum, choice in sum + 256 + choice.provenance.retainedBytes
                + [choice.key, choice.label, choice.color, choice.icon, choice.description, choice.shortLabel].compactMap { $0 }.reduce(0) { $0 + 64 + $1.utf8.count } }
            + [declaredType, inverse, relationModel, displayLabel, choicesDiagnostic].compactMap { $0 }.reduce(0) { $0 + 64 + $1.utf8.count }
            + (related ?? []).reduce(0) { $0 + 64 + $1.utf8.count }
            + declarationAttributes.reduce(0) { $0 + 64 + $1.utf8.count }
            + (selectionAdditionOrder ?? []).reduce(0) { $0 + 64 + $1.utf8.count }
    }
}
extension ProjectModelMetadata {
    var retainedBytes: Int {
        512 + name.utf8.count + (tableName?.utf8.count ?? 0) + namespace.utf8.count
            + provenance.reduce(0) { $0 + $1.retainedBytes }
            + inheritedModels.reduce(0) { $0 + 64 + $1.utf8.count }
            + delegatedModels.reduce(0) { $0 + 128 + $1.key.utf8.count + $1.value.utf8.count }
            + fields.reduce(0) { $0 + $1.retainedBytes }
    }
}
