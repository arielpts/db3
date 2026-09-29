# 13 — Workspace layout and split tab groups

**Status:** planned; no implementation in this task.  
**Planning date:** 2026-09-29.  
**Depends on:** retained tab hosts and close/recovery behavior in [04](04-tabs.md).  
**Coordinates with:** [07 — Projects](07-projects.md), [09 — Grid mode](09-grid-mode.md), [11 — Project terminal](11-terminal.md), and [12 — Files explorer](12-files-explorer.md).

## Outcome

Arrange db3 content side by side or above and below, with native controls to show the left sidebar, bottom panel, and right inspector. A typical project layout has source or SQL on the left and a Claude Code or Codex terminal on the right. Another keeps two database tabs visible for comparison. Each group has its own tab strip and selection; one group or panel owns the current command target.

The supplied screenshot guides the compact toolbar: **Layout**, **Primary Sidebar**, **Bottom Panel**, **Secondary Sidebar**, and **Settings**. VS Code distinguishes editor groups from surrounding sidebars and its panel; use that distinction to make db3's controls predictable. The specific scope and rules below are db3 design decisions, implemented with SwiftUI/AppKit rather than VS Code assets or an extension host. [VS Code custom layout](https://code.visualstudio.com/docs/configure/custom-layout).

Split groups work for database tabs without a project. Files and terminals keep their project-only scope from tasks 11/12. This task introduces no database connections, terminal processes, assistant integrations, or file permissions merely by changing the layout.

## Zones and toolbar

| Control / zone | Content and behavior |
| --- | --- |
| Layout menu | Single Group, Two Columns, Two Rows, Grid (2×2), Split Group Right/Below, Merge All Groups, and Reset Layout. Show a small native diagram beside each preset. |
| Primary Sidebar toggle | Show/hide the existing left region. Within it, an **Explorer / Databases** selector keeps task 12's project tree and the existing Connections/Objects interface reachable. Preserve each selection, search, and scroll position. |
| Bottom Panel toggle | Show/hide a separate dock region beneath the editor groups. Its first supported content is the existing project terminal, moved explicitly from a tab. |
| Secondary Sidebar toggle | Show/hide the existing value inspector on the right. Label its tooltip **Toggle Inspector**; no additional assistant or arbitrary tool sidebar is implied. |
| Settings | Open db3's existing native Settings scene. Layout controls also remain in the View menu. |

Use SF Symbols or small app-owned vector shapes with consistent hit areas, native tooltips, accessibility labels, and a visible pressed state. Preserve the usual window traffic lights and draggable titlebar area. Sidebar toggles show visibility, not which region has keyboard focus. At narrow widths, move lesser-used actions into a native overflow menu without removing keyboard access.

The primary sidebar spans the workspace's content height. The inspector does likewise on the right. The bottom panel spans only the editor area between them. Each database tab retains its own internal SQL/results split: **Results / Messages belongs to its database tab**, not the new workspace panel. File documents do not inherit query controls or results merely because they share a group.

Task [15 — SQL editor](15-sql-editor.md) improves that internal split with a visible height handle and per-worksheet ratio, alongside default word wrap and line numbers. Coordinate pane minimums and recovery persistence; moving a worksheet between groups preserves its editor/results ratio.

Explorer remains unavailable without a project; Databases stays usable. Closing a project selects Databases if Explorer was displayed. Showing an empty inspector displays an appropriate empty state; it must not reveal another group's remembered result value. Toggling visibility never initiates SQL, filesystem indexing, shell startup, or an assistant run.

## Groups, identity, and capacity

Represent the editor area as a bounded split tree. A leaf is a stable group UUID with ordered tab IDs and an optional selected tab ID. A branch has a stable identity, a horizontal or vertical arrangement, a normalized divider ratio, and two children. Use explicit **side by side** and **above/below** labels in UI where axis terminology could be ambiguous. Limit the workspace to **four groups**, including temporarily empty ones.

Keep one central registry of typed tabs: database worksheet/grid, project file document, and project terminal. A tab is owned by exactly one editor group or, for the terminal only, the bottom panel. Group membership is presentation state; the tab's model, native host, connection, document identity, undo manager, and process never belong to the group.

- Four database tabs remain the existing **app-wide** limit, across all groups, including task 09's grid tabs. A second group does not grant four additional connections or result caches.
- Task 12's twelve file-document slots are separate and counted across groups; its file-size and aggregate-memory limits still apply.
- Task 11 permits one terminal session for the active project. Moving it to another group or the panel does not reserve another terminal slot.
- Preserve the existing 16 MiB resident result cache per database tab, 64 MiB aggregate, and shared 1 GiB spool quota. Additional visible views cannot multiply these budgets. File and terminal budgets remain separately enforced.

All operations validate the target group/tab and layout generation before committing a mutation. Restore/reorder/drag code cannot introduce duplicate ownership, orphan a live host, or exceed capacity through an intermediate state. Use one atomic layout mutation for a move, then update view attachment.

## Splitting, moving, and opening

