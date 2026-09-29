import Foundation
import CryptoKit
import DB3Core

/// The caller holds the worksheet operation lease for each complete call. These
/// operations deliberately reuse that physical session, role and transaction.
public enum PostgresTableEditing {
    public static func describe(relationOID: UInt32, on session: any DatabaseSession,
                                metadataProvider: (any FieldEditorMetadataProvider)? = nil) async throws -> EditableTable {
        try await protectedRead(on: session) { try await describeUnprotected(relationOID: relationOID, on: session, metadataProvider: metadataProvider) }
    }

    /// Adopts a verified CURRENT baseline for a directly projected result row.
    /// The caller first proves a single-table SELECT with SQLDirectTableSelect;
    /// libpq provenance alone cannot disambiguate self-join aliases.
    /// Comparing the original projected values and fetching the complete row plus
    /// xmin happens in one SELECT. This is not the original query's xmin.
    public static func verifyProjectedRow(table: EditableTable, projection: ResultEditProjection,
                                          rowIndex: Int, row: DatabaseRow, on session: any DatabaseSession,
                                          metadataProvider: (any FieldEditorMetadataProvider)? = nil) async throws -> EditableRowSnapshot {
        if let reason = table.readOnlyReason { throw DatabaseError(reason) }
        guard rowIndex >= 0, !projection.hasHiddenVersion,
              row.count == projection.resultToTable.count else {
            throw DatabaseError("The result projection no longer matches this row.")
        }
        let key = try projection.primaryKey(in: row, table: table)
        guard key.count == table.primaryKeyColumns.count, !key.isEmpty else {
            throw DatabaseError("The result must include the complete primary key before its values can be edited.")
        }
        return try await protectedRead(on: session) {
            let current = try await describeUnprotected(relationOID: table.relationOID, on: session, metadataProvider: metadataProvider)
            guard current.metadataRevision == table.metadataRevision,
                  current.schema == table.schema, current.name == table.name, current.readOnlyReason == nil else {
                throw DatabaseError("The table definition or permissions changed. Run the query again before editing its result.")
            }
            var parameters: [String?] = []
            func bind(_ value: DatabaseValue, type: String) -> String {
                parameters.append(value == .null ? nil : value.displayText)
                return "$\(parameters.count)::\(type)"
            }
            var predicates = zip(table.primaryKeyColumns, key).map { column, value in
                DatabaseObject.quoteIdentifier(column.name) + " = " + bind(value, type: column.typeSQL)
            }
            // A concurrent drop/recreate must never resolve the old name to a
            // replacement table between metadata inspection and this read.
            predicates.append("tableoid = " + bind(.text(String(table.relationOID)), type: "pg_catalog.oid"))
            for (resultIndex, tableIndex) in projection.resultToTable.enumerated() {
                guard let tableIndex else { continue } // Expressions remain read-only.
                guard table.columns.indices.contains(tableIndex) else { throw DatabaseError("A projected column no longer exists.") }
                let column = table.columns[tableIndex], identifier = DatabaseObject.quoteIdentifier(column.name)
                if column.kind == .text, !column.typeSQL.isEmpty {
                    let parameter = bind(row[resultIndex], type: column.typeSQL)
                    predicates.append("(\(identifier) COLLATE pg_catalog.\"C\") IS NOT DISTINCT FROM (\(parameter) COLLATE pg_catalog.\"C\")")
                } else if column.kind != nil, !column.typeSQL.isEmpty {
                    predicates.append(identifier + " IS NOT DISTINCT FROM " + bind(row[resultIndex], type: column.typeSQL))
                } else {
                    // Unsupported columns remain read-only. Their original wire
                    // text still participates in exact baseline verification.
                    let parameter = bind(row[resultIndex], type: "pg_catalog.text")
                    predicates.append("(\(identifier)::pg_catalog.text COLLATE pg_catalog.\"C\") IS NOT DISTINCT FROM (\(parameter) COLLATE pg_catalog.\"C\")")
                }
            }
            let names = table.columns.map { DatabaseObject.quoteIdentifier($0.name) }.joined(separator: ", ")
            let sql = "SELECT \(names), xmin::text FROM ONLY \(table.quotedName) WHERE \(predicates.joined(separator: " AND ")) LIMIT 2"
            let response = try await query(sql, parameters: parameters, maximumRows: 2, maximumBytes: 2 * 1024 * 1024, on: session)
            guard response.rows.count == 1 else {
                throw DatabaseError("This result row changed, disappeared, or no longer identifies exactly one visible base-table row. Run the query again before editing it.")
            }
            return try table.snapshot(rowIndex: rowIndex, fetchedRow: response.rows[0])
        }
    }

