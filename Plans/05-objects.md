# 05 — Searchable objects sidebar

**Status:** implemented for direct PostgreSQL connections on 2026-09-29; interactive UI verification and task 02/03 integration remain pending as recorded below.  
**Planning date:** 2026-09-29.  
**Scope:** PostgreSQL tables, views, and materialized views in the sidebar, with search, schema and object-kind filtering, refresh, and an explicit action to prepare a query tab.  
**Follow-up:** [09 — Grid mode](09-grid-mode.md) changes object double-click into **Open Data**, automatically opening a grid tab and loading its first page. That explicit data action supersedes this task's no-execution rule for double-click only; selection and New SELECT Query retain the behavior below.  
**Depends on:** [01 — Native scaffold](01-scaffold.md) and the browser/tab context separation in [04 — Query tabs](04-tabs.md).  
**Integrates with:** [02 — Import connections](02-import-connections.md) for profiles/colors and [03 — SSH tunnels](03-ssh-tunnels.md) for routed catalog connections. Direct connections can ship before task 03; SSH-required profiles remain blocked until supported. [07 — Projects](07-projects.md) adds project-provided namespace groups, a Base toggle, and user grouping overrides saved in `.db3/project.json`; Odoo groups follow module ownership while PostgreSQL schema identity stays separate.

## Implementation record — 2026-09-29

The direct-connection implementation adds `CatalogTypes` in `DB3Core`, bound parameters and `PostgresCatalogService` in `DB3Postgres`, and native `ObjectBrowserModel`/`ObjectBrowserView` integration with task 04's independent query tabs. The sidebar provides search, schema and kind filtering, pagination, refresh/cancel, selection, qualified-name copying, and explicit **New SELECT Query**. Opening that tab captures the object's source and inserts SQL without connecting or executing it.

Catalog browsing reads committed metadata through one additional catalog owner, separately from the four worksheet sessions. It never borrows a tab's transaction or results. Admission includes connection setup, cancellation recovery, and closing. Queries fetch 500 objects plus one continuation row, use literal bound search and stable keyset cursors, and have a 10-second statement deadline. The in-memory browser cache is bounded to 5,000 objects and 8 MiB across profiles/schemas/searches; stale rows and incomplete results have explicit states.

Automated server fixtures used **PostgreSQL 17.9**; this record makes no compatibility claim for other server versions. [Catalog measurement notes](../Benchmarks/2026-09-29-catalog-notes.md) record the separate 5,500-view fixture and its limitations. Task 02's imported connection colors and task 03's SSH routing/session factory are not implemented yet; their requirements below remain follow-up integration work, and no SSH support is claimed. Interactive keyboard, VoiceOver, appearance, and sidebar responsiveness checks remain pending; no computer-control session was requested or used for this work.

## Outcome

Keep saved **Connections** at the top of the left sidebar and add an **Objects** section beneath them. Objects belong to the selected sidebar connection and its saved database. Show **Tables**, **Views**, and **Materialized Views** together by default, with a search field and a kind filter inside this section. Queries live in task 04's horizontal tabs above the editor/results area.

Selecting a different sidebar connection changes the browser context without changing any query tab's connection, SQL, results, or transaction. Selecting a query tab likewise does not silently switch the sidebar context. The Objects heading shows the selected connection name and database so both contexts remain clear. The initial version browses the database saved in the connection profile; a server-wide database chooser is outside this task.

The browser reads catalog metadata only. Selecting a row does not query its data. **New SELECT Query** creates a new tab for that object's captured connection/database and inserts a qualified, limited SELECT statement. The user runs it explicitly.

## Current code and required boundaries

| Current behavior | Planned change |
| --- | --- |
| `WorkbenchView.swift` puts Connections and Worksheets in the sidebar | Task 04 moves worksheets into tabs; this task fills the sidebar with a separate Objects section. |
| A connection-row button invokes `connectSaved`, which reconnects the active worksheet | Task 04 introduces a browser profile selection independent of the active tab. Object browsing uses that selection. |
| `Worksheet` owns a private `DatabaseSession`, its transaction, and result store | Preserve this ownership. Catalog requests never run through a worksheet session or overwrite worksheet results. |
| `DatabaseSession.execute` accepts SQL text only | Add a narrow parameterized catalog-query path in `DB3Postgres`; search text and page cursors must not be interpolated into SQL. |
| The app permits four worksheet sessions | Retain that limit and admit at most one additional catalog session app-wide, including sessions connecting or closing. |
| There is no catalog model, cache, or browser state | Add typed relation models, a testable catalog service, and a small main-actor presentation model. |

