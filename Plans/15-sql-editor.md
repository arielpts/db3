# 15 — SQL editor wrapping, line numbers, and resize handle

**Status:** planned; no implementation in this task.
**Planning date:** 2026-09-29.
**Depends on:** the native editor in [01 — Scaffold](01-scaffold.md) and retained worksheet hosts in [04 — Tabs](04-tabs.md).
**Coordinates with:** [09 — Grid mode](09-grid-mode.md), [12 — Files explorer](12-files-explorer.md), and [13 — Workspace layout](13-workspace-layout.md).

## Outcome

Make SQL worksheets easier to read and arrange:

- **Word wrap on by default**, so long SQL lines fit the editor width.
- **Line numbers on by default**, in a gutter aligned with the source text.
- A visible, easy-to-grab **height resize handle between the SQL editor and Results / Messages**, letting the user give either pane more room.

These improvements apply to SQL worksheets with or without a project, including Edit Table Data worksheets. They change presentation only: wrapping, line numbering, and resizing never modify or execute SQL, mark a document dirty, change transaction state, or apply grid drafts.

## Existing implementation

`Packages/DB3Kit/Sources/DB3Editor/SQLTextEditor.swift` already owns a native TextKit 2 `NSTextView`, per-document undo, selection binding, marked-text handling, find, and bounded syntax highlighting. Its current configuration enables horizontal scrolling/resizing and an effectively unlimited text-container width; it has no line-number gutter.

`App/DB3App/WorksheetView.swift` already places the editor above Results / Messages in a `VSplitView`, with current minimum heights of 180 and 220 points. This task improves that divider's visibility and usability rather than adding a second splitter. `QueryHostTests` already verifies that native views, editor/grid scroll positions, undo, and the divider position survive tab switches.

`QueryInspectorView` also uses `SQLTextEditor` to display read-only cell values. Add explicit presentation options at the worksheet call site so SQL-editor preferences do not inadvertently add a gutter or change wrapping in the value inspector. Task 12's future source editor can reuse the underlying components through its own options.

## Word wrap

Provide an app-wide **Word Wrap** preference, enabled when no preference has been saved. Expose it in a **SQL Editor** section in Settings and as a checked **View → Word Wrap** command when a SQL worksheet is active. Keep **Theme** as the first Settings control. An explicit saved choice to disable wrapping survives relaunch; opening an older workspace adopts the default only if no choice exists.

When enabled, constrain the text container to the available text width after subtracting the gutter and insets, disable horizontal document growth, and hide the horizontal scrollbar. Use soft wrapping at natural word boundaries, with character fallback for long identifiers, URLs, literals, or other unbroken text. Vertical scrolling remains native. When disabled, restore horizontal scrolling and unwrapped lines. Never insert newline characters or run a SQL formatter to make the text fit.

Update the retained editor in place. Preserve selection, caret, marked text, native undo/redo, find state, and the logical source position at the top of the viewport. Keep the caret visible when layout changes. Window/sidebar/inspector resizing and gutter-width changes must recompute the available width without a resize-feedback loop. Defer any disruptive presentation update during active IME composition rather than committing or cancelling the user's input.

Keep statement-at-cursor execution and selection execution based on the original UTF-16 source ranges. A visually wrapped SQL statement is still the same statement, and copied/saved text has exactly the same content as before the layout change.

## Line-number gutter

Provide an app-wide **Show Line Numbers** preference, enabled by default, beside Word Wrap in Settings and in the worksheet's View menu. Draw the gutter separately from the text storage; numbers are not selectable SQL, copied text, saved content, or part of the undo stack.

- Count **logical source lines**, starting at 1. Soft-wrapped continuation fragments do not receive new numbers; show the number beside the first visual fragment of its source line. An empty document displays line 1, and a trailing newline creates the next empty numbered line.
- Treat CRLF as one line ending and cover LF/CR and supported native line-separator behavior explicitly. Map offsets using the same UTF-16 conventions as the editor so emoji, combining characters, and non-ASCII SQL cannot shift numbers or execution ranges.
- Use a monospaced digit font, right alignment, restrained contrast, and padding. Size the gutter for the document's line-count digits; avoid width oscillation while scrolling. Respect font-size changes and Light/Dark/System appearance. A subtle current-line-number emphasis is sufficient; no breakpoint controls are added.
- Keep the gutter pinned horizontally and aligned with vertically scrolled text, text-container insets, wrapped fragments, and the final empty line. Redraw visible line numbers plus a small margin instead of allocating a view per line.
- Expose useful line information through the editor's accessibility behavior without turning every offscreen line number into a separate accessibility element. The gutter must not intercept native text selection, scrolling, find, or keyboard editing.

Implement the gutter using TextKit 2 layout/viewport information and a native drawing view or ruler. Prototype visible-fragment alignment before choosing the bridge. Do not force legacy TextKit compatibility or full-document layout merely to draw numbers. Maintain an incrementally updated line-start index, with generation checks for any background rebuild; scrolling should query that index rather than repeatedly scanning from the beginning of the document. Existing huge-file/plain-text behavior and highlighting limits remain intact.

