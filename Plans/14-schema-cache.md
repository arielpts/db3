# 14 — Schema cache and automatic introspection

**Status:** planned; no implementation in this task.
**Planning date:** 2026-09-29.
**Depends on:** [05 — Objects](05-objects.md) and the transaction ownership in [06 — Editing](06-edit.md).
**Coordinates with:** [07 — Projects](07-projects.md), [08 — Odoo](08-odoo-json-rpc.md), [09 — Grid mode](09-grid-mode.md), and [11 — Terminal](11-terminal.md).

## Outcome

Show cached database structure immediately and refresh the affected metadata automatically after changes, without re-introspecting the entire database after every query. Cover connections with and without a project. Preserve the selected schema, search, namespace group, and object selection while refreshing.

Treat **DML** and **DDL** separately. INSERT/UPDATE/DELETE/MERGE normally change rows; CREATE/ALTER/DROP change structure. Ordinary DML invalidates relevant data-derived state, while DDL invalidates schema metadata. DML against a registered application-metadata table can also invalidate its metadata provider. Functions, triggers, and procedures can hide additional effects, so local classification is an optimization with periodic reconciliation, not proof that the schema is unchanged.

The default implementation requires ordinary catalog access and creates no database objects. External changes are eventually detected for actively used metadata; immediate detection across other clients is an optional later mode. Automatic schema refresh never reruns arbitrary worksheet SQL, commits a transaction, replaces a result set, or discards an edit draft.

## Existing implementation to extend

- `ObjectBrowserModel` already owns `ObjectCatalogCache`: up to 32 query entries, 5,000 objects, and 8 MiB in total, with stale restoration and 200 ms search debounce. Its key includes source, schema, search, kind, and project namespace membership. Extract and extend this ownership rather than creating a competing browser cache.
- `PostgresCatalogService` already provides one separately owned catalog session, 500-row keyset pages, source/database checks, cancellation recovery, and 10-second deadlines. It observes committed metadata independently of the four worksheet sessions.
- `CatalogSource.revision` and `DatabaseObjectID.generation` fence live sessions. They are not durable server schema versions. The catalog generation currently changes on reconnect, not after every DDL statement.
- `QuerySummary` supplies the actual command tag and server transaction state. `ManagedSession` owns operation leases and transaction boundaries; `Worksheet.run` and `WorksheetEditing.applyPreview` are logical mutation integration points. Apply executes internal SQL through an exclusive operation, so observing `ManagedSession.run` alone misses grid writes.
- `PostgresTableEditing` already reads live relation metadata and validates an edit fingerprint before Apply. `ProjectMetadataProvider` adds independently revisioned source metadata. Keep both checks authoritative.

## Cache contents and identity

Use an actor-owned `SchemaMetadataCache` with separately revisioned layers:

| Layer | Contents | Refresh scope |
| --- | --- | --- |
| Object directory | Schemas and paged relation names, kinds, advisory access flags, and identity evidence. | Current filtered listing or affected schema. |
| Relation structure | Ordered columns, types/typmods, nullability, default/generated/identity properties, keys, constraints, FK targets, relevant indexes, and enum choices. | Requested relation OIDs and known dependencies. |
| Application annotations | Project/source choices, computed-field warnings, grouping, and provider provenance. | Provider revision plus affected live relations. |
| Data-derived state | FK candidate pages and any future counts/statistics. | Changed data relations; kept separate from structural metadata. |

Only load detail fields required by an existing consumer; this task does not add a general schema designer, function browser, or eager inspection of every index and routine. Keep result rows and FK candidate values out of persistent schema storage.

Live keys include profile UUID, endpoint/authentication/transport revision, connected database identity, catalog connection generation, authenticated/effective role context, and relation OID. Query-list keys also retain schema/search/kind/namespace filter. Worksheet-local keys additionally include physical session identity, transaction epoch, and session settings revision. `SET ROLE`, `SET SESSION AUTHORIZATION`, and `search_path` changes invalidate the affected local resolution/capability context; they do not modify the independent browser connection.

