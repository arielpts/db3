# db3

A native PostgreSQL workbench for **macOS 26+**, built with SwiftUI, AppKit, and an asynchronous `libpq` driver. The interface takes workflow ideas from Navicat and Allround Automations' PL/SQL Developer while remaining PostgreSQL-specific.

**Status:** the native scaffold, [query tabs](Plans/04-tabs.md), [searchable object browser](Plans/05-objects.md), [inline table editing](Plans/06-edit.md), and [projects with model metadata](Plans/07-projects.md) are implemented for Apple Silicon macOS. Driver, catalog, storage, TLS, packaging, document lifecycle, workspace recovery, and editing have headless verification. Basic scaffold launch and a 10,000-row sample query were verified interactively on macOS 26.5.1; interactive acceptance of the new tabs, object browser, and inline editing remains pending. Broader UI acceptance checks remain open in the [scaffold plan](Plans/01-scaffold.md).

## Build and run

The verified build environment is Xcode **26.6**, Swift **6.3.3**, and PostgreSQL/libpq **17.9** on macOS 26.5.1. Select the full Xcode installation with `xcode-select`. `pg_config` must point to PostgreSQL 17.9 on the build machine.

```sh
make                # Show help (same as make help).
make configure      # Prepare native dependencies and generate the Xcode project.
make install        # Build, verify, and install to ~/Applications/db3.app.
make start          # Open the installed app.
make dev            # Build, verify, and run the local app without installation.
```

`make install` includes configuration and replaces the installed app bundle with a verified Release build. Choose another destination with `make install INSTALL_DIR=/Applications`, and use the same `INSTALL_DIR` for `make start`. If needed, set `PG_CONFIG=/path/to/pg_config` when configuring. These commands preserve the dependency lock; `make start` opens the installed app without forcing an existing session to quit.

`make dev` uses the same Release build and verification, then launches the bundle directly from the build directory. If db3 is running, it requests a normal quit and waits before reopening; cancelling the quit stops the command and preserves the current session.

Configuration, installation, `make dev`, and `Scripts/build.sh` share a build lock. Concurrent invocations wait for the current command to finish before touching the generated project or Xcode build directory.

For a build without installation, use `./Scripts/build.sh`. The build output is:

```text
build/DerivedData/Build/Products/Release/db3.app
```

Open that app in Finder, or open [App/DB3.xcodeproj](App/DB3.xcodeproj) in Xcode and run the `db3` scheme. The build command does not launch the application or control the desktop.

`Scripts/prepare-postgres.py` copies the pinned local native libraries into `Vendor/`, adjusts their load paths, and records their license notices. `Dependencies.lock.json` pins the binary input hashes; an intentional dependency update requires auditing the inputs and running the script with `--update-lock`. The generated app embeds all nine native libraries and does **not** require Homebrew on the receiving machine. Build inputs currently use the installed Homebrew distributions; this is a pinned binary packaging workflow, not a source-reproducible libpq build.

The local app uses ad-hoc signing without hardened-runtime library validation, because ad-hoc native libraries have no Developer Team ID. A distribution build must sign the app and every embedded library with the same Developer ID and enable hardened runtime. Developer ID signing, notarization, Intel builds, and App Store distribution are not configured.

## What works

- A native workspace with up to four independent query tabs above the editor/results, menus, keyboard commands, transaction controls, status, and a value inspector. Tabs retain their editor undo history, scroll positions, result column widths, and sessions when switching.
- Connection URL and Manual Input modes, saved connection profiles, passwords in Keychain, verified TLS with custom CA support, and clear connection failures.
- A separate Objects sidebar for tables, views, and materialized views, with server search, schema/kind filters, pagination, refresh, access labels, and **New SELECT Query**.
- A TextKit 2 SQL editor with native undo/find/selection/input methods and bounded background syntax coloring. Use **⌘Return** to run highlighted SQL or the statement at the cursor; **⌘.** cancels work.
- A reusable `NSTableView` grid that loads visible pages asynchronously and sizes columns from content and available width. NULL, empty text, Unicode, and arbitrary-precision numeric text remain distinct.
- PostgreSQL streaming, server-side cancellation before the first row, transaction recovery, notices, and explicit partial/error states.
- A 64 MiB app-wide result-cache budget, partitioned into 16 MiB per worksheet, and a shared 1 GiB temporary spool quota. Evicted rows remain inspectable. The result-storage menu can disable spooling for the next query; memory-only results stop at their limit and remain visibly incomplete.
- CSV export of fetched rows with cancellation and atomic file replacement; SQL files can be opened and saved.
- Native inline table editing and blank-row insertion, exact-value drafts and undo, SQL/parameter previews, conflict review, and searchable foreign-key selection.
- A Theme control first in Settings, with System, Light, and Dark appearances.
- Manual transactions by default; only explicitly classified development connections may opt into Auto mode.
- Automatic preservation of query drafts and tab state on normal quit or workspace-window close, with warnings for uncommitted transactions and running queries.
- An explicitly labeled sample session for trying the UI without a database. Its rows are generated locally and its SQL is not executed on a server.

