# 04 — Query tabs

**Status:** implemented for current direct-connection profiles; Release build and headless verification pass; interactive UI acceptance remains pending.  
**Planning date:** 2026-09-29.  
**Depends on:** the worksheet/session scaffold in [01](01-scaffold.md).  
**Coordinates with:** connection colors/import state in [02](02-import-connections.md), SSH sessions in [03](03-ssh-tunnels.md), and the objects sidebar in [05](05-objects.md).

## Outcome

Move queries out of the left sidebar into a horizontal tab bar above the editor and results. Each query tab owns its SQL, database connection/session, results, messages, and editing state. The sidebar contains connections and, in task 05, a searchable objects list.

The visible structure becomes:

```text
┌─────────────────────┬──────────────────────────────────────────┐
│ Connections         │ Query 1 ×   orders.sql ×   Query 3 ×   + │
│                     ├──────────────────────────────────────────┤
│ Objects [task 05]   │ Connection / transaction controls        │
│ Search objects…     ├──────────────────────────────────────────┤
│ Tables              │ SQL editor                               │
│ Views               ├──────────────────────────────────────────┤
│ Materialized Views  │ Results / Messages                       │
│                     ├──────────────────────────────────────────┤
│                     │ Query status                             │
└─────────────────────┴──────────────────────────────────────────┘
```

The inspector remains optional on the right. The tab bar belongs to the detail area, stays visible while the sidebar is hidden, and does not replace the existing Results / Messages control. These are query tabs inside the current workspace window; detached windows and split editors remain separate work. A subsequent user request adds draft restoration across normal quits, described below.

Retain the current limit of **four open worksheets** for this task. Moving their navigation must not implicitly increase session or result-cache budgets. More disconnected documents than live connections can be a later change with its own admission and memory design.

[11 — Project terminal](11-terminal.md) and [12 — Files explorer](12-files-explorer.md) extend this row with terminal/file tab kinds and separate resource budgets while retaining four database tabs. They replace worksheet-only command fallback with typed routing and create a fresh disconnected query only when all tab kinds are absent. [13 — Workspace layout](13-workspace-layout.md) distributes the same retained tabs across groups without duplicating their documents, connections, or processes; its position shortcuts are local to the active group. These are planned extensions, not current tab behavior.

## Current behavior and integration points

| Location | Existing behavior | Planned change |
| --- | --- | --- |
| `WorkbenchView.swift` | Sidebar contains Connections and Worksheets; detail uses `WorksheetView(...).id(active.id)` | Remove the Worksheets section; add the tab strip and stable per-tab content hosting. |
| `WorkbenchModel.swift` | `worksheets`, `selectedID`, `active`, add/close functions; new titles use current array count | Keep worksheet UUID ownership, add tab actions and independent browser selection, and use noncolliding untitled names. |
| `Worksheet.swift` | Owns SQL/selection, profile, session, query state, result store, and cancellation generation | Add document/presentation state and dirty tracking; retain current session ownership and generation fencing. |
| `SQLTextEditor.swift` | Enables native undo and maintains selection, viewport, and input composition; does not explicitly provide a per-document undo manager | Establish per-tab undo isolation and preserve native editing lifetime across switches; do not reload SQL text just to activate a tab. |
| `ResultsGrid.swift` | Coordinator owns column widths, selection, viewport, and prepared-page work | Preserve per-tab layout/selection while suspending unnecessary offscreen work. |
| `DB3App.swift` | Worksheet/menu commands; app quit checks live queries and transactions | Add tab navigation/close commands and include unsaved SQL in window/app close handling. |

Changing `.id(active.id)` alone is insufficient: recreating the editor/grid can lose native undo history, viewport, and manual column widths even when the `Worksheet` model survives. `WorksheetView` also stores the selected Results / Messages pane in local `@State`; give that state a lifetime tied to the worksheet.

## Tab behavior

[09 — Grid mode](09-grid-mode.md) adds object data tabs to this same tab row and capacity limit. Its explicit double-click/Open Data action connects and reads a bounded first page; the generic query-tab creation rules below continue to prepare SQL without executing it.