Maintain a separate monotonically advancing invalidation revision per source/scope. Each request captures it; a result started before a newer invalidation cannot mark that scope fresh or append to its new listing. Keep database structure and project annotations separately keyed, and retain unresolved/computed-field cautions when a refresh cannot verify their source metadata.

Names alone, OIDs alone, database names, and server version strings cannot establish identity across reconnects or replacements. Treat `pg_class.xmin` only as existing short-lived identity evidence; it is not a complete schema fingerprint. Fingerprint the specific semantic catalog fields actually consumed, including dependent types, enum order, keys, defaults, and privileges. Exclude changing row estimates and maintenance statistics. PostgreSQL's `xmin` describes a row version, and `pg_class` also contains planner estimates updated by maintenance. [System columns](https://www.postgresql.org/docs/17/ddl-system-columns.html), [pg_class](https://www.postgresql.org/docs/17/catalog-pg-class.html).

Do not infer a database-wide schema version from `max(xmin)`, transaction IDs, `relfilenode`, `reltuples`, object count, or `n_mod_since_analyze`. For example, column/type changes need not change a relation's directory entry, and rename/drop/create can leave counts unchanged. Modification statistics are estimates of data activity, not schema-change records. [PostgreSQL statistics](https://www.postgresql.org/docs/17/monitoring-stats.html).

### Persistent warm start

Persist a versioned, disposable metadata DTO in the user's private Caches directory, separate from workspace recovery and `.db3/project.json`. Start with a 32 MiB app-wide disk limit, 8 MiB per source, seven-day expiry, bounded decoding, atomic replacement, and file/directory permissions of 0600/0700. Reject symlinks and malformed/newer formats, evict by recency, and fall back to a live load if a cache is unavailable. Add **Clear Schema Cache** without deleting connection profiles or project settings.

Store names, structural display fields, timestamps, completeness, and a nonsecret profile/configuration digest. Do not serialize `ConnectionProfile` wholesale, passwords, connection URLs containing credentials, SQL history, rows, FK results, source contents, comments, or default-expression text. A disk snapshot can retain that a default exists; full expressions remain live metadata. Never restore permission flags as execution authority.

Restored entries are visibly **Cached — not verified**, with actions requiring live identity disabled. Do not reconnect merely because the app restored a workspace. Once the user loads that connection, authenticate normally, establish a fresh generation, and revalidate the requested scope before enabling its actions. Persisted relation OIDs are hints to re-resolve, never durable execution targets. A matching disk key does not prove the database behind an endpoint is unchanged.

## Change detection and invalidation

Emit typed `DatabaseChangeHint` events carrying source/session identity, transaction epoch, scope, outcome, and certainty. Hints contain IDs and categories, not retained SQL or parameter values. Internal catalog queries, savepoints, and introspection must not recursively generate user-change events.

Use the submitted statement's bounded PostgreSQL-aware classification together with its successful server command tag and final transaction state. App-generated edit plans supply exact target identities. The existing leading-keyword transaction classifier is insufficient for target discovery: handle comments, quoted/dotted names, WITH/data-modifying CTEs, SELECT INTO, and EXPLAIN ANALYZE; treat dynamic or unsupported forms as uncertain. A final SELECT tag does not prove that no writes occurred. Never execute EXPLAIN or the user's statement again to classify it.

| Observed operation | Invalidation and work |
| --- | --- |
| Ordinary INSERT/UPDATE/DELETE/MERGE, including grid Apply | Mark relevant FK candidate/data caches stale. **Zero immediate schema-introspection queries solely because rows changed.** Retain normal periodic structural checks for hidden trigger effects. |
| DML on an explicitly registered metadata dependency | Invalidate that provider's annotations/choices, and structural metadata only if the provider declares that dependency. Batch refresh after commit. |
| CREATE/ALTER/DROP, SELECT INTO, supported ownership/comment/privilege changes | Invalidate affected objects plus known dependants and affected directory pages. Refresh current consumers after the correct transaction boundary. |
| ALTER TYPE / enum changes, shared FK/index dependencies | Invalidate cached relations referencing the changed type/key; reload demanded details in batches. If the dependency map is incomplete, widen the stale scope. |
| TRUNCATE, REFRESH MATERIALIZED VIEW, ANALYZE/VACUUM | Invalidate relevant data/statistics/population state; do not rebuild every column definition. |
| CALL, DO, unresolvable targets, dynamic SQL, or uncertain side effects | Mark a conservative schema/database scope suspect; schedule bounded revalidation of active consumers. Do not guess an OID from an unqualified name. |
| Structural/access error such as missing relation/column, changed result type, or revoked privilege | Invalidate matching metadata, preserve drafts/results, and offer or schedule metadata refresh. Never retry the failed user statement automatically. |
| Manual Refresh, reconnect, or expired active metadata | Revalidate the requested scope. Manual Refresh bypasses freshness and cooldown, but keeps limits and transaction isolation. |