## Sidebar interaction

### Layout and selection

- Use the existing native sidebar, with a resizable boundary between Connections and Objects if needed to keep search and object navigation usable with many saved connections. Both lists scroll independently; the Objects heading/search remain available.
- Show the selected connection/database, refresh button, **Search objects** field, and a compact menu with **All Objects**, **Tables**, **Views**, and **Materialized Views**. Default to All Objects. A schema dropdown beside the kind filter defaults to the connection’s saved **Default schema** (`public` for new and existing profiles). It offers discovered non-system schemas and **All Schemas**; changing it restarts paged server filtering without changing query tabs. Search never filters the saved-connection list or query tabs.
- Use one flat object list, sorted by schema then name, with schema as a visible secondary label and a distinct icon plus textual kind. Do not hide schemas behind collapsed groups during search. Duplicate relation names in different schemas remain distinguishable.
- Tables include ordinary and partitioned tables. Partitioned parents and their ordinary-table partitions appear as individual relations, with a secondary partition label where available. Views and materialized views are separate kinds; a materialized view is never labeled as a table or ordinary view.
- Single-click selects a row and enables its context actions. Double-click does not execute SQL. Use the explicit **New SELECT Query** command in the row context menu and a discoverable action for the selected row; do not overload selection with network execution.
- Provide **Copy Qualified Name**. Keyboard navigation, search-field focus, Escape to clear the filter, context-menu access, and VoiceOver must work. Announce schema, name, kind, selection, and relevant state; color alone conveys none of these.
- Retain task 02's connection colors on connection rows. Object-kind icons/status must remain readable without borrowing a connection's warning-like color as a kind indicator.

### Connection and loading states

Selecting a connection in the sidebar establishes the browser context and starts its catalog load asynchronously. This explicit navigation is enough; do not add a confirmation step before listing objects. Loading credentials or SSH trust goes through the normal native connection flow. Mere app launch, profile import, tab creation, or restoring sidebar selection does not connect; a restored context can offer **Load Objects** until the user requests it.

| State | Presentation and action |
| --- | --- |
| No connection selected | **Select a connection to browse objects**. |
| Restored selection, not loaded | Connection/database heading and **Load Objects**; a fresh user selection starts loading directly. |
| Connecting / loading | Inline progress and Cancel; sidebar navigation and query tabs remain usable. |
| Loaded, no eligible objects | **No tables, views, or materialized views found** for this database; Refresh remains available. |
| Search completed without matches | **No objects match your search**, with Clear Search; distinguish this from an unloaded or incomplete catalog. |
| More matches exist | Loaded count and **Load More**; never present a truncated count as the database total. |
| Refreshing existing results | Keep rows visible with **Refreshing…** and disable stale object actions until the refresh succeeds or is cancelled. |
| Load/refresh failed | Inline error and Retry; retain any cached rows visibly marked **Out of date**. Do not replace an error with an empty-state claim. |
| Credentials/trust/configuration needed | Explain the blocked state and offer the existing connection/configuration flow. Never attempt a direct fallback. |
| Cancelled or disconnected | Show the actual state, preserve search, and allow a deliberate retry; do not restart the request automatically. |

Switching the browser profile cancels the old request, invalidates its pending prompts, and closes its catalog session before another one is admitted. Display any cached rows only under their matching profile/database heading. An existing query tab continues running normally throughout.

## PostgreSQL catalog contract

Use `pg_catalog.pg_class` joined to `pg_catalog.pg_namespace` in the connected database. Return relation OID, schema OID/name, relation name, kind, partition flag, persistence, materialized-view population state where applicable, and advisory access flags. Read the connected database identity separately and verify it matches the requested profile database.

Map only these relation kinds initially:

| `pg_class.relkind` | Browser kind |
| --- | --- |
| `r`, `p` | Table, with an additional partitioned-table label for `p` |
| `v` | View |
| `m` | Materialized View |