The first version accepts **one SQL statement per execution**. With no highlighted text, Run finds the statement at the cursor in background work, respecting quoted strings, identifiers, dollar-quoted bodies, nested comments, and parenthesized rule actions. Highlighting takes priority; multi-statement selections are rejected before partial execution. Ambiguous syntax such as a `BEGIN ATOMIC` function body requires selecting the complete statement explicitly. COPY protocol transfers close the session with a clear unsupported-operation message; dedicated COPY transfer UI, detailed schema inspection, code completion, full scripts, row deletion, bulk clipboard editing, and explain visualization remain roadmap work.

Use the **+** on the tab row or **⌘T** (or **⌘N**) for a new query tab. **⌘1–⌘4** select tabs by their current left-to-right position; holding **⌘** shows gray shortcut hints on the tabs. **⌃Tab / ⌃⇧Tab** switch to the next/previous tab, and **⌘W** closes the active tab. Middle-click a tab or click its close button to close it, with the usual unsaved-change and session checks. Drag tabs to reorder them or use their context menu. Sidebar connection selection is independent of query tabs; new tabs inherit the selected connection profile, and **Connect** opens the session explicitly. Switching tabs never reconnects or executes SQL.

Opening a SQL file creates a tab, or selects its existing tab if already open. **⌘S** saves that query and **⌘⇧S** saves it under another path. A dot marks unsaved SQL. Closing an individual dirty tab still asks before discarding it. **⌘⇧W** closes the whole workspace; closing its final query tab instead leaves a fresh disconnected query.

Normal app quit and workspace-window close preserve tab order, titles, SQL drafts and saved baselines, file references, cursor/selection, connection context, and inspector visibility in `~/Library/Application Support/db3/workspace.json`. This private, atomic recovery file is limited to 64 MiB and does not overwrite your SQL files. An unreadable older recovery file is preserved in a private `workspace-unreadable-*.json` backup before a valid new snapshot replaces it. Restored tabs stay disconnected, with no saved results, passwords, live transactions, or automatic execution. Recovery is a snapshot at successful close, not continuous crash autosave or query history. A failed recovery write keeps the workspace open. Uncommitted or failed transactions still warn before rollback/disconnect; **Keep Open** is the default for that warning. Running work also requires a close decision, and changed transaction state is checked again before closing any session.

Selecting a result cell updates the inspector's value without opening the panel. Use the top toolbar's Inspector toggle (or its keyboard command) to show or hide it.

Selecting a sidebar connection loads its committed catalog through one separate metadata session and leaves query tabs untouched. Tables, views, and materialized views appear together with partition labels and advisory access information. The schema dropdown starts at `public`, or the **Default schema** saved in connection properties (available in both URL and manual modes). Choose another discovered schema or **All Schemas** to browse beyond that scope, including schemas outside `search_path`. The saved default only controls the object browser; it does not change SQL name resolution. Existing connections default to `public`. Search treats `%`, `_`, quotes, backslashes, and dots literally and reaches beyond already loaded pages. **New SELECT Query** captures the object's connection and quoted schema/name in a new tab with `LIMIT 1000`; double-clicking an ordinary table prepares an **Edit Table Data** tab, while views and partitioned tables open a SELECT query tab. Single-click only selects an object. Opening an object automatically connects its new tab to the object's database; choose Run to load its data. Restored browser selection offers **Load Objects** without connecting. Catalog refresh cannot see another tab's temporary objects, uncommitted DDL, or session role changes, and never populates a materialized view. Bound projects add module namespaces, a namespace filter and a saved Show Base toggle. Namespace membership is filtered on the server before pagination. SSH profiles remain planned.

## Projects and source metadata

Choose **File → Open Project Folder…** (⇧⌘O), including `~/Projects/odoo`, or reopen a Recent Project. A compact sidebar status opens project details, diagnostics, connection candidates and binding settings. Opening a folder reads files only; it does not connect, run SQL, or execute project code. Generic folders support configuration discovery and manual namespaces. Odoo is the first source adapter; additional frameworks can implement the shared contract.

