# db3

A native PostgreSQL workbench for **macOS 26+**, built with SwiftUI, AppKit, and an asynchronous `libpq` driver. The interface takes workflow ideas from Navicat and Allround Automations' PL/SQL Developer while remaining PostgreSQL-specific.

**Status:** the native scaffold is implemented and builds as an Apple Silicon macOS application. Driver, storage, TLS, and packaging have headless verification. Basic app launch and a 10,000-row sample query are verified interactively on macOS 26.5.1. Broader UI acceptance checks and the workbench roadmap remain open in the [scaffold plan](Plans/01-scaffold.md).

## Build and run

The verified build environment is Xcode **26.6**, Swift **6.3.3**, and PostgreSQL/libpq **17.9** on macOS 26.5.1. Select the full Xcode installation with `xcode-select`. `pg_config` must point to PostgreSQL 17.9 on the build machine.

```sh
./Scripts/build.sh
```

The app is written to:

```text
build/DerivedData/Build/Products/Release/db3.app
```

Open that app in Finder, or open [App/DB3.xcodeproj](App/DB3.xcodeproj) in Xcode and run the `db3` scheme. The build command does not launch the application or control the desktop.

`Scripts/prepare-postgres.py` copies the pinned local native libraries into `Vendor/`, adjusts their load paths, and records their license notices. `Dependencies.lock.json` pins the binary input hashes; an intentional dependency update requires auditing the inputs and running the script with `--update-lock`. The generated app embeds all nine native libraries and does **not** require Homebrew on the receiving machine. Build inputs currently use the installed Homebrew distributions; this is a pinned binary packaging workflow, not a source-reproducible libpq build.

The local app uses ad-hoc signing without hardened-runtime library validation, because ad-hoc native libraries have no Developer Team ID. A distribution build must sign the app and every embedded library with the same Developer ID and enable hardened runtime. Developer ID signing, notarization, Intel builds, and App Store distribution are not configured.

## What works

- A native workspace with up to four independent, lazily connected worksheets, menus, keyboard commands, transaction controls, status, and a value inspector.
- Connection URL and Manual Input modes, saved connection profiles, passwords in Keychain, verified TLS with custom CA support, and clear connection failures.
- A TextKit 2 SQL editor with native undo/find/selection/input methods and bounded background syntax coloring. Use **⌘Return** to run a selection or the editor's single statement; **⌘.** cancels work.
- A reusable `NSTableView` grid that loads visible pages asynchronously and sizes columns from content and available width. NULL, empty text, Unicode, and arbitrary-precision numeric text remain distinct.
- PostgreSQL streaming, server-side cancellation before the first row, transaction recovery, notices, and explicit partial/error states.
- A 64 MiB app-wide result-cache budget, partitioned into 16 MiB per worksheet, and a shared 1 GiB temporary spool quota. Evicted rows remain inspectable. The result-storage menu can disable spooling for the next query; memory-only results stop at their limit and remain visibly incomplete.
- CSV export of fetched rows with cancellation and atomic file replacement; SQL files can be opened and saved.
- An explicitly labeled sample session for trying the UI without a database. Its rows are generated locally and its SQL is not executed on a server.

The first version accepts **one SQL statement per execution**. Multi-statement selections are rejected before partial execution. COPY protocol transfers close the session with a clear unsupported-operation message; dedicated COPY transfer UI is a later feature. Schema browsing, code completion, full scripts, editable tables, explain visualization, and workspace restoration remain roadmap work.

## Execution and memory boundaries

Main-actor work is limited to UI and small presentation updates. The PostgreSQL connection, DNS resolution, text analysis, encoding, disk pages, and credential persistence have explicit background boundaries. An awaited result consumer applies backpressure; result ingestion does not launch one task per row or keep all rows in observable state.

Column sizing measures headers and up to 64 rows from each column's first loaded page, using bounded cell previews in background work. Columns fit their measured header/content plus padding, leaving unused space to the right. They shrink when needed to fit the available width and reflow when the window, sidebar, inspector, or scrollbar gutters change, growing back only as far as their content needs. Narrow layouts retain readable minimum widths and allow horizontal scrolling. Double-click a header divider to fit the column on its left using those cached measurements, up to 480 points. Dragging or fitting a column pins its width for the current result; the next query restores automatic sizing. Width changes do not animate. Resizing reuses measurements rather than scanning result data again.

Each worksheet pins a physical PostgreSQL session so transactions and temporary objects persist between commands. A busy session rejects overlapping statements. Cancellation is tied to the executing operation; the session is not reused until recovery completes. An interrupted or failed connection never automatically replays SQL.

Application payloads and spool reads have explicit limits. A single exceptionally large PostgreSQL field can still cause a transient driver allocation before storage rejects it; UI truncation is not a hard process-memory bound. The app currently accepts approximately 2 MiB of accounted payload per batch. Long SQL documents over 2 Mi UTF-16 units use plain-text mode. These supported-envelope limits are intentional and should be profiled before increasing them.

Connection passwords are stored only when Keychain saving is selected. Empty CA paths use `/etc/ssl/cert.pem`; this is the macOS PEM root bundle, not Keychain trust overrides. SQL history is not recorded. Temporary result files have private permissions, are removed on close, and have crash-orphan cleanup.

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

The tests cover cancellation and races, failed transactions, network loss, TLS validation, COPY rejection, exact values, bounded backpressure, cache eviction, quotas, corruption, private-file cleanup, and CSV export. Grid tests cover width allocation and native AppKit resizing, scrollbar gutters, manual overrides, and result resets using views offscreen without opening or controlling a window. The integration script requires PostgreSQL server tools and an `openssl` command.

The [benchmark harness](Benchmarks/README.md) measures the real driver and disk-backed result store. A recorded Release run on an **M5 Mac with 32 GiB RAM** streamed and spooled one million rows across eight columns in **1.735 seconds**, with **19.9 MiB peak physical footprint** for the headless process. Exact first/last rows survived cache eviction and cancellation/reuse checks passed. See the [report](Benchmarks/2026-09-29-headless-1m.json) and [measurement notes](Benchmarks/2026-09-29-headless-notes.md).

These are individual headless measurements, not app memory, UI latency, or M1 acceptance results. App launch and sample-result display are verified interactively. Editing stress tests, wide-grid scrolling, accessibility, and UI performance budgets still require further verification. Under the workspace instructions, computer control requires fresh explicit permission.

Layout regression check: load sample results, select a cell, and resize the inspector in both directions. Repeat after manually resizing the sidebar, toggling the inspector, and switching worksheets. The sidebar divider must keep its chosen position while the worksheet absorbs inspector width changes. This check passed on macOS 26.5.1; the nested editor/results split is isolated from the outer split's minimum-size calculations to prevent a constraint-update loop during resizing.

## Layout

- `App/DB3App/`: SwiftUI workspace, lifecycle, Keychain, connection profiles, and query coordination.
- `Packages/DB3Kit/`: UI-independent types, PostgreSQL adapter, bounded result store, native editor/grid, tests, and headless benchmark.
- `Scripts/`: dependency preparation, project generation, builds, integration fixtures, and bundle verification.
- `Benchmarks/`: repeatable SQL/editor fixtures and recorded results.
- [Plans/01-scaffold.md](Plans/01-scaffold.md): architecture, decisions, acceptance budgets, and remaining milestones.
- [Plans/02-import-connections.md](Plans/02-import-connections.md): planned Navicat import wizard, connection selection, Keychain passwords, and colors.
- [Plans/03-ssh-tunnels.md](Plans/03-ssh-tunnels.md): planned SSH transport for imported and manually configured PostgreSQL connections.