## Editor/results height handle

Place one horizontal divider between the editor's SQL status strip and the Results / Messages toolbar. Show a short centered grip and a clear hover/drag state in both themes. Start with a 6–8-point visual separator and an approximately 12-point effective drag target; validate the hit area without covering neighboring toolbar controls. The pointer indicates vertical resizing because dragging changes pane heights.

Dragging up gives more height to Results / Messages; dragging down gives more height to the SQL editor. Resize continuously, keep the selected output tab and both native content hosts alive, and preserve SQL selection, grid column widths, scroll state, and pending cell edits. Resize must not finish or discard a cell edit, steal keyboard focus, or trigger a query.

Prefer enhancing the existing native split behavior; use an explicit AppKit split bridge only if needed for reliable hit testing, grip drawing, or accessibility. Preserve task 04's frame-based containment that prevents the inner split from changing outer sidebar/inspector widths. Do not overlay a second independent drag gesture with conflicting size ownership.

Use an initial ratio of approximately **45% editor / 55% output** of the available split height. Retain each worksheet's chosen ratio across tab switches, Results/Messages changes, query completion, and window resizing. Clamp it to usable pane sizes without overwriting the saved preference during temporary small-window constraints. Existing pane minimums are the starting point; validate them against real toolbar/content heights and coordinate task 13's compact group behavior so nested panes cannot impose an impossible outer minimum size. This task does not add collapse/full-screen pane modes.

Provide **View → Editor Height → Increase / Decrease / Reset** actions for the active SQL worksheet, plus an accessible adjustable separator labelled **SQL editor and results height**. Increase/Decrease moves the ratio by a small consistent step, such as five percentage points. Double-clicking the handle resets the default ratio. Avoid assigning shortcuts that conflict with text navigation or query execution; keyboard menu access must work without dragging.

Persist only the per-worksheet ratio in private workspace recovery, using a validated finite range and a backward-compatible default. Coordinate the recovery-format change with tasks 04/13. Do not store presentation ratios in SQL files or the project's portable configuration. A tab moved to another task 13 group retains its ratio; the global workspace split and this internal editor/results divider remain separate controls.

Task 09's grid mode has no primary SQL editor, so it does not acquire an empty editor pane or this handle. Its explicit View SQL presentation can opt into wrapping/line numbers when that feature is implemented.

## Delivery and verification

1. Add worksheet-scoped editor presentation options and persistent app preferences. Implement wrapping in the retained TextKit 2 editor and verify it does not change document state.
2. Add the logical line index and native gutter, then verify alignment with wrapping, scrolling, resizing, font changes, and Unicode.
3. Improve the editor/results divider, accessible/menu resizing, per-tab state, and validated recovery persistence while retaining native children.
4. Extend the existing editor/host tests and measure large-document behavior. Build and verify the native app bundle; record interactive acceptance separately.

Acceptance:

- [ ] A fresh SQL worksheet opens with wrapping and line numbers enabled. Both preferences toggle live, persist across relaunch, and leave Theme first in Settings. Read-only inspector presentation remains explicitly configured.
- [ ] Long SQL and a long unbroken token fit the text viewport with wrapping enabled. Disabling wrapping restores horizontal scrolling without modifying a single source character.
- [ ] Gutter numbers remain correct for empty SQL, trailing newlines, LF/CRLF, pasted blocks, insert/delete, undo/redo, wrapped continuations, emoji, and combining characters. Line-count digit transitions do not create layout loops.
- [ ] Wrap/gutter changes preserve the native editor identity, undo manager/history, selection, find state, marked text, and logical scroll anchor. SQL dirty state, autosave bytes, cursor execution, and selected-statement execution are unchanged.
- [ ] The divider is visible, has a reliable vertical-resize cursor/hit target, and resizes smoothly in both themes. Double-click reset, menu actions, and accessible adjustment work without mouse dragging.
- [ ] Per-tab editor height survives tab/output switches and recovery; malformed or missing ratios use a safe default. Query completion and changing row counts do not reset the divider.
- [ ] Sidebar/inspector resizing and future group resizing leave the internal split stable. Both pane toolbars stay reachable at the supported minimum size, with no width oscillation, lost grid edits, or native host recreation.
- [ ] Extend `SQLTextEditorLifetimeTests`, `WorksheetStatementTests`, `QueryHostTests`, and recovery tests where appropriate. Include one very long wrapped line and a large multiline document; measure viewport work, line-index memory, and typing/resize latency, investigating app-controlled main-thread work over 50 ms. Do not claim measured UI performance from source inspection alone.
- [ ] Package/app checks and Release bundle verification pass. Mouse/keyboard, IME, VoiceOver, contrast, and real resize interaction receive separate native acceptance under the applicable computer-control rules.

SQL completion, formatting, diagnostics, code folding, minimaps, multiple cursors, and other editor expansion are outside this task. This document plans the requested three improvements; it does not implement them.