    public static func apply(plan: EditPlan, on session: any DatabaseSession,
                             currentContext: EditSourceContext, environment: ConnectionEnvironment,
                             prepareResult: (@Sendable ([Int: EditableRowSnapshot]) async throws -> Void)? = nil,
                             metadataProvider: (any FieldEditorMetadataProvider)? = nil,
                             authorizeAutoCommit: (@Sendable () async throws -> Void)? = nil) async throws -> EditApplyResult {
        guard plan.context == currentContext else { throw DatabaseError("The preview belongs to an older result or transaction. Rebuild the preview before applying.") }
        guard plan.mode != .auto || (environment == .development && plan.environment == .development) else {
            throw DatabaseError("Automatic commit is available only for an explicitly classified development connection.")
        }
        if plan.mode == .auto { try await authorizeAutoCommit?() }
        try Task.checkCancellation()
        guard environment == plan.environment else { throw DatabaseError("The connection environment changed. Rebuild the preview.") }
        guard !plan.statements.isEmpty, plan.statements.count <= EditDraftStore.maximumRows else { throw DatabaseError("The edit batch is empty or exceeds its row limit.") }
        let initial = await session.transactionState()
        guard initial == .idle || initial == .inTransaction else { throw DatabaseError("Roll back the failed transaction or reconnect before applying changes.") }
        guard plan.mode != .auto || initial == .idle else { throw DatabaseError("Resolve the existing transaction before using Apply & Commit.") }
        let savepoint = "db3_edit_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var opened = false, saved = false, committing = false
        var conflict: EditRowDraft?
        do {
            if initial == .idle {
                opened = true
                let began = try await shieldedCommand("BEGIN READ WRITE", on: session)
                guard began.command == "BEGIN", began.transaction == .inTransaction else { throw DatabaseError("PostgreSQL did not start the edit transaction.") }
            }
            _ = try await shieldedCommand("SAVEPOINT \(savepoint)", on: session); saved = true
            try Task.checkCancellation()
            try await PostgresTransactionAccess.requireWritable(on: session)
            // Hold the relation against DDL until the edit transaction ends.
            // The lock name is quoted; verify its OID immediately afterwards.
            if plan.statements.allSatisfy(\.isInsert) {
                // A zero-row SELECT acquires ACCESS SHARE while honoring per-column
                // grants. Explicit LOCK can require broader table-level privileges.
                let key = DatabaseObject.quoteIdentifier(plan.table.primaryKeyColumns[0].name)
                _ = try await command("SELECT \(key) FROM ONLY \(plan.table.quotedName) LIMIT 0", on: session)
            } else {
                _ = try await command("LOCK TABLE ONLY \(plan.table.quotedName) IN ROW EXCLUSIVE MODE", on: session)
            }
            let metadata = try await describeUnprotected(relationOID: plan.table.relationOID, on: session, metadataProvider: metadataProvider)
            guard metadata.metadataRevision == plan.table.metadataRevision,
                  metadata.schema == plan.table.schema, metadata.name == plan.table.name,
                  metadata.readOnlyReason == nil,
                  (!plan.statements.contains(where: \.isInsert) || metadata.insertReadOnlyReason == nil) else { throw DatabaseError("The table definition or permissions changed. Reload the editable snapshot before applying.") }
            var returned: [Int: EditableRowSnapshot] = [:], bytes = 0
            let reservation = try EditPayloadReservation()
            for statement in plan.statements {
                try await metadataProvider?.validatePreparedMetadata(relationOID: plan.table.relationOID)
                try Task.checkCancellation()
                let response = try await query(statement.sql, parameters: statement.parameters.map(\.text), maximumRows: 2, on: session)
                let expectedCommand = statement.isInsert ? "INSERT 0 1" : "UPDATE 1"
                guard response.summary.command == expectedCommand, response.summary.rowCount == 1, response.rows.count == 1 else {
                    if let draft = statement.row {
                        conflict = draft
                        throw EditConflict(row: draft, freshRow: nil)
                    }
                    throw DatabaseError("PostgreSQL did not insert exactly one row. The entire apply batch was rolled back; the new row remains staged.")
                }
                let row = try plan.table.snapshot(rowIndex: statement.rowIndex, fetchedRow: response.rows[0])
                bytes += row.byteCount
                guard bytes <= 2 * 1024 * 1024 else { throw DatabaseError("The returned edit batch exceeds its 2 MiB limit.") }
                try reservation.resize(bytes: bytes)
                returned[row.rowIndex] = row
            }
            try Task.checkCancellation()
            try await prepareResult?(returned)
            try await metadataProvider?.validatePreparedMetadata(relationOID: plan.table.relationOID)
            try Task.checkCancellation()
            _ = try await shieldedCommand("RELEASE SAVEPOINT \(savepoint)", on: session); saved = false
            if plan.mode == .auto {
                guard environment == .development, plan.environment == .development else { throw DatabaseError("Automatic commit is disabled for this connection.") }
                try await authorizeAutoCommit?()
                try await metadataProvider?.validatePreparedMetadata(relationOID: plan.table.relationOID)
                try Task.checkCancellation()
                committing = true
                let result = try await command("COMMIT", on: session)
                committing = false
                guard result.command == "COMMIT", result.transaction == .idle else { throw DatabaseError("PostgreSQL did not confirm COMMIT. The batch was not reported as committed.") }
                return EditApplyResult(rows: returned, transaction: .idle, committed: true, reservation: reservation)
            }
            let state = await session.transactionState()
            guard state == .inTransaction else { throw DatabaseError("The transaction is no longer available. The apply outcome is unknown.") }
            return EditApplyResult(rows: returned, transaction: state, committed: false, reservation: reservation)
        } catch {
            let failureState = await session.transactionState()
            if committing && ((error as? DatabaseError)?.connectionLost == true || failureState == .unknown || (failureState == .idle && (error is CancellationError || (error as? DatabaseError)?.sqlState == nil))) {
                throw DatabaseError("Outcome unknown: the connection was lost while awaiting COMMIT. Reconnect and inspect the database; this batch will not be replayed.", connectionLost: true, commitOutcomeUnknown: true)
            }
            // A separate task ignores the cancelled caller while draining recovery.
            // It is awaited, so the owner cannot release its operation lease early.
            let recovery = Task.detached { [opened, saved] in
                let state = await session.transactionState()
                if opened && state != .idle && state != .unknown {
                    _ = try await command("ROLLBACK", on: session)
                } else if saved && state != .idle && state != .unknown {
                    _ = try await command("ROLLBACK TO SAVEPOINT \(savepoint)", on: session)
                    _ = try await command("RELEASE SAVEPOINT \(savepoint)", on: session)
                } else if state == .unknown { throw DatabaseError("The connection was lost during edit recovery.", connectionLost: true) }
            }
            do { try await recovery.value }
            catch { throw DatabaseError("Edit recovery could not be confirmed. The draft is preserved but unverified; reconnect before continuing.", connectionLost: true) }
            if let conflict {
                // Fresh values are for comparison only. Never silently rebase or retry.
                let fresh = try? await Task.detached {
                    try await protectedRead(on: session) { try await fetchCurrent(row: conflict, table: plan.table, on: session) }
                }.value
                throw EditConflict(row: conflict, freshRow: fresh.flatMap { $0 }.flatMap { try? plan.table.snapshot(rowIndex: conflict.id, fetchedRow: $0) })
            }
            throw error
        }
    }