- Show a tab for every worksheet in stable array order. Each tab contains a short title, optional connection-color marker, progress/error/transaction indicators, an unsaved-change indicator, and an independently clickable close button.
- Use the file name for a file-backed query and monotonically allocated **Query N** names for untitled queries. Renaming affects the label only; UUID identity, result ownership, and credentials never depend on the title.
- Clicking a tab selects it without executing SQL, reconnecting, resetting results, or cancelling background work. The toolbar, transaction controls, inspector, export action, and status immediately target that tab.
- Middle-clicking a tab closes that specific tab through the same close coordinator as its close button. Closing an inactive tab preserves selection; unsaved SQL and active-session checks still apply.
- Keep connection name and database visible in the active tab's header, with the full endpoint in accessible details/tooltips. A connection color supplements this text and must not be confused with running/error state. Show **No connection** for an unassigned tab.
- Place **+** at the end of the bar and keep generic new-tab controls out of the sidebar. It creates and selects a fresh query tab without copying another tab's result, transaction, or session. Select a profile as described below; opening a tab does not connect automatically.
- Allow in-window reordering by drag and accessible **Move Tab Left/Right** actions. Reordering only changes display order; it never changes the selected UUID or reassigns a session.
- Use bounded tab widths, truncated labels with full-title tooltips, and horizontal scrolling when needed. Keep the selected tab visible after selection/reorder/resize. The add button and close affordance remain reachable at the minimum supported window size.
- Disable creation at the existing four-tab limit and explain how to free a slot. File-open and object actions enforce the same limit before mutating workspace state. Do not close, overwrite, or disconnect another query to make room.

