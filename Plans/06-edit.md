# 06 — Inline editing, SQL preview, and manual transactions

**Status:** implemented for direct PostgreSQL connections; automated verification recorded below. Interactive native acceptance remains pending.
**Planning date:** 2026-09-29.
**Scope:** PostgreSQL row updates and explicit-table row inserts, native inline value editors, searchable foreign-key lookups, generated-query previews, and auto-commit **off** by default. Development connections may opt in; production connections never auto-commit.
**Coordinates with:** [04 — Query tabs](04-tabs.md), [05 — Objects](05-objects.md), [07 — Projects](07-projects.md), and [08 — Odoo JSON-RPC edits](08-odoo-json-rpc.md). Enum/selection pickers and project metadata belong to task 07; Odoo is its first adapter, not its only supported project type.

## Implemented behavior

Query results allow inline editing when a conservative SQL check proves one base-table source and the result includes its complete primary key. Aliases, reordered/subset columns, duplicate aliases, WHERE/ORDER BY/LIMIT, and read-only calculated expressions retain their original result shape. Before the first edit, db3 revalidates the displayed base values and obtains the current full row and `xmin` on the worksheet session. Joins, CTEs, grouped/set queries, views, and incomplete keys remain read-only. **Edit Table Data** in Objects remains a convenient way to prepare a bounded full-table query, whose hidden `xmin` is fetched in the original result snapshot.

Double-click a cell or press Return/F2 to open the native editor. Return/Tab stages a scalar value, Escape cancels, and multiline text uses Command-Return to stage. Boolean choices, explicit NULL, draft markers, isolated grid undo/redo, **Preview Changes**, before/after values, actual SQL and bound parameters, and searchable composite FK selection are implemented. Preview search does not change the Apply batch. Existing generated/identity/key values and unsupported types explain their read-only state. Framework-computed metadata has a provider seam, acknowledgement warning, marker, and preview warning; discovering framework metadata remains task 07.

An explicit **Edit Table Data** result has a trailing blank row marked **+**, including for an empty table. Double-click that row or use Return/F2 to create a local insert draft and edit an eligible field. Untouched fields use database **DEFAULT**; explicit **Set NULL**, empty text, and entered values remain distinct. **Use Default** returns a field to its omitted state. Generated and identity columns stay database-supplied, while writable columns can include a manually assigned primary key. New rows appear in the existing **Preview Changes** sheet and are inserted only by **Apply**, under the same batch and transaction rules as updates. Ordinary SELECT editing and read-only browsing do not acquire an insertion row.

All connections start in Manual mode, including restored and reconnected tabs. Manual Run starts a transaction lazily, including for SELECT. Production and unclassified environments cannot enable Auto mode. Connection properties classify the environment; restrictions tighten synchronously when a saved profile changes, including while authentication or Apply is pending. Explicit transaction commands preserve results, and commit uncertainty is reported without replay. Commit/Rollback require local drafts to be resolved and invalidate the editable snapshot until an explicit Run.

When explicit **Edit Table Data** starts a new manual transaction, it requests `BEGIN READ WRITE`. Apply also checks the server's effective transaction access before sending changes. An existing read-only transaction stays unchanged; the error preserves drafts and explains how to discard them, roll back, and reload, or connect to a writable primary when the server is a replica.

Apply holds the worksheet operation lease, revalidates the schema, locks the relation against DDL, protects the full batch with a savepoint, verifies every RETURNING row, and prepares a bounded replacement result store before releasing the savepoint or committing. Errors, conflicts, cancellation, and provisional-storage failure roll back the whole batch while retaining earlier user work. Conflict review compares original/draft/current values and offers deliberate rebase with a new preview. Drafts and lookup values are memory-only; quitting warns about them separately from preserved SQL documents and uncommitted transactions.

The app-wide edit budget covers drafts, originals, undo deltas, previews, active native editor reservations, provisional returned rows, and retained conflict comparisons. FK search uses 50+1 rows per page and caps the picker at 500 candidates / 2 MiB. Canceled searches drain and recover before the worksheet releases their operation lease. Result exports omit the hidden version token and require resolving local drafts first.

## Outcome and first delivery

[09 — Grid mode](09-grid-mode.md) adds automatic, read-only object browsing on double-click. Its short internal browse transactions are separate from this task's editable snapshots and Manual-mode user transactions; opening a grid does not enable editing or commit existing work.