    public static func lookup(foreignKey: EditableForeignKey, table: EditableTable, search: String,
                              cursor: [DatabaseValue]? = nil, on session: any DatabaseSession,
                              metadataProvider: (any FieldEditorMetadataProvider)? = nil) async throws -> ForeignKeyPage {
        if let reason = foreignKey.unavailableReason { throw DatabaseError(reason) }
        guard search.utf8.count <= 4096, !foreignKey.targetColumns.isEmpty,
              foreignKey.localAttributes.count == foreignKey.targetColumns.count,
              cursor == nil || cursor?.count == foreignKey.targetColumns.count else { throw DatabaseError("The referenced-row lookup request is invalid or too large.") }
        return try await protectedRead(on: session) {
            let refreshed = try await describeUnprotected(relationOID: table.relationOID, on: session, metadataProvider: metadataProvider)
            guard refreshed.metadataRevision == table.metadataRevision,
                  refreshed.foreignKeys.contains(foreignKey) else { throw DatabaseError("The relationship definition changed. Reload this editable table.") }
            let names = foreignKey.targetColumns.map { DatabaseObject.quoteIdentifier($0.name) }
            var parameters: [String?] = [search]
            // strpos performs literal, case-insensitive search. Percent, underscore
            // and backslash are ordinary characters, never wildcard patterns.
            var match = names.map { "\($0)::text = $1::text" }
            if let label = foreignKey.labelColumn {
                match.append("pg_catalog.strpos(pg_catalog.lower(\(DatabaseObject.quoteIdentifier(label.name))::text), pg_catalog.lower($1::text)) > 0")
            }
            var predicates = ["($1::text = '' OR \(match.joined(separator: " OR ")))"]
            // Stable keyset order is the referenced unique key, including every
            // composite position. NULL keys cannot identify a relationship.
            predicates += names.map { "\($0) IS NOT NULL" }
            if let cursor {
                let bindings = zip(cursor, foreignKey.targetColumns).map { value, column -> String in
                    parameters.append(value == .null ? nil : value.displayText)
                    return "$\(parameters.count)::\(column.typeSQL)"
                }
                predicates.append("(\(names.joined(separator: ", "))) > (\(bindings.joined(separator: ", ")))")
            }
            let label = foreignKey.labelColumn.map { "pg_catalog.left(\(DatabaseObject.quoteIdentifier($0.name))::text, 1024)" } ?? "NULL::text"
            let qualified = DatabaseObject.quoteIdentifier(foreignKey.targetSchema) + "." + DatabaseObject.quoteIdentifier(foreignKey.targetTable)
            let response = try await query("SELECT \(names.joined(separator: ", ")), \(label) FROM \(qualified) WHERE \(predicates.joined(separator: " AND ")) ORDER BY \(names.joined(separator: ", ")) LIMIT 51", parameters: parameters, maximumRows: 51, maximumBytes: 2 * 1024 * 1024, on: session)
            let candidates = try response.rows.prefix(50).map { row -> ForeignKeyCandidate in
                guard row.count == names.count + 1 else { throw DatabaseError("PostgreSQL returned malformed referenced-row data.") }
                return ForeignKeyCandidate(key: Array(row.dropLast()), label: row.last.flatMap { if case .text(let text) = $0 { text } else { nil } })
            }
            return ForeignKeyPage(candidates: candidates, nextCursor: response.rows.count > 50 ? candidates.last?.key : nil)
        }
    }