Each pane's controls affect its own content, with descriptive tab labels and consistent navigation. This follows Apple's tab guidance; the exact closeable-query-tab styling is a db3 design choice. [Apple tab views guidance](https://developer.apple.com/design/human-interface-guidelines/tab-views).

### Commands and focus

| Action | Proposed command |
| --- | --- |
| New Query Tab | `⌘T`; preserve existing `⌘N` as an equivalent command |
| Close Query Tab | `⌘W` when the workspace is the command target |
| Next / Previous Query Tab | `⌃Tab` / `⌃⇧Tab`, wrapping in visible order |
| Select Query Tab by Position | `⌘1`–`⌘4` in current left-to-right order; unavailable positions are disabled |
| Open SQL / Save SQL | Keep `⌘O` / `⌘S`, with the file/tab behavior below |
| Run / Cancel | Keep `⌘Return` / `⌘.` for the active tab only |

Expose commands in native menus and tab context menus, with enabled states derived from the intended tab. Avoid global key monitors: text editing, completion of marked text, accessibility, and modal sheets keep normal responder-chain behavior. `⌘W` in an unrelated window must retain its normal meaning. Window-close controls still close the workspace through its close coordinator.

While Command is held, show a gray `⌘1`, `⌘2`, etc. on the right of each tab, before the close button. Reserve space for these hints so titles do not shift; update numbering after reordering or closing tabs, and hide hints when Command is released or the workspace loses activation.

On tab switch, restore the last meaningful responder in that tab; on a newly created query, focus the editor. Switching while an input method is composing text must use native resignation/commit behavior without transferring marked text to another document. A close click on an inactive tab must not briefly select or execute commands in it. VoiceOver announces title, selected state, connection, dirty state, and running/error state; the close control has a distinct label.

## Connection context and task 05 contract

Keep `selectedTabID` (or the current `selectedID` with clearer naming) independent of `selectedBrowserProfileID`. Clicking a connection in the sidebar selects the browser context. It no longer silently calls `connectSaved` against whichever worksheet happens to be active.

- A generic new-tab action chooses the explicitly selected browser profile, otherwise the active tab's profile, otherwise no profile. Copy configuration only; obtain a new session when the user explicitly connects. Display the chosen profile before execution.
- Select a sidebar connection, then use the tab row's **+** or the new-query menu/keyboard commands to create a tab for it without retargeting the existing tab. **Connect** in the tab header operates only on the profile shown there. Editing/choosing a different profile for an existing tab is explicit and preserves busy/transaction guards.
- Task 05's **New SELECT Query** action passes an immutable snapshot of the selected profile, database, schema, and object to `openQueryTab(context:sql:title:)`. The action creates a fresh tab with generated SQL, without running it. Later browser-selection changes cannot retarget that tab or an in-flight connection attempt.
- Switching query tabs leaves browser selection alone. The sidebar and tab each label their own database context; a future **Reveal Connection in Sidebar** action can align them explicitly.
- Saved-profile edits affect future connections. An existing connected tab keeps the configuration snapshot for its live session until the user reconnects; display that distinction when relevant. Imported incomplete/SSH-required profiles retain task 02/03 restrictions.
- Toolbar/menu callbacks and async saves/connections capture a worksheet UUID before awaiting. Allocate a connection-intent generation before any credential lookup or modal edit and revalidate it before connecting; a still-open UUID alone cannot distinguish superseded attempts on the same tab. Revalidate existence/closing state too, and never redirect completion to the tab that became active meanwhile.

Task 04 works with ordinary direct profiles before tasks 02/03 are implemented. It must preserve their additional appearance/provenance/transport fields when those tasks land, without adding separate copies of the profile model.

## State lifetime and resource ownership

Use one retained view host per worksheet UUID, owned by a workspace tab coordinator. A suitable baseline is an `NSTabViewController` with separate `NSHostingController` children and a SwiftUI tab strip; `.unspecified` lets the app provide the tab selector. Create children through the controller API and validate actual view lifetime in a small prototype before adopting the bridge. Apple's API supports child controllers and lazy page loading; it does not by itself prove all of db3's editor/grid state survives. [NSTabViewController](https://developer.apple.com/documentation/appkit/nstabviewcontroller), [tab selector styles](https://developer.apple.com/documentation/appkit/nstabviewcontroller/tabstyle-swift.enum).

Requirements are the same if a simpler retained host passes the prototype:

- Keep each created `NSTextView`, text storage, SQL selection, and editor scroll position until its tab closes. Provide an explicitly isolated document undo manager and verify responder routing after tab switches. Do not swap all documents through one text view or copy complete attributed strings when selecting tabs.
- Keep grid widths, row/cell selection, horizontal/vertical scroll position, Results / Messages selection, and editor/results divider position per tab. The current Results / Messages conditional also removes `ResultsGrid`; retain its native host or restore explicit presentation state when switching output panes, not only query tabs.
- Keep sidebar width and inspector visibility/width as workspace layout state; inspector value, text selection, and scroll belong to the active worksheet's presentation state. Replace the single shared `inspectorSelection` range with per-tab state, clamped/reset when that tab chooses a different value.
- Inactive tabs may finish queries and update their model/status. They do not steal focus, open the inspector, scroll the visible grid, or replace another tab's results. Ensure callbacks from a retained inactive grid cannot change workspace presentation accidentally.
- Hide inactive content from hit testing and accessibility. Pause offscreen viewport loading, speculative page work, and unnecessary presentation updates without cancelling the underlying query or discarding results. Preserve undo history even when reducing background work.
- Retain the 16 MiB result-page cache per worksheet / 64 MiB across four, and the existing shared 1 GiB spool quota. Account separately for native editor storage and grid presentation caches; a result-cache limit is not a whole-app memory guarantee.
- Closing a tab, rather than switching tabs, owns shutdown of its task/session/tunnel lease and result store. Release native view hosts, observers, callbacks, and pending work after coordinated close. No reference cycle should keep a closed query alive.

Keep the existing layout boundary that prevents the inner editor/results split from driving the outer sidebar's minimum-size calculations. Adding the tab host must preserve the current sidebar/inspector resizing fix and the grid's column-width behavior.

## File handling, dirty state, and close

Opening a SQL file creates a tab instead of replacing the active query. First check whether the same file is already open and select that tab, even at capacity; creating another copy is a separate deliberate action. For a new file, reserve an available slot and show a cancellable loading state before reading asynchronously. Disable editing of that loading document and fence completion with its load generation/revision, so a late read cannot overwrite edits or populate a closed/reused slot. At capacity, report the limit without replacing another tab. Report load failure without losing existing SQL. Saving captures the correct document and revision, so switching tabs while the save panel is open cannot save another query under that file name.

Track a saved baseline or equivalent revision-aware document state. Untouched starter text is clean; user edits and newly generated object SQL are unsaved. Undoing exactly back to the baseline clears the indicator. Running a query, fetching rows, changing row selection, or connecting is not a SQL document edit. A completed async save marks only its captured content as saved; later edits remain dirty.

Use one idempotent close coordinator for tab close, window close, and app quit:

1. Identify the target UUID and capture its dirty, busy/exporting, and transaction states. Never substitute the active tab after an await. Prevent duplicate close requests for the same tab.
2. A clean idle tab closes immediately. Otherwise show the applicable unsaved-text and active-session consequences together. Offer **Save and Close**, **Close Without Saving**, and **Keep Open** when SQL is dirty; session-only cases need their own clear close/keep choices. Closing an active or failed transaction explains rollback; closing running work explains cancellation and possible uncertain server outcome.
3. A cancelled or failed save leaves the tab/session intact. If text or session state changes while deciding/saving, revalidate before closing; newly edited text is never discarded based on an old decision. Do not close other tabs while gathering a multi-tab window/quit decision that may be cancelled.
4. After the decision is valid, fence late completions, stop new commands for that tab, cancel owned work, await bounded session/transport shutdown, close its result store, and then remove its host/model. Reflect closing state while teardown runs. Reuse current generation protection and task 03's tunnel cleanup when applicable.
5. Closing the active tab selects its right neighbor, otherwise its left. Closing an inactive tab leaves selection unchanged. Closing the final tab creates one fresh disconnected query so the workspace remains useful. Window close/app quit do not create replacement tabs.

The original layout scope deferred restoration. The subsequent explicit user request now authorizes automatic draft preservation on normal quit and workspace-window close. Preserve editor text and tab state in a private atomic recovery document, without overwriting SQL files. Restore disconnected, without executing SQL or retaining results/credentials/transactions. Suppress dirty-SQL save prompts only for whole-workspace close; retain explicit alerts for running work and open/failed transactions, gather all decisions before closing any tab, and revalidate after the asynchronous recovery write. A failed write keeps tabs open. Continuous crash autosave and SQL history remain outside scope.

### Subsequent editor and recovery changes

- Run executes highlighted SQL or the statement containing the cursor. Statement extraction runs off the main actor and handles PostgreSQL quoting/comments; the driver's one-statement rule remains enforced.
- Cell selection updates inspector content without opening it. Visibility changes only through its explicit toggle/command or restoration of the saved user choice.
- Quit/window close saves up to four tabs, order, selection, titles, SQL and saved baselines, file references, connection/object context, cursor position, output-pane choice, sample-session identity, and inspector visibility. On next launch, tabs and browser context are restored without database connections. There are no persisted result pages or live transactions.
- `WorkspaceRecovery.swift` performs JSON validation/encoding and atomic private-file I/O off the main actor. Its versioned recovery file is bounded to 64 MiB; invalid or oversized drafts are never truncated. Recovery failure prevents closing the current workspace.
- Uncommitted and failed transactions show an explicit rollback warning with **Keep Open** as the default. No quit path commits a transaction. Individual dirty-tab close still offers the original save/discard/keep choices.

## Implementation stages

### 0. Lock down model and view lifetime

- [x] Add UUID-based tab actions, independent browser selection, unique untitled labels, and immutable query-opening context.
- [x] Prototype retained editor/grid hosts; offscreen tests prove undo, viewport, manual widths, marked-text preservation, and result state across repeated switches. Interactive input-method/focus behavior remains in the acceptance checks below.
- [x] Choose the host implementation from that evidence; keep AppKit ownership outside `DB3Core`.

### 1. Move navigation into tabs

- [x] Add `QueryTabBar` and a retained `QueryTabContentHost`; remove worksheet navigation from the sidebar.
- [x] Wire selection, create, close, reorder, keyboard commands, focus, accessibility, overflow, and per-tab indicators. Live interaction verification remains pending.
- [x] Route all worksheet commands by captured UUID and preserve inactive-query behavior and existing split/grid layout constraints.

### 2. Complete document and connection behavior

- [x] Add dirty/file identity state, safe Open/Save behavior, and a unified tab/window/quit close coordinator.
- [x] Replace sidebar-click retargeting with explicit browser selection/new-query actions and the task 05 query-opening contract.
- [ ] Verify imported color/status and SSH compatibility when tasks 02/03 exist. Current profile snapshots are preserved as whole values; no extra session slots or duplicate transport/profile schema were introduced.

### 3. Verify and document

- [x] Add focused model/lifecycle tests with fake sessions and offscreen AppKit tests for state preservation. A root Swift package compiles the actual app sources (excluding its entry point) for tests; Xcode still builds the application bundle.
- [x] Regenerate the Xcode project for new app files through `Scripts/generate-project.py`, run the relevant test suite, and build the local app.
- [ ] Verify the native layout, focus, commands, input methods, and split resizing; update README terminology and usage.

## Acceptance and verification

- Queries appear only as tabs above the editor/results; the sidebar has no Worksheets section. Connections remain usable, with room for task 05's objects/search.
- With four distinct queries, switching/reordering preserves SQL, undo/redo, selection, scroll, grid widths, Results / Messages, inspector selection, and transaction/session identity. Results from a busy inactive tab never appear in the active one.
- Run a delayed query in one tab while editing and running another. Run, Cancel, transaction actions, export, Open/Save completions, and close affect exactly their captured target; switching tabs creates no network traffic or SQL execution.
- Test first/middle/last/inactive-tab close, final-tab replacement, duplicate close requests, dirty undo-to-baseline, save failure/cancellation, edits during save, active query/export, failed transaction, and window/quit cancellation. No discarded SQL or partially closed workspace after choosing Keep Open.
- Selecting a different sidebar connection or object never retargets a tab. Explicit new queries inherit the displayed captured context; creation at capacity changes nothing else. Unknown credentials/unsupported SSH never fall back to another profile or direct connection.
- Verify long/identical/Unicode titles, minimum window width, hidden sidebar, keyboard-only navigation, VoiceOver, light/dark appearance, contrast settings, and input-method composition across switches.
- Repeat the existing inspector/sidebar divider and grid sizing checks across tabs. Measure repeated switches during a large result; investigate app-controlled main-thread slices over 50 ms and retained-host memory growth. Budgets are targets to measure, not acceptance claims already achieved.
- Closing a tab releases its session, native hosts, observers, and spool files; switching away does not. Four tabs retain the existing result-cache/spool limits, and repeated open/close cycles do not accumulate work or memory.

Run headless tests/builds first. The current user instructions authorize local db3 build, bundle verification, and CLI launch/normal quit/restart without repeated approval. Screenshots, UI-state inspection, and mouse/keyboard automation still require fresh explicit permission immediately before computer control begins or resumes.

## Implementation record — 2026-09-29

The workspace now uses a horizontal SwiftUI tab strip and retained `NSHostingController` pages in a frame-based AppKit container. Only the active page is attached; editor/grid activity flags suspend offscreen presentation work. Each editor has its own undo manager, the grid survives Results / Messages switches, and the inspector retains per-query selection/scroll. Offscreen host tests verify native identity, nonzero scroll positions, manual column widths, divider position, undo isolation, and closed-host/coordinator cleanup.

The document model separates browser selection from query context, keeps four worksheet slots, handles file-open/save and connection-intent races, and gathers all close decisions before shutting down any workspace session. File identity resolution uses a dedicated utility queue. The menu/window lifecycle uses the same close coordinator; ordinary tab selection does not read credentials or touch a network session. Sample data opens a separate tab when necessary to preserve unsaved SQL.

Tab controls now include middle-click close and native `⌘1`–`⌘4` position shortcuts. Holding Command shows gray hints before each close button without shifting titles; hints resynchronize when the workspace becomes active. The generic new-tab button lives on the tab row, with sidebar new-tab controls removed. Offscreen mouse-event tests cover event routing, release outside the tab, and cancelling/confirming close on an inactive dirty tab. The application suite passes 49 tests after these changes, and the Release build and bundle verification pass. Live keyboard and visual checks remain pending.

The Release bundle builds with a valid ad-hoc signature and nine embedded native libraries, without Homebrew/workspace load paths. The driver/result/editor/grid suite passes with disposable plain/TLS PostgreSQL fixtures; the app suite passes using fake persistence, credentials, dialogs, and sessions. Run `./Scripts/test.sh --integration` for both suites or `swift test --package-path .` for application checks alone.

No screenshots or computer-controlled UI session were used for this implementation. Live keyboard/menu/focus, drag, VoiceOver, input-method, narrow-window, and visual resize checks remain unverified; offscreen tests do not establish whole-app UI performance or memory acceptance. Imported color/SSH integration awaits tasks 02/03, and object browsing remains task 05.