**Split Group Right** and **Split Group Below** create an empty adjacent group and focus its placeholder. The original tabs stay in their group. The placeholder offers New Query, Open Project File, and Move Tab Here where applicable; creating content still follows each type's admission rules. This deliberately makes splitting a layout operation with no duplicate SQL connection, running process, or document buffer.

Provide **Move Tab to New Group Right/Below** in each tab's context menu. It combines group creation and moving that exact tab. A tab dragged onto a group's middle moves into its tab strip; dropping on a highlighted edge creates a group and moves the tab there. Drop feedback identifies the destination before release. Escape cancels without mutation. Do not copy tabs with modifier keys in this slice; disable invalid drops with a clear explanation at four groups or insufficient space.

Presets rearrange existing groups when their number permits. Increasing the group count adds empty groups; decreasing it merges excess groups into retained groups in visual reading order, preserving tab order and content. Single Group and Merge All Groups merge editor-group tabs into the active group; a docked terminal stays docked. Reset Layout also restores zone sizes and visibility defaults, without closing content or resetting an editor's SQL/results divider.

Moving the only tab out of a populated group removes its empty source group and collapses the redundant branch, except when splitting the workspace's previously sole group: retain that original empty group as an opening destination. Explicitly created empty groups remain until filled or closed. **Close Group** merges its tabs into the nearest surviving group; it is disabled for the sole group. **Close All Tabs in Group…** gathers all required close decisions before closing anything. Cancelling preserves the group and its contents. Following task 11's mixed-tab policy, create one disconnected query only when the entire workspace has no tabs, counting a docked terminal. Layout operations never allocate replacement queries.

New content opens in the active editor group. If focus is in the bottom panel, use the last active editor group. Selecting an already-open file, object grid, or project terminal reveals its existing location; it does not silently move or duplicate it. Explorer's **Open to the Side** creates a new adjacent group for a new document, but an already-open document is revealed where it lives. Explain that distinction in the menu help. Simultaneous views of the same document are deferred: they require a separate view identity and shared edit/undo design.

## Terminal placement

The terminal remains an ordinary editor tab by default, including Shell, Claude Code, and Codex modes from task 11. Add explicit **Move Terminal to Bottom Panel** and **Move Terminal to Editor Group** actions. Reparent the same native host and PTY session; retain transcript, selection, running command, and project binding. Never send input, restart a CLI, or copy its screen contents to simulate the move.

The panel toggle only changes visibility. If no terminal is docked, the visible panel offers **Move Project Terminal Here** when one exists or **Open Project Terminal Here** when a project is open. The latter is an explicit terminal launch action governed by task 11. Without a project, show the project requirement and keep launch disabled. Hiding the panel preserves its process; closing the terminal invokes task 11's process-close handling. Moving it back targets the last active editor group and hides the now-empty panel.

## Focus and command routing

Replace assumptions of a single `selectedID` with `activeGroupID`, per-group selection, last active editor group, and a typed active command context. The present `WorkbenchModel.active` falls back to the first worksheet. That fallback is unsafe when a file, terminal, empty group, or panel is focused: remove it from user command dispatch rather than mapping non-database content to an invisible query.

Clicking or keyboard-focusing an inactive visible group activates it before its editor/grid action executes. Each group has a visible focus border and an accessible name. Only the active database context supplies Run, Cancel Query, transaction, export, and inspector actions. Files supply file Save/Save As; the terminal supplies its own selection, copy/paste, and input handling. `⌘Return`, `⌘.`, and database toolbar actions must never execute or cancel hidden SQL while a terminal/file is active.

Use `⌃Tab` / `⌃⇧Tab` within the active editor group and extend numbered selection to `⌘1`–`⌘9` for its first nine mixed tabs, disabling absent positions. Later tabs remain reachable through cycling, overflow, and the tab menu. Add native View commands for Focus Next/Previous Group, Focus Group 1–4, Split Right/Below, Move Tab to Group, and visibility toggles. Validate additional shortcuts against native editing and terminal applications before assigning them. Every drag operation has a menu equivalent.

Sidebar interactions retain their own browser/file selection and do not change a database tab's profile. Inspector interaction keeps the captured source tab as its command context. Focusing a terminal panel suppresses database actions and inspector values until a database context is active again. Async callbacks capture tab IDs and source revisions, never whichever group happens to be active on completion.