    private static func fetchCurrent(row: EditRowDraft, table: EditableTable, on session: any DatabaseSession) async throws -> DatabaseRow? {
        let predicates = table.primaryKeyColumns.enumerated().map { offset, column in DatabaseObject.quoteIdentifier(column.name) + " = $\(offset + 1)::\(column.typeSQL)" }
        let sql = "SELECT \(table.columns.map { DatabaseObject.quoteIdentifier($0.name) }.joined(separator: ", ")), xmin::text FROM ONLY \(table.quotedName) WHERE \(predicates.joined(separator: " AND ")) LIMIT 2"
        let response = try await query(sql, parameters: table.primaryKeyColumns.map { row.original.values[$0.index].displayText }, maximumRows: 2, on: session)
        guard response.rows.count <= 1 else { throw DatabaseError("The original primary key no longer uniquely identifies a row.") }
        return response.rows.first
    }

    private static func describeUnprotected(relationOID: UInt32, on session: any DatabaseSession,
                                            metadataProvider: (any FieldEditorMetadataProvider)? = nil) async throws -> EditableTable {
        let response = try await query(metadataSQL, parameters: [String(relationOID)], maximumRows: 1600, on: session)
        guard let first = response.rows.first, response.rows.allSatisfy({ $0.count == 25 }),
              let databaseOID = UInt32(first[20].displayText), let schemaOID = UInt32(first[21].displayText) else { throw DatabaseError("The table no longer exists or its metadata is unavailable.") }
        let schema = try text(first[0]), name = try text(first[1])
        let enumResponse = try await query(enumTypesSQL, parameters: [String(relationOID)], maximumRows: ValueChoiceSet.maximumChoices,
                                           maximumBytes: ValueChoiceSet.maximumBytes, on: session)
        var enumRows: [UInt32: [DatabaseRow]] = [:]
        for row in enumResponse.rows {
            guard row.count == 7, let oid = UInt32(row[0].displayText) else { throw DatabaseError("The enum catalog metadata is invalid.") }
            enumRows[oid, default: []].append(row)
        }
        var enums: [UInt32: (typeSQL: String, choices: ValueChoiceSet, permitted: Bool)] = [:]
        for (oid, rows) in enumRows {
            let first = rows[0], typeSQL = DatabaseObject.quoteIdentifier(try text(first[1])) + "." + DatabaseObject.quoteIdentifier(try text(first[2]))
            let labels = try rows.compactMap { row -> ValueChoice? in
                if row[4] == .null { return nil }
                let label = try text(row[4]); return ValueChoice(key: label, label: label)
            }
            // Include label OIDs and sort positions: replacement, rename and
            // reordered labels must all invalidate previously prepared edits.
            let revision = rows.map { $0.map { "\($0.byteCount):\($0.displayText)" }.joined(separator: "|") }.joined(separator: "\n")
            enums[oid] = (typeSQL, try ValueChoiceSet(choices: labels, source: "PostgreSQL enum \(typeSQL)", revision: revision, origin: .postgresEnum(typeOID: oid)), first[6] == .text("true"))
        }
        func editingType(_ oid: UInt32) -> (String, ScalarEditorKind)? {
            if let type = enums[oid] { return (type.typeSQL, .enumeration) }
            return typeInfo(oid)
        }
        let primary = try response.rows.compactMap { row -> (Int, Int)? in
            guard let order = Int(try text(row[16])), order > 0, let attribute = Int(try text(row[5])) else { return nil }
            return (order, attribute)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        let tableReason: String?
        if try text(first[2]) != "r" || text(first[3]) == "true" || text(first[4]) == "true" { tableReason = "Only ordinary tables without partitioning or inheritance can be edited." }
        else if primary.isEmpty { tableReason = "A usable primary key is required for row editing." }
        else if response.rows.contains(where: { $0[13] != .text("true") }) { tableReason = "SELECT permission is required for every displayed column." }
        else if response.rows.filter({ primary.contains(Int($0[5].displayText) ?? -1) }).contains(where: { editingType(UInt32($0[7].displayText) ?? 0) == nil }) { tableReason = "This primary key type is not supported for safe row editing." }
        else { tableReason = nil }
        var columns = try response.rows.enumerated().map { index, row -> EditableColumn in
            guard let attribute = Int(try text(row[5])), let oid = UInt32(try text(row[7])) else { throw DatabaseError("The table column metadata is invalid.") }
            let info = editingType(oid)
            let reason: String?
            if primary.contains(attribute) { reason = "Primary-key values are read-only in this version." }
            else if try text(row[11]) != "" { reason = "PostgreSQL generated columns are read-only." }
            else if try text(row[12]) != "" { reason = "Identity columns are read-only." }
            else if try text(row[14]) != "true" { reason = "The current role has no UPDATE permission for this column." }
            else if try text(row[15]) != "true" { reason = "Nondeterministic collation comparisons are not supported for editing." }
            else if enums[oid]?.permitted == false { reason = "The current role has no USAGE permission for this enum type." }
            else if info == nil { reason = "This PostgreSQL type does not yet support safe editing and conflict comparison." }
            else { reason = nil }
            let insertReason: String?
            if try text(row[11]) != "" { insertReason = "PostgreSQL generated columns use their database default." }
            else if try text(row[12]) != "" { insertReason = "Identity columns use their database default." }
            else if try text(row[22]) != "true" { insertReason = "The current role has no INSERT permission for this column." }
            else if enums[oid]?.permitted == false { insertReason = "The current role has no USAGE permission for this enum type." }
            else if info == nil { insertReason = "This PostgreSQL type does not yet support safe editing." }
            else { insertReason = nil }
            let hasDefault = row[23] != .null || row[11] != .text("") || row[12] != .text("")
            return EditableColumn(index: index, attributeNumber: attribute, name: try text(row[6]), typeOID: oid,
                                  typeSQL: info?.0 ?? "", nullable: try text(row[10]) != "true", kind: info?.1, readOnlyReason: reason,
                                  valueChoices: enums[oid]?.choices, insertReadOnlyReason: insertReason, hasDefault: hasDefault)
        }
        var applicationRevision = ""
        var choiceFingerprints = Set(enums.values.map { $0.choices.fingerprint })
        var choiceBytes = enums.values.reduce(0) { $0 + $1.choices.byteCount }
        guard choiceBytes <= 8 * 1_024 * 1_024 else { throw DatabaseError("This table's enum vocabularies exceed the 8 MiB metadata limit.") }
        if let metadataProvider {
            await metadataProvider.prepare(databaseOID: databaseOID, schemaOID: schemaOID, relationOID: relationOID,
                                           schema: schema, table: name, columns: columns)
            for index in columns.indices {
                let column = columns[index]
                let metadata = await metadataProvider.metadata(relationOID: relationOID, attributeNumber: column.attributeNumber)
                var choices = column.valueChoices
                if choices == nil, let supplied = await metadataProvider.choices(relationOID: relationOID, attributeNumber: column.attributeNumber) {
                    let plain = EditableColumn(index: column.index, attributeNumber: column.attributeNumber, name: column.name,
                        typeOID: column.typeOID, typeSQL: column.typeSQL, nullable: column.nullable, kind: column.kind)
                    let compatible = !supplied.isAuthoritative && [.text, .integer, .boolean].contains(column.kind) && supplied.choices.allSatisfy { (try? EditDraftStore.validate(.text($0.key), column: plain)) != nil }
                    if supplied.isResolved && !compatible {
                        choices = try ValueChoiceSet(choices: [], source: supplied.source, revision: supplied.fingerprint,
                            status: .unresolved("The source choice keys are not compatible with this database column."))
                    } else { choices = supplied }
                    if let retained = choices, !choiceFingerprints.contains(retained.fingerprint) {
                        if choiceBytes + retained.byteCount > 8 * 1_024 * 1_024 {
                            choices = try ValueChoiceSet(choices: [], source: String(retained.source.prefix(1_024)), revision: retained.fingerprint,
                                status: .unresolved("This table's source choices exceed the 8 MiB metadata limit."))
                        } else { choiceFingerprints.insert(retained.fingerprint); choiceBytes += retained.byteCount }
                    }
                }
                columns[index] = EditableColumn(index: column.index, attributeNumber: column.attributeNumber, name: column.name,
                    typeOID: column.typeOID, typeSQL: column.typeSQL, nullable: column.nullable, kind: column.kind,
                    readOnlyReason: column.readOnlyReason, applicationMetadata: metadata, valueChoices: choices,
                    insertReadOnlyReason: column.insertReadOnlyReason, hasDefault: column.hasDefault)
                let parts = [String(column.attributeNumber), metadata?.classification.rawValue ?? "", metadata?.modelField ?? "", metadata?.source ?? "", metadata?.revision ?? "", choices?.fingerprint ?? ""]
                applicationRevision += parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|") + "\n"
            }
        }
        let fkResponse = try await query(foreignKeysSQL, parameters: [String(relationOID)], maximumRows: 512, on: session)
        var groups: [UInt32: [DatabaseRow]] = [:]
        for row in fkResponse.rows {
            guard row.count == 18, let oid = UInt32(try text(row[0])) else { throw DatabaseError("The foreign-key metadata is invalid.") }
            groups[oid, default: []].append(row)
        }
        guard groups.count <= 64 else { throw DatabaseError("This table exceeds the supported 64 relationships for editing.") }
        let foreignKeys = try groups.keys.sorted().map { oid -> EditableForeignKey in
            let rows = groups[oid]!.sorted { Int($0[2].displayText)! < Int($1[2].displayText)! }, first = rows[0]
            let local = try rows.map { row -> Int in guard let n = Int(try text(row[3])) else { throw DatabaseError("Invalid relationship column.") }; return n }
            let target = try rows.enumerated().map { index, row -> EditableColumn in
                guard let attribute = Int(try text(row[8])), let typeOID = UInt32(try text(row[10])) else { throw DatabaseError("Invalid referenced column.") }
                let info = editingType(typeOID)
                return EditableColumn(index: index, attributeNumber: attribute, name: try text(row[9]), typeOID: typeOID, typeSQL: info?.0 ?? "", nullable: true, kind: info?.1,
                                      valueChoices: enums[typeOID]?.choices)
            }
            let label: EditableColumn?
            if case .text(let labelName) = first[14], case .text(let attribute) = first[15], let att = Int(attribute) {
                label = EditableColumn(index: 0, attributeNumber: att, name: labelName, typeOID: 25, typeSQL: "pg_catalog.text", nullable: true, kind: .text)
            } else { label = nil }
            let overlap = local.contains { att in groups.keys.filter { key in groups[key]!.contains { Int($0[3].displayText) == att } }.count > 1 }
            let reason: String?
            if local.contains(where: { att in columns.first { $0.attributeNumber == att }?.effectiveReadOnlyReason != nil }) { reason = "Every component of this relationship must be editable." }
            else if overlap { reason = "Overlapping foreign-key constraints require manual key entry and review." }
            else if target.contains(where: { $0.kind == nil || $0.kind == .json }) { reason = "This referenced key type does not support ordered lookup." }
            else if rows.contains(where: { $0[11] != .text("true") || $0[12] != .text("true") || $0[13] != .text("true") }) { reason = "The current role cannot list this relationship, or its key collation is unsupported." }
            else { reason = nil }
            guard let targetOID = UInt32(try text(first[4])) else { throw DatabaseError("Invalid referenced relation.") }
            return EditableForeignKey(id: oid, name: try text(first[1]), localAttributes: local, targetRelationOID: targetOID,
                                      targetSchema: try text(first[5]), targetTable: try text(first[6]), targetColumns: target, labelColumn: label, unavailableReason: reason)
        }
        // Hash exact bytes rather than retaining the entire catalog response or
        // relying on Unicode-normalizing String equality for enum labels.
        var fingerprint = SHA256()
        for row in response.rows + fkResponse.rows + enumResponse.rows {
            for value in row {
                fingerprint.update(data: Data("\(value.byteCount):".utf8))
                fingerprint.update(data: Data(value.displayText.utf8)); fingerprint.update(data: Data("|".utf8))
            }
            fingerprint.update(data: Data("\n".utf8))
        }
        fingerprint.update(data: Data(applicationRevision.utf8))
        let revision = fingerprint.finalize().map { String(format: "%02x", $0) }.joined()
        let insertReason: String?
        if first[24] != .text("true") { insertReason = "The current role has no USAGE permission for this schema." }
        else if response.rows.allSatisfy({ $0[22] != .text("true") }) { insertReason = "The current role has no INSERT permission for this table." }
        else if let required = columns.first(where: { !$0.nullable && !$0.hasDefault && $0.effectiveInsertReadOnlyReason != nil }) {
            insertReason = "Required column \(required.name) cannot be inserted: \(required.effectiveInsertReadOnlyReason!)"
        } else { insertReason = nil }
        return EditableTable(relationOID: relationOID, schema: schema, name: name, columns: columns, primaryKeyAttributes: primary,
                             foreignKeys: foreignKeys, metadataRevision: revision, readOnlyReason: tableReason, insertReadOnlyReason: insertReason)
    }

    private static func typeInfo(_ oid: UInt32) -> (String, ScalarEditorKind)? {
        switch oid {
        case 16: ("pg_catalog.bool", .boolean)
        case 20: ("pg_catalog.int8", .integer)
        case 21: ("pg_catalog.int2", .integer)
        case 23: ("pg_catalog.int4", .integer)
        case 25: ("pg_catalog.text", .text)
        case 1042: ("pg_catalog.bpchar", .text)
        case 1043: ("pg_catalog.varchar", .text)
        case 700: ("pg_catalog.float4", .floatingPoint)
        case 701: ("pg_catalog.float8", .floatingPoint)
        case 1700: ("pg_catalog.numeric", .decimal)
        case 1082: ("pg_catalog.date", .date)
        case 1083: ("pg_catalog.time", .time)
        case 1266: ("pg_catalog.timetz", .time)
        case 1114: ("pg_catalog.timestamp", .timestamp)
        case 1184: ("pg_catalog.timestamptz", .timestamp)
        case 2950: ("pg_catalog.uuid", .uuid)
        case 3802: ("pg_catalog.jsonb", .json)
        default: nil
        }
    }

    private static func protectedRead<T: Sendable>(on session: any DatabaseSession,
                                                  operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let state = await session.transactionState()
        guard state == .idle || state == .inTransaction else { throw DatabaseError("Roll back the failed transaction or reconnect before loading editing metadata.") }
        let name = "db3_lookup_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let saved = state == .inTransaction
        try Task.checkCancellation()
        if saved { _ = try await shieldedCommand("SAVEPOINT \(name)", on: session) }
        do {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            if saved { _ = try await shieldedCommand("RELEASE SAVEPOINT \(name)", on: session) }
            return result
        } catch {
            if saved {
                let recovery = Task.detached {
                    _ = try await command("ROLLBACK TO SAVEPOINT \(name)", on: session)
                    _ = try await command("RELEASE SAVEPOINT \(name)", on: session)
                }
                do { try await recovery.value }
                catch { throw DatabaseError("The lookup was interrupted and transaction recovery failed. Reconnect before continuing.", connectionLost: true) }
            }
            throw error
        }
    }

    private static func text(_ value: DatabaseValue) throws -> String {
        guard case .text(let text) = value else { throw DatabaseError("PostgreSQL returned incomplete editing metadata.") }; return text
    }
    private static func shieldedCommand(_ sql: String, on session: any DatabaseSession) async throws -> QuerySummary {
        // Savepoint boundaries are short and deadline-bounded. Finish establishing
        // them before observing cancellation, so recovery always has a known target.
        try await Task.detached { try await command(sql, on: session) }.value
    }
    private static func command(_ sql: String, on session: any DatabaseSession) async throws -> QuerySummary {
        try await query(sql, parameters: [], maximumRows: 0, on: session).summary
    }
    private static func query(_ sql: String, parameters: [String?], maximumRows: Int,
                              maximumBytes: Int = EditDraftStore.maximumPayloadBytes,
                              on session: any DatabaseSession) async throws -> EditingQueryResponse {
        try await withThrowingTaskGroup(of: EditingQueryResponse.self) { group in
            group.addTask {
                let collector = EditingRowCollector(maximumRows: maximumRows, maximumBytes: maximumBytes)
                let summary = try await session.execute(sql: sql, parameters: parameters) { try await collector.consume($0) }
                return await EditingQueryResponse(rows: collector.rows, summary: summary)
            }
            group.addTask { try await Task.sleep(for: .seconds(10)); throw DatabaseError("This editing operation timed out after 10 seconds. Narrow the lookup or retry after reviewing the draft.") }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }; return result
        }
    }