Review `.env` candidates individually. Development, production and URL groups stay separate, passwords remain masked, and the connection editor starts with certificate and hostname verification. Saving uses the existing optional Keychain flow. Explicitly bind a saved profile and PostgreSQL schema before using source metadata; a changed candidate requires another review and suspends automatic submission. While a project is open, the sidebar and query connection menu show only its bound profiles; project details can bind another saved connection. Closing the project restores the full connection list. SQL tabs keep their captured sessions.

Odoo inspection uses pinned, embedded Tree-sitter C targets, with no Python installation or imports. It resolves safe declarations, constants, aliases, module ownership, stored/computed/related fields and literal choices. Dynamic or ambiguous facts remain unresolved. **Objects → Model Metadata…** shows advisory model/field provenance. PostgreSQL columns, types and constraints remain authoritative. Native enum/source choices have search, exact stored keys, a distinct NULL action, and local staging through the editing preview.

Objects group by defining module; framework tables use **Base**, hidden by default. Use **Assign Namespace** in an object's context menu to save an override in `.db3/project.json`; names, ordering and Base visibility are editable in project details. Credentials, endpoints, bookmarks, profile UUIDs and catalog identity evidence stay outside this portable file. Conflicting external edits and failed saves offer Retry/Reload. Unmatched object assignments remain in the file for explicit revalidation.

FSEvents changes are coalesced with bounded queues, plus focus/wake and periodic reconciliation. Enumeration, parsing, hashing, settings I/O and watcher setup run away from the main actor. Inspection is capped at 2 MiB per file, 50,000 source files and 64 MiB accounted metadata. Larger or incomplete projects visibly report partial coverage; they never silently claim complete metadata. Source changes retain cautious editing restrictions and invalidate mutation previews, including an in-flight Apply before it releases its savepoint or commits.

The embedded parser pins and MIT notices are packaged with the app in `DB3Kit_DB3Projects.bundle`. Native visual/VoiceOver acceptance remains pending; headless tests cover discovery, inspection, bindings, watchers, persistence and transaction fences.

## Edit table data

Run a single-table SELECT that includes its complete primary key, then edit its result cells directly. Column aliases, reordered/subset columns, and duplicate aliases are supported; calculated expressions remain read-only. db3 verifies the displayed base values against the current row before the first edit and captures its version for later conflict checks. **Edit Table Data** in Objects also prepares a bounded full-table query. Joins, grouped/CTE queries, views, partitioned/inherited tables, and unsupported types remain read-only. Existing primary-key and generated/identity values cannot be changed.

Double-click a cell or press Return/F2. Return/Tab stages scalar changes; Escape cancels. Large text/JSON uses a multiline editor with Command-Return to stage. NULL is an explicit action, and exact numeric text is preserved. A foreign-key cell offers **Choose referenced row…**, with server search and complete composite-key staging. **Preview Changes** shows every before/after change, submitted SQL, parameter types/values, and any computed-field warning. Apply always uses the complete preview batch even when its list is filtered.

After running an explicit **Edit Table Data** query, double-click its trailing blank row (marked **+**) to stage a new row, including when the table is empty. Return/F2 works on that row too. Untouched fields use **DEFAULT**; **Set NULL** and an explicitly entered empty string remain distinct. **Use Default** restores an omitted value. Generated and identity fields stay database-supplied; writable fields, including a manually assigned primary key, can be filled in the draft. New rows use the same **Preview Changes → Apply** workflow as updates. Creating or editing a draft sends no database write; INSERT runs only on Apply.

**Manual mode is the default**, including for SELECT statements. Apply leaves a transaction open; Commit or Rollback affects the entire worksheet transaction. Resolve local drafts before either action. Only connections explicitly classified as **Development** in connection properties can opt into per-tab Auto mode; production and unclassified connections never auto-commit. An Auto edit batch still requires **Apply & Commit** from its preview. Nothing commits on cell blur, tab switch, or backgrounding.

Conflicts preserve drafts and offer comparison with current server values and deliberate rebasing. A changed schema, connection, result, or transaction invalidates the editing snapshot; Run explicitly to reload. Applied base values update in their existing result columns; calculated expressions require a rerun to refresh. Quit warns before discarding memory-only grid drafts, and does not include them in the SQL workspace recovery file. CSV export keeps all visible columns, omits any hidden version metadata, and requires resolving local drafts first. Bound project metadata adds stored-computed warnings and source choices; native PostgreSQL enums use catalog labels. ORM execution remains task 08.