Edit a value or stage a new row in the results grid, review the exact SQL and parameters db3 will send, apply the changes to the worksheet's transaction, and explicitly commit or roll back. Creating a row or finishing a cell edit only changes a local draft. It never sends an INSERT or UPDATE, or commits a transaction.

This is the **SQL editing mode** for PostgreSQL connections/tabs. Task 08 adds a separate **Odoo connection type**, optionally linked to a PostgreSQL profile for direct SQL access. Its ORM data tabs have their own operation previews and explicit commit boundary; attaching a project or an Odoo endpoint never silently reroutes a SQL UPDATE through RPC. A project framework, connection protocol, and tab editing mode are distinct concepts.

The delivery updates existing rows of ordinary PostgreSQL tables with a usable primary key and inserts new rows from explicit **Edit Table Data** results. Deletes, changes to existing primary keys, bulk paste, arbitrary SQL expressions as cell values, and editing views/materialized views/foreign tables/partitioned or inheritance hierarchies are later work. A read-only cell explains its reason and remains selectable/copyable.

[10 — Multi-row copy and paste](10-copy-paste.md) builds on this editing contract with range/row selection, spreadsheet clipboard interchange, and one undoable draft batch per paste. It reuses these previews, row identities, field warnings, and transaction rules; task 06's initial inline editor does not acquire bulk paste implicitly.

Task 05 gains **Edit Table Data** for eligible tables. This prepares a new task 04 tab with an app-owned, bounded SELECT and automatically connects it to the object's captured source; the user explicitly runs it. Its snapshot includes the complete primary key and a hidden row-version token alongside displayed columns. Ordinary **New SELECT Query** and hand-written single-table SELECT results are also editable when all primary-key columns are projected directly. Result-column provenance alone does not prove a join or expression safely maps to one row: a conservative PostgreSQL lexer first rejects ambiguous query structures, then catalog/provenance checks map each visible column to its physical attribute. **Open Base Table for Editing** remains available for read-only queries with clear base-table provenance. No path rewrites or silently reruns the user's original SQL.

## Existing code and required changes

| Location | Current behavior | Required change |
| --- | --- | --- |
| `DB3Core/DatabaseTypes.swift` | Columns contain name/type OID; `.idle` is labeled “Auto commit” | Separate commit mode from server transaction state; add source-column identity, capabilities, parameters, and edit states. |
| `DB3Postgres/PostgresSession.swift` | Async `PQsendQueryParams` with zero parameters; one operation at a time | Bound typed parameters, catalog metadata, exact command results, and exclusive multi-command edit operations. |
| `App/DB3App/Worksheet.swift` | Every `run` replaces results; BEGIN/COMMIT/ROLLBACK use that same path | Dedicated transaction/apply APIs that preserve the grid and coordinate drafts, results, and transaction epochs. |
| `DB3Grid/ResultsGrid.swift` | Read-only virtualized cells and bounded previews | One active native cell editor, draft overlays, edit callbacks, and relation-picker presentation. |
| `DB3Results/ResultStore.swift` | Paged immutable fetched rows | Keep the original snapshot; overlay only changed rows and invalidate/reload affected pages after confirmed server changes. |
| `WorkbenchView.swift`, `DB3App.swift`, `WorkbenchModel.swift` | Transaction menus and close guards | Persistent Manual/Auto mode, Preview Changes, Apply, Commit, Rollback, and draft-aware close handling. |

Extend task 05's parameter and catalog models instead of introducing a second database adapter. Each tab keeps its pinned physical session, operation identity, and result-store ownership.

## Transaction behavior

Commit mode, connection environment, and backend state are independent. A connected idle session can be in **Manual mode** without an open transaction. Replace the current `.idle → “Auto commit”` label with separate mode/status labels. Carry `development`, `production`, or `unknown` environment through the immutable connection/session context, including project-discovered profiles from task 07.

**Production always uses Manual mode.** Disable Auto mode in the UI and enforce the same rule in the operation coordinator; stale menu actions, saved preferences, project refreshes, reconnects, and generic Apply APIs cannot bypass it. Unknown/unclassified connections also remain Manual until explicitly identified as development. Do not infer development from `localhost`, which can be a tunnel to production. Production still supports an explicit user Commit after review; it never gets an automatic Apply & Commit path.

