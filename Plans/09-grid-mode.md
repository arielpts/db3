# 09 — Object grid mode

**Status:** planned; this task does not implement grid browsing.  
**Planning date:** 2026-09-29.  
**Scope:** double-click a PostgreSQL object to open its data in a tab, automatically fetch the first bounded page, and browse with server-side sorting and SQL conditions.  
**Depends on:** [04 — Query tabs](04-tabs.md) and [05 — Objects](05-objects.md).  
**Coordinates with:** [06 — Editing](06-edit.md) for a separate editable mode, [03 — SSH](03-ssh-tunnels.md) for transport, and [07 — Projects](07-projects.md) / [08 — Odoo](08-odoo-json-rpc.md) for future source capabilities. The first delivery uses PostgreSQL; it does not translate SQL filters into Odoo domains.

## Outcome

Double-click a table, view, or materialized view in the Objects sidebar. db3 opens a grid tab, obtains its connection through the normal credential flow, and displays its first **1,000 rows** without requiring the user to open an editor or press Run. The tab shows its connection, database, qualified object name, filters, ordering, loading/error state, and page range.

The interaction takes inspiration from DataGrip's object data editor: SQL predicates in a WHERE field, SQL ordering in an ORDER BY field, and sorting through column headers. These controls query the database, so they can reach rows outside the displayed page. [DataGrip filtering](https://www.jetbrains.com/help/datagrip/tables-filter.html), [DataGrip sorting](https://www.jetbrains.com/help/datagrip/tables-sort.html).

This task deliberately replaces task 05's rule that double-click never executes SQL **for the Open Data action only**. Single-click still selects metadata. **New SELECT Query**, the tab-row **+**, and ordinary SQL-file tabs still prepare a query without connecting or running it. Grid tabs share the existing tab row and four-tab capacity; they are not a second window or a sidebar worksheet list.

## Opening and tab identity

- Double-click and the row context-menu command **Open Data** have the same behavior. Return on a focused object row provides a keyboard equivalent; Return in sidebar search retains search behavior. Announce the action through accessibility.
- Capture the clicked row's validated profile/source revision, database identity, relation OID, schema, name, and kind before any asynchronous work. Do not rely on whichever row becomes selected while credentials load.
- Reserve a tab slot before connecting. Show the tab immediately with Connecting / Loading / Cancel. Repeated double-clicks during loading reuse that pending tab and operation.
- By default, reopening the same source/database/relation activates its existing grid tab and preserves its page, condition drafts, applied filters, ordering, widths, and selection. It does not refresh automatically. An explicit **Open Data in New Tab** action creates an independent view when capacity permits.
- An existing matching tab can be activated at capacity. A new object at capacity shows the existing four-tab message without opening a connection or replacing another tab.
- Use a typed grid identity separate from tab UUID and display title. Catalog generation is an invalidation token, not a permanent deduplication key. Refreshing metadata should not create duplicates for unchanged relations; a changed endpoint/credential revision, database replacement, or drop/recreate must not reuse a stale binding merely because names or OIDs match.
- Revalidate object identity and capabilities on connection/reconnect. Renames update names only after identity verification; a replaced or missing relation yields a useful error. Do not silently run against a different object that inherited the old name.
- Titles use the qualified object name plus a grid/kind icon. Keep connection/database context visible and preserve tab shortcuts, middle-click close, reordering, overflow, and inactive-tab isolation.

## Grid layout and actions

Use the existing native results grid and value inspector. The SQL editor is hidden in grid mode; **View SQL** reveals the generated query and its bound parameters, and **Open as SQL Query** creates an ordinary, unexecuted query tab without changing the grid tab.

For **Open as SQL Query**, render the captured parameters as correctly escaped PostgreSQL literals with explicit type casts where needed; ordinary SQL tabs currently have no parameter-binding editor. Use one tested, type-aware renderer rather than ad hoc interpolation, and never emit unresolved `$n` placeholders. If a parameter type cannot be represented faithfully, explain why this action is unavailable while retaining the parameterized preview. The new SQL document is unsaved and follows normal Connect/Run behavior.

```text
Tabs: [Query 1] [public.orders ▦] [+]
      Connection · database · public.orders                 Read only
WHERE    [status = 'open' AND total > 100                   ] [Apply]
ORDER BY [created_at DESC NULLS LAST                       ] [Reset]
      [Refresh] [Cancel] [View SQL]             Rows/page [1000 ▾]
      ┌ id ────┬ status ───┬ total ───┬ created_at ↓ 1 ───────┐
      │ ...    │ ...       │ ...      │ ...                    │
      └────────┴───────────┴──────────┴────────────────────────┘
      Rows 1–1000 · more available               [First] [Previous] [Next]
```