## Execution and memory boundaries

Main-actor work is limited to UI and small presentation updates. The PostgreSQL connection, DNS resolution, text analysis, encoding, disk pages, and credential persistence have explicit background boundaries. An awaited result consumer applies backpressure; result ingestion does not launch one task per row or keep all rows in observable state.

Column sizing measures headers and up to 64 rows from each column's first loaded page, using bounded cell previews in background work. Columns fit their measured header/content plus padding, leaving unused space to the right. They shrink when needed to fit the available width and reflow when the window, sidebar, inspector, or scrollbar gutters change, growing back only as far as their content needs. Narrow layouts retain readable minimum widths and allow horizontal scrolling. Double-click a header divider to fit the column on its left using those cached measurements, up to 480 points. Dragging or fitting a column pins its width for the current result; the next query restores automatic sizing. Width changes do not animate. Resizing reuses measurements rather than scanning result data again.

Each worksheet pins a physical PostgreSQL session so transactions and temporary objects persist between commands. A busy session rejects overlapping statements. Cancellation is tied to the executing operation; the session is not reused until recovery completes. An interrupted or failed connection never automatically replays SQL.

The object browser adds at most one catalog session, including opening and closing owners. Schema and kind filters combine with server search. Schema choices include empty non-system schemas and refresh independently of the current filters, with a 5,000-name cap and an explicit notice if truncated. Searches debounce for 200 ms and fetch 500 objects per page, with a 5,000-row / 8 MiB in-memory cache budget and a bounded working page. Searches and refreshes cancel superseded operations, use bound parameters, and enforce a 10-second statement deadline before recovery. Stale rows remain marked out of date with actions disabled. A local 5,500-view fixture measured 11.9 ms for its first 500 objects and 2.4 ms for targeted search; see the [catalog measurement notes](Benchmarks/2026-09-29-catalog-notes.md). These are headless fixture timings, not native sidebar performance measurements.

Application payloads and spool reads have explicit limits. A single exceptionally large PostgreSQL field can still cause a transient driver allocation before storage rejects it; UI truncation is not a hard process-memory bound. The app currently accepts approximately 2 MiB of accounted payload per batch. Long SQL documents over 2 Mi UTF-16 units use plain-text mode. These supported-envelope limits are intentional and should be profiled before increasing them.

Connection passwords are stored only when Keychain saving is selected. Empty CA paths use `/etc/ssl/cert.pem`; this is the macOS PEM root bundle, not Keychain trust overrides. SQL history is not recorded. Temporary result files have private permissions, are removed on close, and have crash-orphan cleanup.

If Keychain cannot read a saved password, db3 asks for a temporary password for that query or browser connection. Entering it bypasses Keychain for that attempt without saving, deleting, or replacing the saved credential. Cancel leaves the connection unchanged; responses remain tied to the tab or browser request that opened the prompt.

New connections open in **Connection URL** mode. Paste a `postgresql://` or `postgres://` URL, review the parsed settings, or switch to **Manual Input** to edit them. URLs are hidden until revealed and are never saved as raw strings; passwords use the same optional Keychain storage as manual connections. If a URL omits its password, the form provides a separate password field.

URLs support one host, IPv6 and Unix sockets, percent-encoded credentials, and the query parameters `host`, `port`, `dbname`, `user`, `password`, `sslmode`, and `sslrootcert`. Supported TLS modes are `verify-full` (the default), `require`, and `disable`. Other options and multiple hosts produce a validation error rather than being silently ignored. URL parsing runs off the main thread and does not connect to a server.

## Verification

```sh
# Fast tests; database integration cases are skipped without a fixture.
./Scripts/test.sh

# Complete suite using disposable local plain/TLS PostgreSQL instances.
# Instances and their files are removed when the script exits.
./Scripts/test.sh --integration

# Read-only signature and dependency-path verification; does not launch the UI.
python3 Scripts/verify-bundle.py
```

The tests cover cancellation and races, failed transactions, network loss, TLS validation, COPY rejection, exact values, bounded backpressure, cache eviction, quotas, corruption, private-file cleanup, and CSV export. Grid/editor tests cover width allocation, resizing, manual overrides, undo isolation, and inactive presentation work. The root Swift package tests the real application models and retained SwiftUI/AppKit tab hosts, including asynchronous files, close decisions, credential races, and per-tab presentation state. These tests use offscreen views without opening or controlling a window. The integration script requires PostgreSQL server tools and an `openssl` command.