Preserve native responder-chain editing, undo, marked text, and modal behavior. A native editor that refuses resignation prevents the corresponding move/activation; reconcile layout without losing its draft. Move focus to the nearest surviving group when removing a focused group and restore the last meaningful responder per tab. Background query completion and terminal output cannot activate a group. [Apple NSResponder](https://developer.apple.com/documentation/appkit/nsresponder).

## Native hosting and resizing

Extend `QueryViewHosts` into a typed retained-host registry, still keyed by tab identity. `QueryTabContentHost` becomes a group-specific container whose explicit inputs identify its selected tab and presentation activity. One native content host may attach to only one container at a time. Retain offscreen hosts for undo/view state; detach them from hit testing and accessibility.

Prototype nested `NSSplitViewController`/`NSSplitViewItem` containers for the split tree, with SwiftUI group chrome and the existing native page controllers. Apple's split controller provides native divider management; validate db3's nested constraints and host lifetime before selecting the bridge. Preserve the current frame-based boundary that stops inner editor/results sizing from forcing the outer sidebar widths. [Apple NSSplitViewController](https://developer.apple.com/documentation/appkit/nssplitviewcontroller).

Start with a minimum editor-group content area of 420 × 240 points, primary sidebar width 210–320, inspector width 240–400, and panel height at least 160. Validate these proposals with realistic database controls and terminal rows before freezing them. Clamp divider ratios to fit all visible descendants and keep tab-strip overflow reachable. Resize the terminal PTY using its measured cell dimensions through task 11's existing path; coalesce resize events without restarting it.

Enable a new split only when the resulting groups fit. On a smaller restored window or later resize, use a temporary compact presentation showing the active group and an explicit group switcher; preserve the complete split tree and selected tabs for expansion. Do not close groups, discard ratios, or create an impossible minimum window size. The compact state is visibly explained and keyboard-accessible. Hidden sidebars/panel retain their last usable size. Provide Equalize Groups for predictable recovery after manual resizing.

Several selected group tabs may be visible simultaneously. Separate **visible**, **focused**, and **background** activity: every visible grid may load its bounded viewport, but only the focused context drives global commands. Inactive tabs within a group remain suspended as in task 04. Closing a tab still owns its cleanup; resizing, merging, hiding, and moving do not.

## Persistence and project transitions

Extend the private versioned workspace recovery document with stable tab references, the bounded split tree, group selections, last active group, terminal placement descriptor, zone visibility, and clamped sizes. Coordinate one schema/migration across tasks 09/11/12/13; do not independently bump the same SQL-only format. Migrate old snapshots into one group in existing tab order, preserving selection and inspector visibility.

Layout state belongs in private Application Support, not the project's portable `.db3/project.json`. Preserve the current recovery size limit and atomic-write/failure policy; do not serialize results, live connections, transactions, terminal buffers, credentials, or assistant transcripts. Restore terminal placement as task 11's stopped placeholder, never a running process. Files use task 12's reference-only recovery after its explicit dirty-file close decisions; no source contents are persisted here.

Validate tree depth/count, finite ratios, unique IDs, ownership, selected IDs, and typed tab references before attachment. Salvage valid documents into one group when layout metadata alone is malformed; report the reset. Unsupported newer versions or invalid document data follow recovery error handling rather than silently discarding drafts.

Project switch/close first gathers task 11's terminal and task 12's file decisions through the shared project-close coordinator. On cancellation, retain the old project and layout. After success remove only the closed project tabs/panel content, collapse resulting empty groups, and preserve database tabs and sessions. Project lifecycle cannot retarget an existing terminal to a new directory or disturb an unrelated transaction.

## Delivery and acceptance

1. Implement and test the typed tab/group model, atomic moves, focus routing, and recovery migration before exposing split controls.
2. Prototype retained hosts in two groups; prove native lifetime and constraints, then deliver split tree, presets, resizing, and keyboard commands.
3. Add screenshot-inspired zone controls, sidebar modes, terminal docking, and compact-window behavior.
4. Integrate close/project transitions and restoration; run the native build and targeted lifecycle tests. Interactive checks follow the workspace's computer-control permission rules.

- [ ] SQL + SQL, source + SQL, source + Claude/Codex, stacked groups, and a 2×2 layout preserve independent selections and exact tab ownership.
- [ ] Splitting/moving/merging/docking never connects, runs SQL, clones a document, spawns a process, or changes transaction state. The four database, twelve file, one terminal, and four group bounds hold throughout.
- [ ] Native undo, IME composition, SQL/results divider, grid widths/selection/scroll, file selection, terminal transcript, and process identity survive repeated moves and visibility changes.
- [ ] Run/Cancel/Save/Close/Copy/Paste target the intended visible content after mouse and keyboard focus changes, including empty groups, inspector, sidebar, modal sheets, and docked terminal. No hidden SQL receives commands.
- [ ] Visible grids keep loading within shared budgets; hidden hosts do not perform presentation work or appear in accessibility. Async completions cannot steal focus or publish into another group.
- [ ] Drag cancellation, group-capacity rejection, compact mode, small screens, large text, sidebar toggles, divider changes, and native toolbar overflow remain usable with VoiceOver and keyboard alone.
- [ ] Group close cancellation is atomic; project-close cancellation preserves all content. Approved close releases each session/host once, and moving never triggers close cleanup.
- [ ] Old recovery files migrate; malformed layouts salvage valid documents; unknown versions fail safely. Restoration starts no SQL or process, preserves SQL drafts under their existing policy, restores source-file references under task 12's explicit-save policy, and leaves every valid tab reachable.

Detached windows, arbitrary tool docking, more than four groups, simultaneous duplicate document views, and a full VS Code command/extension system remain outside this task.