- Display WHERE and ORDER BY together above the grid. Empty fields mean no user condition/order. Use SQL-aware editing and column-name completion scoped to this object's metadata; general query completion is outside this task.
- **Apply** or Return in either condition field applies both drafts and returns to page one. Typing alone never queries. Keep draft text separate from the last successful applied specification and show when unapplied changes exist. Escape restores that field's applied text.
- **Reset** clears both drafts and applies the default unfiltered view; each field can also be cleared independently and then applied. Default primary-key ordering, if available, remains visible as such.
- **Refresh** reloads the current page using the applied specification; it does not unexpectedly apply unfinished text. On an emptied later page, show the empty range and First/Previous rather than silently choosing another page.
- Preserve full-value inspection, copy, column resizing, double-click divider auto-fit, and export of the displayed page. Label that export scope explicitly; an all-matching-rows export is later work.
- Initial grids are read-only. Task 06's explicit **Edit Table Data** remains a separate path with its own eligibility, transaction, preview, and draft rules. Merely double-clicking an object must not turn on editing or generate UPDATEs.
- Route toolbar Run / `⌘Return` by tab kind: **Apply** when condition drafts differ, otherwise **Refresh** the applied grid. Never execute hidden worksheet starter SQL. Disable SQL Save/Save As, sample-data replacement, generic transaction commands, and in-place connection retargeting for grid tabs. Open SQL and new-query commands still create ordinary tabs; Cancel, export, inspector, and close target the grid's captured operation/result.

## SQL conditions

WHERE accepts a PostgreSQL boolean expression **without** the WHERE keyword. Examples:

```sql
status = 'open' AND total >= 100
name ILIKE '%alice%' OR email IS NULL
created_at >= CURRENT_DATE - INTERVAL '7 days'
payload->>'state' = 'ready'
```

Support parentheses, comparisons, AND/OR/NOT, IN, BETWEEN, IS NULL, LIKE/ILIKE, casts, and normal PostgreSQL expressions. Raw SQL keeps PostgreSQL wildcard semantics. This is distinct from the sidebar's literal object-name search.

Cell context actions **Filter Equals**, **Filter Not Equals**, **Is NULL**, and **Is Not NULL** build typed predicates for supported values. Combine new quick conditions with the existing predicate using explicit parentheses and AND. A quick filter is an explicit apply action; it must not discard an unapplied text draft—add to that draft and leave Apply pending instead. Use exact stored values, not truncated cell previews; preserve NULL, empty text, large numeric text, dates, and escaping.

The query compiler must distinguish raw, user-authored SQL from generated values. Bind quick-filter values, page size, and offset as parameters. Quote each schema/relation/column identifier separately using the existing PostgreSQL identifier helper. A whole SQL predicate is not a string parameter.

The compiler owns parameter numbering. Raw WHERE/ORDER BY fragments cannot contain PostgreSQL parameter-reference nodes such as `$1`; reject them with a field error instead of binding them to unrelated quick-filter or pagination values. Recognize literal/comment/dollar-quoted text correctly. A future parameter-entry UI would need an explicit binding and remapping contract.

Validate WHERE as one expression and ORDER BY as one ordering list using PostgreSQL-aware parsing, then compose an app-owned SELECT. Validate the resulting structure as well: keep the captured outer relation/projection and app-controlled LIMIT/OFFSET, and reject extra statements, outer query clauses, set operations, write/locking clauses, or attempts to escape the fragment. Semicolons inside SQL strings and comments need correct lexical handling. The existing statement selector alone is not a fragment validator; do not use regex or simple semicolon splitting. Choose and prove the parser/version/dependency approach before enabling raw fragments.

Errors point to the relevant field and preserve its draft. Never fall back to an unfiltered query after a syntax, type, permission, or timeout error. Query previews show the exact effective SQL, including default/tie-breaker ordering and pagination, with parameters represented separately. Do not put predicate text, parameter values, or returned data into diagnostic logs.

## Sorting