Ordinary data changes can affect trigger-modified tables and arbitrary function side effects. If the affected data set cannot be proven, invalidate the bounded data-derived cache for that source rather than assuming only the directly named table changed. Existing fetched results remain snapshots; show **Data may have changed** where relevant instead of silently executing another SELECT.

Provider dependency registration is typed and source-bound. For example, a future task 08 runtime Odoo provider could declare `ir_model`, `ir_model_fields`, and selection metadata as dependencies after verifying their schema/identity. This task does not query those tables merely because a project looks like Odoo. Task 07's current filesystem inspector continues using its file watcher and source digest; SQL DML alone does not rescan the whole project.

## Transaction boundaries

Accumulate pending invalidation scopes per physical worksheet session and transaction epoch. Separate **metadata visible inside this transaction** from **committed metadata shared by the browser**.

1. After successful DDL or registered metadata-changing DML in any open transaction, invalidate that worksheet's affected local metadata immediately. This includes explicit BEGIN while Development Auto mode is selected. Any required re-introspection uses its idle pinned session under the existing exclusive lease and error/savepoint recovery rules. Never borrow a busy or failed session. The browser may show **Schema changes pending commit** but must not present those changes as committed.
2. A confirmed COMMIT publishes the accumulated scope and schedules a fresh read through the catalog owner. Do not copy a worksheet snapshot directly into the committed cache. Successfully auto-committed operations publish at completion only when server state confirms that boundary; the mode selector alone is insufficient. Grid Apply inside an existing transaction does not publish shared changes until that transaction commits.
3. Full ROLLBACK discards that transaction's pending shared hints and invalidates its local overlay. `ROLLBACK TO SAVEPOINT` must not clear changes made before the savepoint: either track a tested savepoint journal or conservatively retain pending scopes until the final boundary. Conservative extra refresh is acceptable. RELEASE SAVEPOINT is not a commit.
4. Handle COMMIT AND CHAIN/ROLLBACK AND CHAIN as a boundary plus a new epoch. A COMMIT command returning ROLLBACK is not a successful commit. Failed transactions retain pending scope until resolved. Connection loss or unknown commit outcome marks metadata suspect and reconciles after reconnection; it never replays writes or claims that a change committed.
5. A catalog refresh cannot make an old worksheet snapshot or preview valid again. Preserve values and drafts, invalidate affected preview capabilities, and require the existing deliberate reload/rebase path. Revalidate live schema, privileges, provider revisions, and edit fingerprints inside Apply even when the display cache is fresh.

Temporary objects and session-local role/search-path state stay worksheet-local and memory-only. The shared sidebar retains task 05's committed, nontemporary scope. Respect repeatable-read snapshots; do not end or alter user transactions to obtain newer metadata.

## Efficient refresh scheduler

Use one app-wide coordinator and the existing catalog connection admission limit. Default mode opens no listener and no per-table/background-profile connections. Hidden/disconnected profiles only accumulate bounded stale markers; navigation revalidates them through the ordinary connection flow. Suspend automatic I/O while the app is inactive, asleep, cancelled, or waiting for credentials/trust.