PostgreSQL explicitly distinguishes these catalog kinds; foreign tables, sequences, indexes, composite types, and TOAST relations are outside this task. Use the catalog rather than a union of information-schema views that could omit materialized views. [PostgreSQL `pg_class`](https://www.postgresql.org/docs/current/catalog-pg-class.html).

- Default scope is the connection’s saved **Default schema**, falling back to `public`; **All Schemas** explicitly broadens it to all non-system schemas in the selected database. The setting appears in URL and manual connection properties and does not alter SQL `search_path`. Older saved profiles decode with `public`. Discovery reads non-system namespaces independently of search/kind/object results, includes empty schemas, and is capped at 5,000 names with a truncation notice. A missing configured schema stays selected and shows an empty result instead of silently broadening scope. Hide `pg_catalog`, `information_schema`, internal TOAST schemas, and temporary relations. A system-object toggle and worksheet-local temporary-object browser are later features.
- Do not filter with `pg_table_is_visible`: it describes resolution through `search_path`, not whether an object belongs in this cross-schema list. Query schema `USAGE`, table `SELECT`, and any-column `SELECT` capability by OID to annotate restricted/limited access. List returned catalog objects even when data access is limited; do not treat a false table-level flag as proof that no column grants exist. These flags are advisory, can become stale, and never grant access or bypass PostgreSQL. [PostgreSQL privilege and visibility functions](https://www.postgresql.org/docs/current/functions-info.html).
- A catalog permission failure is an error state, not an empty database. Object selection and name copying remain metadata operations; execution errors occur in the user's query tab. An unpopulated materialized view may be labeled **Not populated**; browsing never populates or refreshes it.
- Use a typed identity containing saved profile UUID, connected database OID, and relation OID. Scope identities/cache to the profile's endpoint/authentication/transport revision and a valid catalog generation. Names are display values, not IDs: renaming preserves selection within a valid refresh; identical names in other schemas/databases do not collide. OIDs are not permanent across drop/recreate, database replacement, or unrelated servers; invalidate accordingly and do not persist object IDs as durable bookmarks in v1.
- Schema-qualify generated identifiers and quote each component separately using PostgreSQL identifier rules, including doubling embedded double quotes. Never split a stored name on `.` or use string-literal quoting for identifiers. For example, schema `Sales` and table `Order.Items` produce `"Sales"."Order.Items"`. [PostgreSQL quoted identifiers](https://www.postgresql.org/docs/current/sql-syntax-lexical.html).
- Bind user search input, cursor values, kind choices, and limits as data through a parameterized driver API. Keep catalog SQL templates static and the kind mapping allowlisted. Preserve the existing one-statement-per-execution rule and async cancellation/UTF-8 behavior when extending the driver. [libpq asynchronous parameterized queries](https://www.postgresql.org/docs/current/libpq-async.html).

The catalog session reflects committed objects visible to its saved connection user. It cannot reflect another tab's uncommitted DDL, temporary relations, `SET ROLE`, or session-local `search_path`. Explain this in browser help; do not steal a busy tab's session or silently commit/roll back user work to make the list match it.

## Search, refresh, and resource limits

Search is case-insensitive literal substring matching against the schema name, object name, and their displayed qualified form. `%`, `_`, quotes, backslashes, and dots are literal search characters, not SQL wildcard syntax. Use one tested definition consistently; initial case matching follows the database's collation. The exact, case-sensitive schema filter and kind filter intersect the search, and All Objects searches all three kinds together.

Use server-filtered, bounded catalog pages so searching reaches objects beyond the currently loaded page. Debounce typing by approximately 200 ms, cancel/supersede old requests, and retain only the latest requested search. Empty text fetches the normal list. Do not filter a partial cache locally and then claim **No objects match**. A zero-match state is valid only after the matching server request completes successfully.

Initial bounds and behavior:

- Fetch 500 rows per page, plus one row to determine whether more exist. Use stable keyset order/cursors over schema name, relation name, and OID, with an explicit consistent ordering/collation across pages. Avoid an unbounded initial fetch or an extra `COUNT(*)` on each keystroke.
- Keep at most 5,000 relation rows and 8 MiB of decoded catalog/search cache app-wide, with bounded request/response batches and LRU eviction. At the display cap, show **Narrow your search to see more objects**. The next search runs on the server and can find previously unlisted objects; no unbounded accumulation in hidden search states.
- Publish small page updates on the main actor; do SQL, decoding, matching, and sorting on background owners. Use native list virtualization and stable row IDs. No database call, Keychain lookup, synchronous file read, or large sort occurs in a view/body/data-source callback.
- Add a bounded statement deadline, initially 10 seconds excluding user-input waits. Cancel protocol work and finish recovery before reusing the metadata session; if recovery fails, close it and expose Retry. No new session bypasses the one-session admission cap while the prior owner is still closing.
- Cache only in memory. Mark cached rows out of date after switching away, reconnecting, or changing connection settings. Do not persist database structure to disk in this task. A cache carries its full source/revision, filters, completeness, and last-success time.
- **Refresh Objects** reloads the current search/filter from the first page, preserving valid selection by identity. It reads catalog metadata; it never issues `REFRESH MATERIALIZED VIEW`. Invalidate the loaded page chain when refreshing so pages from different searches or source revisions cannot be combined.
- Cancel, newer search text, profile change, profile removal/edit, disconnect, and app shutdown all invalidate the request generation. An old response/error/prompt cannot replace the current list or reopen its connection. Cancellation must target its exact operation, not whichever query happens to start next.
- Concurrent external DDL may change a paged list. Deduplicate by identity and offer Refresh; do not hold a long transaction/snapshot merely to browse. Dropped objects and renamed objects receive a useful ordinary query error if a prepared SELECT is later run against stale names.

## Integration with query tabs and SSH

**New SELECT Query** captures the selected object's profile snapshot, saved database, schema, and relation name at invocation. It creates and selects a fresh task 04 tab containing:

```sql
SELECT *
FROM "schema_name"."object_name"
LIMIT 1000;
```

The title identifies the object; the tab's connection/database context is explicit. Creation does not connect or run SQL, and it never replaces an existing tab's editor or result set. Follow task 04's normal explicit Connect/Run behavior. At the four-tab limit, show the existing capacity message and leave the workspace unchanged. A profile switch or rename while preparing the command cannot redirect it to another database.

The browser uses the shared session factory and credential/challenge coordinator introduced by task 03, with an explicit **catalog** owner purpose. Its separate connection must honor the exact TLS/SSH/configuration rules used by worksheets. A tunneled catalog session owns its own transport lease and uses the same cancellation route; it does not borrow a worksheet tunnel or disconnect one on refresh. Include this additional owner in the application-wide SSH forwarding and session budgets. Until SSH is available, an imported SSH profile shows the support/configuration requirement with no direct-network attempt.

Creating a tab from an object does not pass a live catalog connection, password, SSH lease, transaction, or `ResultStore` into the worksheet. Only nonsecret typed source context and generated SQL cross this boundary. Prompt replies are scoped to the catalog attempt and ignored if its context changes.

## Architecture and implementation sequence

| Area | Planned work |
| --- | --- |
| `DB3Core` | `DatabaseObject`, `DatabaseObjectKind`, source/database identity, query/page/cursor models, and a narrow catalog service protocol. Keep UI and native-driver pointers out. |
| `DB3Postgres` | Catalog SQL/mapping and parameterized async query support using the existing private driver owner, deadlines, cancellation, and backpressure. |
| Session factory/coordinator | One bounded catalog-session owner, purpose-scoped credentials/prompts, direct/SSH routing, and deterministic shutdown. |
| New `ObjectBrowserModel.swift` | Browser selection, search/filter state, generation fencing, cache completeness/eviction, pagination, error/retry, and explicit object actions. Injectable service for deterministic tests. |
| New `ObjectBrowserView.swift` and `WorkbenchView.swift` | Native sidebar section, object rows, search, kind filter, progress/error states, keyboard behavior, and context actions. |
| `WorkbenchModel.swift` | Use task 04's browser profile selection; create a tab from captured object context; close the catalog owner on shutdown independently of worksheets. |
| Package/app tests and docs | Catalog mapping/query fixtures, state-machine tests, disposable PostgreSQL integration coverage, and README feature/limitation updates. Update project generation if new files/targets require it. |

1. **Define the shared context.** Land task 04's separation of browser selection and query tabs. Specify catalog identity, source revision, request/page types, connection budget, and explicit query-tab creation API.
2. **Implement catalog access.** Add bound parameters, static SQL, kind mapping, identifier quoting, limits, and a separately owned metadata connection. Prove direct routing, restricted permissions, and cancellation before UI integration.
3. **Build the Objects section.** Add loading states, all three kinds, search/filter/paging, selection, Refresh, Copy Qualified Name, and New SELECT Query. Preserve query-tab state during every browser action.
4. **Integrate routes and lifecycle.** Reuse task 02 profile requirements and task 03's factory/challenges; verify one metadata owner, invalidation, profile edits, app shutdown, and no direct fallback.
5. **Verify and document.** Complete the checks below, measure large-catalog behavior, and record supported server versions and limitations before changing this plan's status to implemented.

## Verification and acceptance

Use synthetic fixtures and disposable PostgreSQL databases. Do not use imported production connections as test fixtures.

- [x] The implemented sidebar contains Connections plus Objects with search; query documents use task 04's horizontal tab strip. Source and workbench tests verify separate browser/tab context. Interactive layout verification remains below.
- [x] Disposable PostgreSQL fixtures cover ordinary tables, partitioned parents/children, views, populated/unpopulated materialized views, multiple schemas, and duplicate/quoted names. Tests exclude system/temp relations, sequences, indexes, and composite types and verify object kind/schema/population flags.
- [x] A 514-object fixture finds tables, views, and materialized views beyond the first 500 rows through server search, including schema-qualified matches and literal wildcard/backslash/quote/dot characters, Unicode, and mixed-case names. Model tests verify clearing filters and server requests beyond a partial cache; workbench tests preserve tab context.
- [x] Injectable model tests cover no selection, restored/not-loaded state, loading, successful empty/no-match results, partial pages, row/byte caps, permission errors, stale rows, cancellation, retry, and oversized responses. Failed or incomplete requests cannot claim a successful empty result.
- [x] Restricted-role fixtures verify schema USAGE, table SELECT, column-only SELECT, denied access, and revoked column grants. Flags remain advisory and do not promise that a generated `SELECT *` will succeed.
- [x] Real fixtures verify rename, drop/recreate, reconnect, and source-revision changes. Typed identity/model fixtures separately verify equal relation OIDs across different database/source identities and reject mixed generations. Workbench tests verify saved-profile edits invalidate browser state while existing tabs retain their captured profile; the equal-OID case does not claim two live databases with deliberately matched OIDs.
- [x] Workbench tests verify **New SELECT Query** quotes unusual names, captures the original connection/database/schema/object, creates an unconnected and unexecuted tab, preserves existing SQL, and enforces four-tab capacity. A real fixture executes generated SQL for quoted identifiers. Row selection has no query-execution action; interactive single/double-click verification remains pending.
- [x] Model tests exercise debounce, late pages/errors, profile switches during credential lookup, stale prompt replies, cancellation, retry, and shutdown. Real locked-catalog queries verify cancellation and 10-second deadline recovery before reuse. Sixteen concurrent source revisions are checked against `pg_stat_activity` and admit at most one catalog session.
- [x] Live transaction-isolation verification passes: the separate catalog session hides uncommitted DDL and worksheet-local temporary relations, leaves an open transaction unchanged, discovers the new relation after COMMIT, and leaves a failed transaction failed. A real `pg_sleep(30)` remains active through browsing and stops only after its own explicit task cancellation. Workbench doubles also verify an active tab is neither retargeted nor disconnected.
- [ ] Complete transport/failure integration: browser-only connection loss and supported SSH fixtures must verify trust, credentials, TLS hostname identity, cancellation, tunnel ownership, and resource release. Current direct-driver tests cover TLS, protocol loss/cancellation recovery, missing/wrong SCRAM credentials, and non-authentication startup failures. Task 03's SSH profile requirements, no-direct-fallback checks, and transport fixtures remain deferred with task 03.
- [x] A synthetic 50,000-object service verifies 500-row publications, the 5,000-row display limit, and server search beyond that limit. Separate model tests cover byte caps, eviction, and latest-request-only publication. The disposable 5,500-view PostgreSQL fixture measured 11.9 ms for the first 500 objects and 2.4 ms for targeted search; see [measurement notes](../Benchmarks/2026-09-29-catalog-notes.md). Native sidebar responsiveness was not measured.
- [x] Final `Scripts/test.sh --integration` passed on 2026-09-29: **95 package XCTest cases plus 13 Swift Testing cases**, including **11 real catalog integration tests and two catalog type tests**, followed by **80 workbench XCTest cases**. Catalog app coverage includes 16 model tests and five workbench integration tests. The local execution log is `/tmp/db3-final-integration.log`.
- [x] The Release app build passed with `Scripts/build.sh`; `Scripts/verify-bundle.py` verified ad-hoc signing and nine bundled libraries without Homebrew/workspace runtime paths. The local build log is `/tmp/db3-objects-release-build.log`. These automated checks do not substitute for the interactive checks below.
- [ ] Interactive checks remain pending: keyboard navigation, search focus/Escape, context menus, VoiceOver labels, contrast, narrow sidebar widths, many saved connections, single/double-click behavior, visible browser/tab context separation, and native scrolling/responsiveness. No computer-control permission was requested for this implementation.

Under the current user instructions, building, rebuilding, testing, verifying the local app bundle, and launching/normally quitting/restarting db3 through CLI or platform commands are authorized development work. Mouse/keyboard automation, screenshots, UI-state inspection, browser control, and unrelated app control still require fresh explicit permission immediately before each control session. Record manual/interactive checks as pending if that permission has not been obtained.

## Later work

Column/index details, DDL/definition previews, foreign tables, system-object browsing, worksheet-local temporary objects, cross-database navigation, data editing, materialized-view refresh commands, and persistent catalog snapshots are separate follow-ups. This task is complete when the three requested object kinds are discoverable and searchable in the sidebar and can open correctly scoped query tabs without disrupting existing work.