- Header sort controls cycle **Ascending → Descending → None**. A normal click selects that column as the primary user sort; Option-click adds/cycles a column within a multi-column order. A Sort menu provides the same actions without modifier keys.
- Show direction and priority numbers. Provide **NULLS FIRST**, **NULLS LAST**, and PostgreSQL default null placement for each structured sort key. Sorting fetches a new server page; do not sort only the currently loaded rows and imply a database-wide ordering.
- ORDER BY accepts comma-separated PostgreSQL sort expressions without the keyword, for example `created_at DESC NULLS LAST, total ASC`. Enter/Apply uses the same query-generation path as header sorting.
- Keep one applied ordering model for both controls. Simple column clauses map to header indicators. Expression-based ordering displays **SQL ordering**; provide an explicit **Use Column Sorting** action to replace it before header controls can overwrite those expressions. Raw and structured orders must never both appear independently active.
- With clean condition fields, header sorting applies immediately. With unapplied WHERE or ORDER BY text, update only the ordering draft and leave Apply pending; preserve the WHERE draft. **Use Column Sorting** follows the same rule. Field edits, header actions, and quick filters all pass through one draft/applied coordinator so a convenience action cannot discard or unexpectedly execute unfinished text.
- Where a valid primary key is available, use all components for the default order and append missing components as tie-breakers to user ordering. Show these effective keys in View SQL. Do not guess uniqueness from a column named `id`, and do not use `ctid` or display row numbers as stable identity.
- Views, materialized views, and keyless tables can be browsed without inventing a key. Display that page order is not guaranteed when no unique ordering is known. Unsupported sort operators/types produce an actionable error while retaining the prior applied result.

## Paging, loading, and execution

Default to 1,000 rows per page, with 100 / 500 / 1,000 choices. Fetch at most page size plus one lookahead row; only expose **Next** after a successful complete page demonstrates more rows. Show a visible row range and “more available” or “end of results”, not a fabricated total. Do not issue an automatic COUNT(*) or offer Fetch All in this slice.