- Coalesce hints for approximately **300 ms**, with a **2-second maximum delay** for a continuous burst when the session is available. Deduplicate by source and scope, merge relation IDs, and promote oversized sets to one schema/database stale marker. Maintain at most one running job and one merged successor, with a 1,024-ID dirty-set cap. Do not cancel/restart an executing query for every new hint.
- Prioritize explicit Refresh and visible consumers, then demanded relation details. An invalidated inactive entry is cheap to mark; re-introspect it only on demand. Reuse one in-flight request for matching consumers and never let cancelling one consumer cancel an unrelated worksheet query.
- Keep current 500-object pages, 5,000 cached directory objects, 32 list entries, and the 8 MiB directory budget. Add a separate **8 MiB app-wide detail budget**, capped at 256 relations with a 512 KiB decoded per-relation cache limit. Count dependency edges, strings, in-flight cache buffers, and duplicate representations. Oversized metadata bypasses caching under the existing bounded live-read/editing limits; this new cache limit must not remove support for existing larger enum vocabularies. If a live-read limit is also exceeded, retain the existing partial/unavailable explanation.
- Batch details for at most **32 requested relation OIDs** using bound OID arrays and fixed catalog queries, rather than one round trip per column or table. Aim for at most six catalog round trips per detail batch, with byte/row caps. Fetch privileges in the requesting context. Use one SQL statement or a short `REPEATABLE READ READ ONLY` transaction on the independent catalog session so multi-query detail reads share a snapshot; read-only mode alone does not provide that consistency. Close it before idle time and never hold a catalog snapshot across UI pagination. Do not change a worksheet's isolation level for a cache read.
- Compare canonical semantic fingerprints and publish only changed structures. Cache dependent enum/type definitions once per valid scope. When only annotations change, rebuild that overlay without fetching unrelated catalog detail. Retain Task 06's live Apply validation even when it duplicates a recent display read.
- Keep the 10-second hard query deadline; use a short lock timeout for background probes and release/recover the catalog session after cancellation. Back off repeated failures (5/15/60 seconds with jitter), preserve stale content, and stop retries requiring user credentials. Only explicit retry/load resumes a user-cancelled scope.

The isolation choice above follows PostgreSQL's distinction between Read Committed statement snapshots and Repeatable Read transaction snapshots. [Transaction isolation](https://www.postgresql.org/docs/17/transaction-iso.html).

### Changes made outside db3

Default to **60-second soft freshness** for actively consumed directory pages and relation details, with jitter and one shared scheduler. A foreground/navigation check refreshes expired metadata; an already visible view checks while the app is active. Unchanged cached metadata is served immediately within that window. After sleep or reconnection, invalidate freshness and reconcile the active scope once, rather than replaying missed timer ticks.

Check bounded visible listing pages and hot relation fingerprints; never fetch the whole schema or compute a database-wide hash every minute. Invalidate continuation pages when refreshing a listing generation so old and new keyset pages cannot masquerade as one complete snapshot. New objects outside the current loaded/filter scope are discovered on navigation or server search. Partial results remain explicitly partial, and server search must still reach beyond cached rows.

This is eventual freshness under ordinary permissions, not guaranteed immediate detection of all external changes. Show **Last checked** and stale/refreshing/offline states. Performance budgets can delay reconciliation on a huge catalog; report this rather than claiming a hard 60-second consistency guarantee. Changes made by Claude Code, Codex CLI, psql, migrations, or other tools use this same external-change path. Do not scrape terminal text as evidence that DDL succeeded or committed.

## Optional server notifications — later phase