    private static let metadataSQL = """
        SELECT n.nspname::text, c.relname::text, c.relkind::text, c.relispartition::text,
               EXISTS (SELECT 1 FROM pg_catalog.pg_inherits h WHERE h.inhrelid=c.oid OR h.inhparent=c.oid)::text,
               a.attnum::text, a.attname::text, a.atttypid::text, a.atttypmod::text,
               pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull::text, a.attgenerated::text, a.attidentity::text,
               pg_catalog.has_column_privilege(c.oid, a.attnum, 'SELECT')::text,
               pg_catalog.has_column_privilege(c.oid, a.attnum, 'UPDATE')::text,
               COALESCE(coll.collisdeterministic, true)::text,
               COALESCE(pk.position, 0)::text, a.attcollation::text, c.relrowsecurity::text, c.relforcerowsecurity::text,
               (SELECT d.oid::text FROM pg_catalog.pg_database d WHERE d.datname=pg_catalog.current_database()), n.oid::text,
               pg_catalog.has_column_privilege(c.oid, a.attnum, 'INSERT')::text,
               pg_catalog.pg_get_expr(ad.adbin, ad.adrelid), pg_catalog.has_schema_privilege(n.oid, 'USAGE')::text
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
        LEFT JOIN pg_catalog.pg_collation coll ON coll.oid=a.attcollation
        LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid=c.oid AND ad.adnum=a.attnum
        LEFT JOIN LATERAL (
            SELECT key.ordinality AS position FROM pg_catalog.pg_index i,
                 LATERAL pg_catalog.unnest(i.indkey) WITH ORDINALITY key(attnum, ordinality)
            WHERE i.indrelid=c.oid AND i.indisprimary AND i.indisvalid AND key.attnum=a.attnum AND key.ordinality<=i.indnkeyatts
        ) pk ON true
        WHERE c.oid=$1::oid ORDER BY a.attnum
        """
    private static let enumTypesSQL = """
        SELECT t.oid::text, ns.nspname::text, t.typname::text, e.oid::text, e.enumlabel::text,
               e.enumsortorder::text, pg_catalog.has_type_privilege(t.oid, 'USAGE')::text
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace ns ON ns.oid=t.typnamespace
        LEFT JOIN pg_catalog.pg_enum e ON e.enumtypid=t.oid
        WHERE t.typtype='e' AND t.oid IN (
            SELECT a.atttypid FROM pg_catalog.pg_attribute a WHERE a.attrelid=$1::oid AND a.attnum>0 AND NOT a.attisdropped
            UNION
            SELECT a.atttypid FROM pg_catalog.pg_constraint c
            JOIN pg_catalog.pg_attribute a ON a.attrelid=c.confrelid AND a.attnum=ANY(c.confkey)
            WHERE c.conrelid=$1::oid AND c.contype='f'
        ) ORDER BY t.oid, e.enumsortorder, e.oid
        """
    private static let foreignKeysSQL = """
        SELECT con.oid::text, con.conname::text, key.position::text, con.conkey[key.position]::text,
               target.oid::text, ns.nspname::text, target.relname::text, target.relkind::text,
               a.attnum::text, a.attname::text, a.atttypid::text,
               pg_catalog.has_schema_privilege(ns.oid, 'USAGE')::text,
               pg_catalog.has_column_privilege(target.oid, a.attnum, 'SELECT')::text,
               COALESCE(coll.collisdeterministic, true)::text,
               label.attname::text, label.attnum::text, con.confmatchtype::text, con.convalidated::text
        FROM pg_catalog.pg_constraint con
        CROSS JOIN LATERAL pg_catalog.generate_subscripts(con.conkey, 1) key(position)
        JOIN pg_catalog.pg_class target ON target.oid=con.confrelid
        JOIN pg_catalog.pg_namespace ns ON ns.oid=target.relnamespace
        JOIN pg_catalog.pg_attribute a ON a.attrelid=target.oid AND a.attnum=con.confkey[key.position]
        LEFT JOIN pg_catalog.pg_collation coll ON coll.oid=a.attcollation
        LEFT JOIN LATERAL (
            SELECT l.attname, l.attnum FROM pg_catalog.pg_attribute l
            WHERE l.attrelid=target.oid AND l.attnum>0 AND NOT l.attisdropped
              AND l.attname IN ('name', 'title') AND l.atttypid IN (25, 1042, 1043)
              AND pg_catalog.has_column_privilege(target.oid, l.attnum, 'SELECT')
            ORDER BY CASE l.attname WHEN 'name' THEN 0 ELSE 1 END, l.attnum LIMIT 1
        ) label ON true
        WHERE con.conrelid=$1::oid AND con.contype='f'
        ORDER BY con.oid, key.position
        """
}
private struct EditingQueryResponse: Sendable { let rows: [DatabaseRow]; let summary: QuerySummary }
private actor EditingRowCollector {
    let maximumRows: Int, maximumBytes: Int
    private(set) var rows: [DatabaseRow] = []
    private var bytes = 0
    init(maximumRows: Int, maximumBytes: Int) { self.maximumRows = maximumRows; self.maximumBytes = maximumBytes }
    func consume(_ event: QueryEvent) throws {
        guard case .rows(let batch) = event else { return }
        guard rows.count + batch.rows.count <= maximumRows, bytes + batch.byteCount <= maximumBytes else { throw DatabaseError("The editing response exceeds its bounded row or memory limit.") }
        rows += batch.rows; bytes += batch.byteCount
    }
}