The first implementation can use checked, parameterized LIMIT/OFFSET with First/Previous/Next. Filter, ordering, and page-size changes reset the offset. Large offsets may be expensive, and separate page requests can shift under concurrent database changes. Stable unique ordering improves repeatability but does not create a consistent cross-page snapshot; do not hold a long transaction merely to browse. Keyset paging is a later optimization. [PostgreSQL LIMIT/OFFSET semantics](https://www.postgresql.org/docs/17/queries-limit.html).

Each grid tab owns one normal worksheet-budget session and its results. It never borrows the Objects catalog session or another tab's transaction. Opening a grid is authorization for its first bounded read; normal Keychain/credential/TLS/SSH prompts still apply. Cancelling those prompts leaves a retryable tab. Unsupported SSH never falls back to a direct connection.

Run each browse request as one serialized internal operation: begin a short READ ONLY transaction, apply a local statement deadline (initially 10 seconds), fetch metadata/page as appropriate, and end with ROLLBACK after collecting the result. Error/cancel also rolls back and completes protocol recovery before the next request. There is no automatic commit of user work and no change to task 06's Manual mode for ordinary SQL/editing tabs. Grid mode cannot be attached to an existing editing transaction; opening an editing/query tab is a distinct action. PostgreSQL read-only mode enforces database restrictions, but is not a general sandbox for every possible function side effect. [PostgreSQL transaction access modes](https://www.postgresql.org/docs/17/sql-set-transaction.html).

- Capture source, tab, connection intent, applied-spec revision, and request generation before awaiting. Cancel/supersede queued obsolete reloads, and wait for the active operation's cancellation/recovery before executing the newest one. Late responses cannot replace a newer page or another tab's results.
- Retain the last successful grid while a replacement loads. Stage new rows separately and swap the applied specification, result, page range, and generation together only after success. On failure/cancel, keep the prior view labeled as the previous result; do not label it with the failed predicate or display an incomplete page as complete.
- Reuse existing result-store and grid virtualization limits: 16 MiB resident result cache per tab, 64 MiB across four tabs, shared 1 GiB spool quota, and existing per-batch/value protections. Replacement staging shares those budgets rather than doubling them. A LIMIT bounds row count, not server work or bytes.
- Perform SQL parsing, catalog/key discovery, execution, decoding, and storage off the main actor. Switching tabs pauses unnecessary presentation work without discarding results, column widths, filter drafts, or session identity.
- Empty objects and successful zero-match filters have distinct states. Permission failures, column-only grants, RLS, dropped columns/objects, and an unpopulated materialized view have honest error/access states. Use an explicit permitted-column projection when only column grants allow browsing; never automatically populate or refresh a materialized view.

## Implementation boundaries

| Area | Planned change |
| --- | --- |
| `DB3Core` | Grid source identity, query specification, parsed predicate/order representation, typed parameters, page request/result, and column/key capabilities; reuse catalog types. |
| `DB3Postgres` | Parameterized worksheet reads, bounded metadata discovery, generated-query validation, read-only operation lifecycle, deadline/cancellation, and source verification. |
| `WorkbenchModel` / `Worksheet` | Distinct `openObjectGrid` operation and tab content kind; capacity/deduplication before connection, generation fencing, applied/draft state, and staged result replacement. Do not treat generated browse SQL as an unsaved SQL file. |
| `ObjectBrowserView` | Double-click the actual row, Open Data / Open Data in New Tab, and keyboard/accessibility actions; preserve New SELECT Query. |
| Tab content host / grid views | Retain per-tab grid/filter state, toolbar and SQL preview, sorting callbacks, native resizing/inspector behavior, and page controls. Keep SQL tab behavior unchanged. |
| Workspace recovery | Version the SQL-only snapshot to include tab kind, source, condition/order drafts and applied state, and page size. Migrate existing SQL snapshots. Restore grid tabs disconnected and unloaded; no startup network reads. Follow the existing SQL-text recovery policy for conditions, without adding a separate persistent filter history or storing results/credentials. |

Task 06 can later consume the same source/column metadata, query builder, and grid presentation, while keeping edit snapshots and manual transaction ownership separate. Task 07 may decorate labels/grouping; it cannot change relation identity or executable identifiers. Task 08 requires its own capability-aware filtering contract before ORM objects can use this view.

[10 — Multi-row copy and paste](10-copy-paste.md) adds range/row selection and bounded clipboard operations. These browsing grids support Copy; Paste requires task 06's explicit eligible editing mode and cannot silently turn a read-only browse session into an editing transaction.

## Delivery and acceptance

1. **Model and SQL contract:** finalize tab identity/recovery migration, query specification, raw-fragment parser, parameter binding, unique-order metadata, and bounded read operation.
2. **Open Data:** implement tab admission/reuse, double-click/menu/keyboard activation, connection/retry/cancel, first page, and read-only grid content.
3. **Conditions and sorting:** add draft/applied fields, column sorting, multi-sort/null placement, quick filters, SQL preview, and result-preserving reloads.
4. **Paging and lifecycle:** add page controls, metadata invalidation, export scope, disconnected restoration, close cleanup, and task 06 integration boundaries.
5. **Verify and document:** use fake services and disposable PostgreSQL fixtures, then build with `make dev` and verify native interaction under the workspace's computer-control rules. No implementation testing against project production credentials is needed.

- [ ] Double-click a table, view, or materialized view opens a grid and loads its first bounded page; single-click and New SELECT Query do not execute data reads.
- [ ] Repeated activation, loading tabs, duplicates, four-tab capacity, source switches during credential prompts, and same names/OIDs across different databases preserve exact ownership.
- [ ] Conditions and sorting find rows outside page one. NULLs, quoted identifiers, Unicode, JSON expressions, composite keys, duplicates, raw ordering, and unsupported sort types behave as specified.
- [ ] Generated values stay parameters; raw fragments cannot claim `$n` bindings, inject extra statements, or override the outer relation/page limit. SQL literals/comments/dollar quotes, literal-rendered Open as SQL Query, and syntax/type errors have dedicated cases.
- [ ] Failed/cancelled/obsolete requests retain the last successful applied specification and result. Closing a tab or changing profiles cannot publish a late page or reopen a closed session.
- [ ] Page changes reset or retain offsets correctly, lookahead rows never appear in export/selection, and keyless/concurrently changing objects do not imply stable snapshots or exact totals.
- [ ] Read-only requests leave no idle transaction; a function attempting a database write is rejected by the read-only operation. No browse action commits, rolls back, or borrows another tab's user transaction.
- [ ] Restricted grants, RLS, empty/unpopulated objects, rename/drop/recreate, schema changes, disconnection, statement deadlines, and large/wide values produce correct states within existing resource budgets.
- [ ] Native sort clicks preserve header-divider auto-fit, keyboard input/IME, inspector/copy, widths, and retained tab state. Grid restoration performs no automatic connection/query, and SQL-tab recovery remains compatible.
- [ ] Header/quick-filter actions preserve unapplied text, and Run/Save/transaction/source commands respect the active tab kind instead of executing hidden SQL or changing the browse-session contract.

This is a planning task. Creating it does not change the current object gestures, run SQL, or implement database editing.