The [benchmark harness](Benchmarks/README.md) measures the real driver and disk-backed result store. A recorded Release run on an **M5 Mac with 32 GiB RAM** streamed and spooled one million rows across eight columns in **1.735 seconds**, with **19.9 MiB peak physical footprint** for the headless process. Exact first/last rows survived cache eviction and cancellation/reuse checks passed. See the [report](Benchmarks/2026-09-29-headless-1m.json) and [measurement notes](Benchmarks/2026-09-29-headless-notes.md).

These are individual headless measurements, not app memory, UI latency, or M1 acceptance results. App launch and sample-result display are verified interactively. Editing stress tests, wide-grid scrolling, accessibility, and UI performance budgets still require further verification. Under the workspace instructions, computer control requires fresh explicit permission.

Layout regression check: load sample results, select a cell, and resize the inspector in both directions. Repeat after manually resizing the sidebar, toggling the inspector, and switching worksheets. The sidebar divider must keep its chosen position while the worksheet absorbs inspector width changes. This check passed on macOS 26.5.1; the nested editor/results split is isolated from the outer split's minimum-size calculations to prevent a constraint-update loop during resizing.

## Layout

- `App/DB3App/`: SwiftUI workspace, lifecycle, Keychain, connection profiles, and query coordination.
- `Packages/DB3Kit/`: UI-independent types, PostgreSQL adapter, bounded result store, native editor/grid, tests, and headless benchmark.
- `Tests/DB3WorkbenchTests/` and root `Package.swift`: headless tests of the real application sources, with fake credentials/dialogs/sessions and retained native tab hosts.
- `Scripts/`: dependency preparation, project generation, builds, integration fixtures, and bundle verification.
- `Benchmarks/`: repeatable SQL/editor fixtures and recorded results.
- [Plans/01-scaffold.md](Plans/01-scaffold.md): architecture, decisions, acceptance budgets, and remaining milestones.
- [Plans/02-import-connections.md](Plans/02-import-connections.md): planned Navicat import wizard, connection selection, Keychain passwords, and colors.
- [Plans/03-ssh-tunnels.md](Plans/03-ssh-tunnels.md): planned SSH transport for imported and manually configured PostgreSQL connections.
- [Plans/04-tabs.md](Plans/04-tabs.md): implemented query tabs, document/session lifecycle, verification evidence, and pending interactive checks.
- [Plans/05-objects.md](Plans/05-objects.md): implemented searchable sidebar list of tables, views, and materialized views; pending interactive acceptance checks.
- [Plans/06-edit.md](Plans/06-edit.md): implemented inline editing and blank-row insertion, SQL previews, searchable foreign-key lookups, computed-field warnings, and manual transactions; development may opt into auto-commit, production never does.
- [Plans/07-projects.md](Plans/07-projects.md): implemented folder workspaces, Odoo source inspection, reviewed connection binding, native enum/source choices, background refresh, and portable namespace settings; verification and measured coverage are recorded in the plan.
- [Plans/08-odoo-json-rpc.md](Plans/08-odoo-json-rpc.md): planned Odoo connections with optional PostgreSQL access, JSON-RPC edit previews, guarded atomic batches, and explicit production commits.
- [Plans/09-grid-mode.md](Plans/09-grid-mode.md): planned object grids opened by double-click, with automatic first-page loading, SQL WHERE/ORDER BY conditions, server-side sorting, and bounded paging.
- [Plans/10-copy-paste.md](Plans/10-copy-paste.md): planned Airtable-inspired range/row copy and paste, spreadsheet interchange, single-value fill, and undoable edit batches using the existing preview and transaction rules.
- [Plans/11-terminal.md](Plans/11-terminal.md): planned project-only native terminal tab with Shell, Claude Code, and Codex CLI launch profiles, coordinated shutdown, and stopped restoration.
- [Plans/12-files-explorer.md](Plans/12-files-explorer.md): planned native project Explorer, editable source-file tabs, file operations, explicit saves, and external-change conflict handling.
- [Plans/13-workspace-layout.md](Plans/13-workspace-layout.md): planned side-by-side/stacked tab groups, sidebar and panel controls, terminal docking, and persistent native workspace layout.
- [Plans/14-schema-cache.md](Plans/14-schema-cache.md): planned persistent schema cache, transaction-aware DML/DDL invalidation, batched introspection, and bounded automatic refresh for local and external changes.
- [Plans/15-sql-editor.md](Plans/15-sql-editor.md): planned SQL word wrap and line numbers enabled by default, plus a visible editor/results height handle with per-tab persistence and keyboard resizing.