| Situation | Behavior |
| --- | --- |
| New tab, new connection, or reconnect | Manual mode; auto-commit off. Opening a tab or connection does not issue BEGIN. |
| Run an ordinary statement in Manual mode while idle | Issue BEGIN, then the statement on the same session under one exclusive operation. This includes SELECT; db3 must not guess whether a function or CTE writes. |
| Run while a healthy transaction is open | Use that transaction. Never begin another one or change its isolation level implicitly. |
| Apply generated grid changes in Manual mode | Begin if necessary, protect the apply batch with a savepoint, execute it, and leave the transaction open. |
| Commit | Commit the entire worksheet transaction, including SQL run before or after grid edits. Local drafts must first be reviewed/applied or discarded. |
| Rollback | Roll back the entire worksheet transaction; invalidate affected displayed data. Resolve local drafts explicitly rather than silently losing them. |
| Failed transaction | Disable Apply and ordinary Run until recovery or explicit Rollback; show the server state. |
| User enables Auto mode | Available only for a connection classified as development, as an explicit per-tab choice. Resolve an existing transaction and drafts first; toggling cannot silently commit them. Other/new tabs remain Manual. |
| Apply generated changes in development Auto mode | Still stage and preview. **Apply & Commit** runs one atomic transaction for the entire batch and commits only after validation succeeds. |

Explicit transaction-control SQL must use the same coordinator and update the UI from the server's response. Recognize top-level controls with PostgreSQL-aware tokenization/parsing, including comments and quoted text; never classify statements by substring or split scripts on semicolons. Keep one statement per driver execution. Transactions requiring unsupported coordination, such as two-phase commit, remain outside the managed editor contract.