Defer push notifications until the cache, transaction events, and polling path are complete. Offer a reviewed, explicitly installed administrator integration for supported DDL event triggers (`ddl_command_end` and `sql_drop`) to emit a small invalidation hint. PostgreSQL requires superuser privileges to create event triggers, and they do not cover shared objects such as roles/databases/tablespaces; retain fallback checks for permissions and unsupported operations. No automatic installation or superuser requirement for normal db3 use. [Event-trigger behavior](https://www.postgresql.org/docs/17/event-trigger-definition.html), [CREATE EVENT TRIGGER](https://www.postgresql.org/docs/17/sql-createeventtrigger.html).

`LISTEN/NOTIFY` needs an installed sender; LISTEN alone does not discover schema changes. Notifications are delivered at transaction completion, can fold duplicate payloads, and are hints to re-read catalogs. Keep payloads bounded to IDs/categories and never include SQL or row values; notifications are visible to database users. Avoid a global counter row that serializes concurrent DDL. Do not add per-row triggers to every application table. [NOTIFY](https://www.postgresql.org/docs/17/sql-notify.html).

If enabled, permit at most **one additional listener connection app-wide**, tied to the actively browsed source and subject to the existing TLS/SSH/session lifecycle. Add idle socket notification draining to the driver; `QueryEvent` currently has no notification path. Commit LISTEN first, then establish a fresh catalog baseline, then reconcile hints. Disconnect/reconnect always triggers a fresh check because notifications are not a durable replay log. Leave the listener out of long transactions and close it on source switch, inactivity timeout, or shutdown. [LISTEN setup race](https://www.postgresql.org/docs/17/sql-listen.html), [libpq notifications](https://www.postgresql.org/docs/17/libpq-notify.html).

## Delivery and acceptance

1. Extract the bounded cache, add structural/detail keys and freshness states, and implement disposable disk snapshots with current browser behavior preserved.
2. Add typed mutation outcomes and transaction-scoped invalidation for worksheet SQL and grid Apply, including provider dependency hooks and source/session fences.
3. Implement batched introspection, dependency invalidation, merged scheduling, periodic active-scope reconciliation, and native freshness/cache controls.
4. Integrate project annotations, editor metadata, and task 09 grid consumers without weakening live write checks. Measure on disposable large catalogs and write the benchmark record.
5. Evaluate the optional administrator notification integration separately; the first delivery ships without it.

Acceptance uses synthetic fixtures and disposable PostgreSQL databases:

- [ ] Warm navigation serves an unchanged in-memory entry with **zero catalog round trips** inside its freshness window. Cold/disk-restored content is labelled unverified and cannot supply stale execution targets.
- [ ] A burst of 1,000 ordinary row writes schedules **zero schema scans caused by those DML hints**; data-derived invalidation is bounded. A burst of committed DDL coalesces to one active-scope batch plus at most one merged successor while it runs.
- [ ] Local CREATE/ALTER/DROP, enum/default/key/FK changes, rename/schema moves, permissions, drop/recreate, quoted identifiers, writable CTEs, SELECT INTO, procedures, and uncertain targets refresh or conservatively invalidate the correct scope.
- [ ] External column changes are detected even when `pg_class` identity/count is unchanged. No-change checks publish no structural revision. Dependency changes invalidate affected cached consumers without assuming a complete dependency graph.
- [ ] Manual DDL remains local until commit; full rollback, rollback-to-savepoint, failed statements, chained boundaries, COMMIT returning ROLLBACK, Apply savepoint recovery, and lost commit acknowledgements never publish false committed snapshots.
- [ ] Profile/credential/role changes, equal OIDs on different sources, database replacement, reconnects, project switches, and late callbacks cannot mix metadata. `SET ROLE`, temporary relations, and search-path changes do not leak into the shared browser.
- [ ] Refresh preserves drafts and fetched results; outdated previews cannot Apply. Revoked privileges, changed enums/defaults, and source/provider revisions still fail the existing live validation even with a warm cache.
- [ ] Empty and partial results remain distinguishable from failure. Search reaches objects beyond the cache; listing refresh resets continuations safely. Disk corruption, oversized input, expiry, permission failure, and eviction fall back without losing user work.
- [ ] Cancel/sleep/foreground/hidden-browser behavior, merged requests, timeouts, reconnect recovery, and source switching respect one default catalog owner and leave worksheet sessions untouched.
- [ ] Benchmark 50,000 directory objects, a wide relation, 32 simultaneous detail demands, unchanged warm navigation, and migration bursts. Record round trips, bytes, cache hit rate, peak memory, and refresh latency without logging SQL, values, or credentials. Initial warm-cache publication target: under 50 ms on the measured machine; document results rather than claiming unmeasured UI performance.
- [ ] Package/app integration checks and Release bundle verification pass. Native freshness labels, retained selection, accessibility, and cancellation get separate interactive acceptance under the applicable computer-control rules.

Runtime implementation, database trigger installation, automatic user-data refresh, and full database crawling are not performed by this planning task.