Commands PostgreSQL forbids inside a transaction must fail clearly in Manual mode. A development connection can deliberately switch mode and rerun; production cannot bypass the policy through this fallback. db3 never retries a failed command outside the transaction automatically. Display transaction age and unfinished-work state, but never commit on a timer, tab switch, navigation, or app backgrounding. PostgreSQL transaction and savepoint semantics are the foundation; the default mode and lazy BEGIN policy above are db3 decisions. [Transactions](https://www.postgresql.org/docs/17/tutorial-transactions.html), [SAVEPOINT](https://www.postgresql.org/docs/17/sql-savepoint.html).

## Native inline editor

- Double-click a **cell**, or use Return/F2 on the focused editable cell, to edit. Double-clicking a **header divider** retains the existing column auto-fit action.
- In explicit **Edit Table Data** mode, double-click the trailing blank row or its **+** gutter to stage an insert. Finish any active editor first; a validation error keeps that editor open and prevents the new draft. Synthetic draft rows use the local overlay without reading or inspecting nonexistent result-store rows.
- Use a reusable AppKit field editor for short scalar values; a native popover/sheet with a multiline editor handles larger text/JSON. Boolean values use a native choice control. Keep one active editor per tab, with keyboard navigation, selection, IME composition, and VoiceOver labels.
- Enter/Tab validates and stages the value; Escape cancels the current edit. Leaving a cell never applies SQL. Show changed-cell markers and a pending-change count using text/icons as well as color.
- Provide an explicit **Set NULL** action only when permitted. SQL NULL, empty text, the text `NULL`, boolean false, zero, and an untouched value are distinct. An empty editor must not silently become NULL.
- Insert fields begin as **DEFAULT**, separate from NULL or empty text. An untouched editor preserves that default; **Use Default** restores it after entering a value. Database-generated and identity fields are omitted from the insert, and required writable fields must be supplied before preview.
- Preserve exact numeric/decimal text rather than passing through `Double`. Validate integer ranges, text encoding, and supported date/time syntax off the main actor; preserve timestamp/time-zone and precision semantics. PostgreSQL remains authoritative for constraints and domain checks.
- Load the complete stored value asynchronously before editing; truncated grid previews are never editable source data. If the full value exceeds the edit budget or cannot be loaded, retain inspection/copy behavior and explain why editing is unavailable.
- Generated columns, identity columns, existing primary-key values, expressions, and unsupported types remain read-only in this slice. A new row may supply a writable primary key. Enum-specific pickers and application-defined selections are deferred to task 07; task 06 exposes a typed editor-provider interface for them.
- Grid undo/redo changes local drafts and is isolated from the SQL editor's undo history. Undo after Apply must not pretend the server update was undone; use Rollback or stage a new reviewed change.
- Repeated edits to a row coalesce against its original baseline. Restoring every edited value removes that row's draft. A lookup that changes several FK components forms one undo step.

### Computed-field warning

Task 07's adapter-neutral metadata can identify a field computed or derived by an ORM. A **stored, database-writable ORM-computed field** shows a warning before its first edit: **“This value is computed by the application. A direct database edit will not run its computation or update dependent values.”** Show the model/field and source of that classification, with **Cancel** and **Edit stored value**. Keep a computed marker in the grid and repeat the warning in the change preview. Acknowledgement is scoped to the field and metadata revision; changed definitions invalidate it.

This warning does not unlock PostgreSQL generated columns, nonstored computed fields, or otherwise ineligible columns. Distinguish stored related/inverse-backed fields as derived values with the same direct-SQL warning when the adapter can identify them. Unknown/ambiguous source metadata is visibly unresolved, not a claim that a field is ordinary. **Recalculate through ORM** is a much later feature: no compute method, inverse, onchange, application constraint, or application cache update runs as part of this SQL-editing plan. SQL permissions, transaction policy, preview, and conflict checks still apply after acknowledgement. Task 08 defines a separate, explicit ORM write mode; it must not silently replace SQL execution or imply a recalculation action already exists.

## Row identity and conflict detection

Resolve relation OID, schema/name, physical attribute numbers, types/type modifiers, nullability, generated flags, primary-key components, update permissions, and FK definitions from PostgreSQL. Quote schema/table/column identifiers separately; aliases and displayed labels are never identifiers. `PQftable` and `PQftablecol` supply column provenance, but eligibility also requires a proven single-table query and matching catalog context. Self-joins can expose identical relation/attribute OIDs for different aliases and must be rejected. [libpq result metadata and parameters](https://www.postgresql.org/docs/17/libpq-exec.html).

Use an ordinary table's full primary key, including composite keys. Do not identify rows by visible row number, display label, guessed `id`, or `ctid`. The app-owned editable SELECT obtains `xmin` with the displayed row in the **same snapshot**, with a collision-free hidden metadata channel. A normal query without hidden metadata establishes its baseline at first edit: one parameterized SELECT must match its full key and every displayed base-column original, returning exactly one full row plus `xmin`. Unsupported read-only columns participate through exact textual comparison; calculated expressions remain read-only. This later token is the verified **current** baseline, not proof of the original query version: a change-and-change-back or identical delete/reinsert before the first edit cannot be detected. Later Apply checks the captured version and original edited values. Treat tokens as short-lived session data, never durable identifiers or cross-reconnect bookmarks. [PostgreSQL system columns](https://www.postgresql.org/docs/17/ddl-system-columns.html).

Canonical table rows remain separate from displayed projections. RETURNING and conflict rebase update every displayed base-column alias while preserving column order and expression values; calculated values are marked for explicit rerun after changes. Only app-owned results have trailing hidden metadata, so normal-query CSV exports keep every visible column. Repeated result rows sharing a key cannot stage separate conflicting drafts; confirmed changes refresh every occurrence of that key.

Each update draft carries worksheet/session identity, result revision, transaction epoch, relation/attribute identity, original key/version, exact original edited values, and typed replacement values. A new query, reconnect, schema change, or untracked same-session SQL invalidates its baseline. Revalidation keeps the user's draft available for comparison; it never silently attaches it to another result row.

Generate one UPDATE per changed row. Match its original primary key and version; also compare original edited values with null-safe, type-correct predicates where supported, including repeated updates inside one transaction. Unsupported comparison semantics require a separately tested strategy before that type becomes editable. Require exactly one returned/affected target row. Zero means conflict, deletion, permission filtering, or trigger suppression; more than one is an invariant failure. Neither outcome permits automatic retry or widening the predicate.

Insert drafts have local identities until Apply returns their database key and version. Generate one parameterized INSERT per new row, omitting DEFAULT fields; use `DEFAULT VALUES` when every field is omitted. Validate required fields and insert capabilities before preview, then require exactly one complete RETURNING row. A rejected insert rolls back the whole Apply batch and preserves its local drafts. Confirmed returned rows join the fetched result; synthetic draft coordinates never identify existing database rows.

After a conflict, present original, draft, and freshly fetched values for the target row. The user can discard or deliberately rebase the draft and preview again. There is no unconditional “overwrite anyway” path in the first slice.

## Query preview and Apply

**Preview Changes** opens a native sheet with a changes table and a SQL pane. Show connection/database/environment, Manual/Auto mode, affected tables, row keys, before/after values, statement count, parameter types/values, and computed-field warnings. Search/filter within the preview is presentation-only and must not silently exclude hidden changes from Apply; the action states the full batch count.

The preview is an immutable `EditPlan` generated from a particular draft revision and source context. It is the same plan execution consumes. A later value, metadata, connection, or transaction change invalidates the preview and requires rebuilding it. Opening or copying the preview performs no writes, EXPLAIN ANALYZE, or trigger execution.

Illustrative parameterized UPDATE, using synthetic names:

```sql
UPDATE ONLY "public"."example_record"
SET "title" = $1::text, "owner_id" = $2::bigint
WHERE "id" = $3::bigint
  AND xmin = $4::xid
  AND "title" IS NOT DISTINCT FROM $5::text
  AND "owner_id" IS NOT DISTINCT FROM $6::bigint
RETURNING "id", "title", "owner_id", xmin::text;
```

Values travel as libpq parameters, including NULL, with explicit type handling. Never interpolate user text or convert a display label into executable SQL. The SQL pane and parameter panel expose the real command and values separately; copying them is explicit and does not log them. The actual RETURNING list includes the supported displayed columns needed to refresh the row, including server/trigger adjustments. A preview describes submitted commands, not every effect a trigger or function might cause. [UPDATE and RETURNING](https://www.postgresql.org/docs/17/sql-update.html).

Apply sequence:

1. Finish the active editor, validate limits/capabilities, capture the plan, and reserve the worksheet session for the entire operation. Actor isolation alone does not prevent interleaving across awaits.
2. Revalidate source/schema/transaction generations. Start BEGIN only if needed, then create a uniquely named internal SAVEPOINT.
3. Execute parameterized updates and inserts in the immutable plan's deterministic order, with bounded returned data, cancellation, and per-operation deadlines. Do not generate one enormous SQL script or hold every returned row in SwiftUI state.
4. Check every command result and returned row count. Merge server values into a provisional result overlay only after the whole apply batch succeeds.
5. Release the savepoint. Manual mode shows **Applied — not committed** and leaves the transaction open. Development Auto mode commits the batch and verifies completion before showing **Committed**. Recheck the environment policy before a possible automatic COMMIT.
6. On error, conflict, cancellation, quota failure, or malformed response, drain protocol work and roll back the whole batch to its savepoint. Earlier user work in an existing transaction survives. If db3 opened the transaction solely for this failed apply, roll it back completely. Preserve drafts for correction; mark them unverified if recovery fails.

A COMMIT failure, including deferred constraints, is not success. Inspect command tag and backend state: COMMIT in a failed transaction can finish as ROLLBACK. Losing the connection while awaiting a commit acknowledgement yields **Outcome unknown**; never reconnect and replay the batch. Confirmed rollback/commit invalidates relevant snapshots and refreshes through an explicit, bounded read. Export clearly distinguishes fetched data from local drafts; this slice exports the fetched/applied view only, with drafts resolved first.

## Searchable foreign-key lookups

An editable FK cell offers **Choose referenced row…** in a native popover, with a larger sheet when needed. The search field is focused immediately. Show the exact referenced key and a readable label; selecting a row stages the key value, not its label. Escape cancels; keyboard arrows/Return select. Nullable relationships have a separate **No value (NULL)** action.

- Derive the target relation and ordered local/referenced key columns from FK constraints, including references to eligible unique keys. A `_id` suffix does not prove a relationship. Match composite key positions correctly and stage the complete tuple atomically. If any component is read-only or participating constraints conflict, explain the restriction instead of partially updating the relationship. [PostgreSQL FK catalog metadata](https://www.postgresql.org/docs/17/catalog-pg-constraint.html).
- Choose only permitted stored label columns. A basic default can use a suitable `name`/`title` plus the key, with a per-relation column choice. Task 07 can supply a verified model label hint. Nonstored Odoo `display_name` is not automatically a SQL column or an executable formatting function.
- Search the server, including rows beyond the current page. Support exact-key search and case-insensitive literal text search on selected supported label columns. Escape `%`, `_`, and backslash as literal characters and bind all inputs. Duplicate labels remain distinguishable by key; keep database collation semantics explicit.
- Debounce about 200 ms; fetch 50 candidates plus one next-page indicator, with stable keyset pagination. Avoid full-table downloads and COUNT queries on each keypress. Bound labels/response bytes and cache at most 500 candidates/2 MiB per open lookup. Use a short cancellable deadline; an expensive search yields a useful timeout/narrow-search state rather than freezing the editor.
- Run lookup SELECTs through the worksheet's serialized owner so they see its uncommitted changes, role, and session context. They never run over an active query/apply operation. Internal reads do not themselves open a long-lived user transaction while idle. Within an existing transaction, protect lookup work with a savepoint and recover before reusing the session, so a cancelled search cannot poison unrelated edits.
- Fence replies by tab, source, result, editor, relation, and search generations. Closing/changing the editor or starting Apply cancels obsolete lookup work and waits for protocol recovery. A late result cannot edit a different cell.
- Respect PostgreSQL privileges/RLS and show unavailable/permission/empty/no-match/loading states distinctly. Existing FK values remain visible even when the referenced row cannot be listed. Selection is only a draft; PostgreSQL checks the FK again at Apply/Commit and may reject a concurrently deleted target.

## State, memory, and close behavior

Keep local draft state separate from applied-but-uncommitted server state and confirmed committed state. A small per-tab change coordinator owns these transitions and the exclusive operation lease. Manual SQL writes may affect more rows than the grid journal knows; transaction controls always state that they act on the **entire transaction**.

Task 04's close coordinator must include dirty cell editors, unapplied drafts, and applied transactions independently of unsaved SQL documents. Closing, rerunning, replacing results, changing connections, or quitting offers appropriate Apply/Preview, Discard Drafts, Commit, Rollback, or Cancel actions. Apply in Manual mode is not permission to commit. Tab switching preserves drafts/editor state and never changes transaction ownership. Rollback invalidates displayed applied values instead of presenting them as persisted.

Keep storage reads, catalog work, validation, encoding, plan generation, and SQL off the main actor. Reuse visible native cells and apply targeted row/cell updates without resizing animations. Initial limits: 1,000 changed rows, 1 MiB per editable value, and 8 MiB app-wide for accounted draft/original/undo/preview payloads; respect the driver's tighter per-command/batch limits. Reject an edit before exceeding limits and keep the existing draft intact. These are payload budgets, not a hard whole-process memory guarantee. Preview lists and FK results are virtualized and paged.

Draft values, parameters, keys, SQL previews, and FK result data are memory-only in this task. Do not place them in diagnostics, project configuration, autosave, or telemetry. Task 07's project file stores editor/grouping preferences, not database changes. Closing a worksheet releases its edit/lookup tasks, memory, and result handles.

## Delivery and verification

1. **Transaction foundation:** separate Manual/Auto mode, lazy BEGIN, exclusive operations, result-preserving transaction commands, and true server-state/command-tag handling.
2. **Editable snapshots:** source capabilities, primary-key/version metadata, app-owned Edit Table Data queries, exact-value loading, and a bounded draft/undo store.
3. **Inline UI and preview:** native scalar editors, NULL action, immutable parameterized EditPlan, before/after review, and draft-aware navigation/close.
4. **Apply and recovery:** savepoint batch semantics, conflicts, RETURNING overlays, explicit commit/rollback, cancellation, and outcome-unknown handling.
5. **FK search:** composite mappings, labels/keys, paged server search, transaction-safe cancellation, and task 07's metadata-provider seam.

Acceptance uses synthetic fixtures and disposable PostgreSQL instances, never project production credentials:

- [x] New/reconnected tabs default to Manual; SELECT and UPDATE open transactions when appropriate; editor blur and tab switch never write/commit. Mode changes resolve existing work explicitly.
- [x] Production and unknown environments reject Auto mode at both UI and coordinator boundaries, including stale callbacks/preferences and project refreshes. A production explicit Commit still works; only an explicitly classified development session can Apply & Commit.
- [x] BEGIN/COMMIT/ROLLBACK/Apply preserve the grid appropriately; explicit SQL controls, prohibited-in-transaction commands, failed transactions, deferred-constraint commit errors, and COMMIT-returning-ROLLBACK display correctly.
- [ ] Double-click a cell edits; double-click a divider still fits. Keyboard/IME/VoiceOver, NULL/empty text, Unicode, quotes, huge exact numerics, booleans, timestamps, and oversized values behave correctly.
- [x] Read-only reasons cover missing/composite keys, permissions, expressions/joins/views, generated/identity columns, schema changes, and unsupported comparison/type handling.
- [x] Preview SQL/parameters equal the executed plan. Editing after preview invalidates it; SQL-looking values remain parameters. Hidden preview filtering does not change batch scope.
- [x] Stored ORM-computed/derived fields warn before editing and in preview; acknowledgement does not authorize an otherwise read-only column. Native generated/nonstored fields stay read-only, and no ORM recalculation runs. Metadata changes invalidate prior acknowledgements/previews.
- [x] Two sessions updating/deleting a row cause a conflict without lost edits; repeated same-transaction edits, triggers, RLS, and zero/multiple RETURNING rows exercise the full batch rollback path.
- [x] Cancel/error midway through a batch restores all its database changes while preserving earlier transaction work and local drafts. Reconnect, close, stale callbacks, and uncertain commit never replay writes.
- [ ] FK tests include composite/reordered keys, unique-key targets, duplicate labels, nullable keys, denied visibility, Unicode/wildcards, more than one page, own uncommitted rows, stale searches, timeout/cancel recovery, and target deletion before Apply.
- [ ] A large result retains existing paging budgets with a small edit set; lookup/preview/input stay responsive during background reads. Full integration tests, package tests, and app build pass before native UI acceptance.

Automated coverage is in `EditingTests`, `PostgresEditingTests`, `ManagedSessionTests`, `WorksheetTransactionTests`, `ResultsGridEditingTests`, `WorksheetEditingIntegrationTests`, `ForeignKeyLookupCancellationTests`, and `ResultStoreTests`. Disposable PostgreSQL cases exercise real row updates, deferred constraints, concurrent-writer conflicts, rebasing that removes a draft while refreshing the fetched values/version, generated values, read-only domains, RLS, composite and unique-target FK order/paging, Unicode search, own uncommitted rows, target deletion, cancellation, storage failure, and late environment restrictions. Controlled cancellation tests keep the operation lease through savepoint recovery and reject stale lookup callbacks. Offscreen native tests cover editing gestures, NULL/empty distinctions, IME guards, editor lifetime, draft markers, and memory lease release. Live mouse/keyboard, VoiceOver, and visual acceptance remain unchecked above; no real project database was used.

Verification on 2026-09-29: `./Scripts/test.sh --integration` passed **305 tests** (168 package XCTest, 15 result-store Swift Testing, and 122 application tests), with no failures or skipped fixture cases. Added `SQLDirectTableSelectTests` and `ResultEditProjectionTests` cover eligibility, self-join rejection, aliases, complete composite keys, row shape, and metadata fencing. Real application fixtures also exercise direct SELECT editing, reordered/duplicate aliases, duplicate result rows, expression preservation, first-edit conflicts, reordered FK selection, and CSV shape. The Release Xcode build passed. Bundle verification confirmed a valid ad-hoc signature, nine bundled libraries, and no Homebrew or workspace dependency paths.

Follow-up verification on 2026-09-29 for blank-row insertion and transaction access: `./Scripts/test.sh --integration` passed **397 tests** (230 package XCTest, 24 Swift Testing, and 143 application tests), with no failures or skipped cases. Coverage includes insert defaults/NULL/empty text, generated keys, insert permissions, empty-table insertion, new-row FK selection, mixed-batch rollback, returned-row editing, and default-only draft close/undo behavior. All 53 grid tests passed, including insertion gestures and stale editor completion. The Release build and bundle verification also passed; the first Settings control now provides persistent System/Light/Dark appearance.

The normal `make dev` restart was attempted again after this build, but the running application canceled quitting (AppleScript error -128). The verified build is ready in `build/DerivedData/Build/Products/Release/db3.app`; the existing process was not forcibly terminated, and this build has not received interactive acceptance.

Builds and local app lifecycle commands follow the current AGENTS.md exception. Mouse/keyboard automation, screenshots, and UI inspection still require fresh approval. This document is a plan, not permission to alter a connected database during implementation.
