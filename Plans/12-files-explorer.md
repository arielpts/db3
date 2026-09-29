# 12 — Project files explorer and native file tabs

**Status:** planned; this task does not implement an explorer or file editor.  
**Planning date:** 2026-09-29.  
**Scope:** a native project tree and editable text-file tabs, with explicit saves and external-change handling.  
**Depends on:** [07 — Projects](07-projects.md) for folder identity/access and [04 — Query tabs](04-tabs.md) for retained native document hosts.  
**Coordinates with:** [09 — Grid mode](09-grid-mode.md), [11 — Project terminal](11-terminal.md), and [13 — Workspace layout](13-workspace-layout.md) for sidebar controls and editor groups.

## Outcome and first delivery

Browse the active project's files in Explorer and edit source/configuration files in native workbench tabs. Task 13 owns Explorer's primary-sidebar icon, visibility, placement, and later editor groups. Connections and Objects retain independent selection and database context.

Without a project, show **Open Project Folder…**. Any supported local folder works without framework detection. File opening executes no code, starts no terminal/database connection, and sends no content to Claude Code or Codex. Task 11's unmodified CLIs produce filesystem changes handled like another editor's changes.

The first delivery includes lazy navigation, refresh, hidden-file visibility, file opening, native text editing/find/undo, Save/Save As, conflict handling, and coordinated close. A later stage within this task adds native New File/New Folder, Rename, Move, and Move to Trash. Defer drag-and-drop filesystem mutations, global content search, Git controls, language servers, completion, extensions, preview tabs, and executable project tasks. Every opened document has a retained tab; opening another file never replaces an existing document.

## Explorer tree

- Show the captured project root name and a virtualized hierarchical tree, using a native outline view or an equivalent implementation whose row reuse and accessibility are verified. Expand/collapse folders; single-click selects, double-click or Return opens a file. Keyboard arrows navigate without opening files. Provide **Refresh**, **Collapse All**, **Show Hidden Files**, **Reveal in Finder**, and **Copy Relative Path**.
- Enumerate direct children only when a directory is expanded. Sort folders first, then names consistently using locale-aware comparison with a stable path tie-breaker. Preserve expansion and selection through refresh when identity remains valid. Show loading, unreadable, disappeared, empty, and incomplete states distinctly.
- Keep hidden entries off by default with a discoverable toggle; dotfiles such as `.env` become available through that toggle. Explorer visibility is separate from task 07's inspection exclusions: an excluded dependency folder can be browsed deliberately without enabling indexing. Do not claim to honor `.gitignore` in this slice.
- Use one enumeration worker and bounded requests. Initial limits are 5,000 entries per expanded directory, 20,000 cached tree nodes, and 16 MiB of tree metadata. Stop enumeration at the limit, mark that directory incomplete, and offer narrowing or Reveal in Finder. A local name filter only filters loaded entries and says so; it is not project-wide search. Evict collapsed subtrees while retaining compact expansion references where budget permits.
- Display symlinks distinctly. Resolve approved in-project targets with cycle detection; links outside the project are listed but cannot be expanded or opened as project documents in this slice. Recheck containment at use time. Do not traverse packages, sockets, FIFOs, devices, or other special files as ordinary text; packages remain leaves with Reveal in Finder.

Tree enumeration, metadata access, path resolution, sorting, and filtering run off the main actor. Reconcile folders changed during enumeration without duplicated nodes or false completeness. Other sidebar/tab selections leave Explorer's root unchanged.

## Project identity and filesystem changes

Reuse task 07's project owner, durable folder reference, access lifetime, and root generation. Keep document UUID, project identity, relative display path, resolved URL, and observed filesystem identity distinct. A display name is never a document key. Reopening the same resolved file selects its existing document, including through an in-project symlink; an atomic external replacement at the same path is a changed document revision rather than an unrelated new tab.

Share the project's filesystem event service where practical. Watch events invalidate observations; they do not supply trustworthy replacement contents. Debounce bursts around 300 ms, reconcile expanded directories and open documents, and rescan affected state after dropped events, focus return, or sleep/wake. Do not recursively enumerate the full project merely to update a collapsed folder. Keep watcher queues bounded, with overflow scheduling reconciliation.

Capture project, document, request, and disk-revision generations before asynchronous work. Closing/replacing a project cancels its pending tree work and prevents late callbacks from populating the new project's Explorer. A file-read result also checks the document's edit revision so it cannot overwrite typing that began meanwhile. Root relocation, disappearance, permission changes, and symlink retargeting produce explicit unavailable/conflict states; none silently retarget an open document.

Task 07 inspection observes successful edits normally. Opening or saving configuration does not accept discovered connections, reconnect existing sessions, or run project code. Its managed `.db3/project.json` writer and the file editor must share revision/conflict coordination so namespace changes cannot overwrite an open settings-file draft.

## Shared tabs and document ownership

Use shared tab kinds **query**, **grid**, **file**, and **terminal**, sharing ordering, selection, close, overflow, and retained hosts with separate resource owners. Files allocate no `Worksheet`, PostgreSQL session, result store, or connection context.

- Opening `.sql` uses the existing SQL-file operation: deduplicate and select an existing worksheet or create an ordinary disconnected SQL tab, capturing normal connection context. It counts toward the four query/grid tabs and follows SQL Run and recovery rules. Never create a second generic editable document for that SQL file.
- Other supported text files create file tabs labeled by basename, with enough parent-path context to distinguish duplicate names. Show the project-relative path, file format, dirty state, loading/conflict state, and accessible close label. Retain text storage, undo, selection, scroll, and focus until close.
- Admit at most **12 file documents app-wide**, independently of four database tabs and task 11's one terminal for the active project. Reopening an existing document works at capacity. Reserve a slot and memory budget before reading; failure must not replace another document. Later editor groups share the same document owner and count, rather than admitting another copy per group.
- Route Save/Save As to the selected document kind. Database Run/Cancel, transactions, sample-data replacement, CSV export, and value inspector are unavailable for file tabs. Never fall back to the first worksheet when a file is selected. Tab navigation and Close target the shared tab identity. Task 13 defines positional shortcuts when the combined count exceeds four.

Generalize the SQL-only `active` fallback, tab bar, host, menus, and close coordinator. Preserve independent split-layout behavior and inactive editors.

## Native editor and resource limits

Extract reusable TextKit/AppKit primitives from `DB3Editor` or add an equivalent file adapter. Plain-text editing suffices initially; omit SQL coloring/accessibility labels and Run instructions. Preserve native selection, IME, navigation, find/replace, clipboard, and document-owned undo. Disable smart quote/dash substitutions.

Support strict UTF-8, with or without a BOM, in the first slice. Preserve BOM choice, existing newline bytes, final newline, and tabs; ordinary editing or Save must not silently reformat a file. Insert new lines using the detected convention, with an explicit visible choice for mixed-line-ending documents. Unsupported encodings open an explanation with Reveal in Finder; never decode lossily and overwrite the source. A read-only file remains viewable with Save As available where permitted.

Start with a 2 MiB encoded-text limit and 2 Mi UTF-16-unit limit per editable file, and 32 MiB accounted current/baseline text across file documents. Check bounds during reads and before accepting paste, replacements, or growth beyond capacity. Reject an oversized edit intact. Binary classification and regular-file validation precede full decoding; files containing unsupported control/binary data get a metadata view, not an executable or rendered HTML preview. Oversized files offer a clearly labeled read-only bounded preview of at most 256 KiB when decodable; that preview cannot be saved over the full source.

Bound undo separately: prototype document-local undo groups with a measured payload budget, initially 8 MiB per file and 64 MiB app-wide. Evict oldest completed groups with a visible undo-history-limit state; never discard current text or mislabel it saved. Native `levelsOfUndo` alone does not bound bytes. If an enforceable implementation cannot pass oversized paste/replace tests, reduce supported editing limits before shipping. Tree, text, undo, native layout, and temporary save buffers need separate accounting; these budgets are not a whole-process memory guarantee.

## Saving and external edits

Track the loaded/saved content baseline and a disk revision containing identity, size, timestamp, and a bounded content digest. Dirty means current content differs from its saved baseline; undo back to that baseline clears the indicator. Reading, selecting, or observing a file is not an edit. Keep reads and writes on bounded background queues. Apply the shared file-I/O conflict guards to Explorer-opened SQL worksheets too, while preserving their database behavior and SQL recovery policy; a disk reload never reruns SQL.

Saving captures the document UUID, destination, text/format, edit revision, and expected disk revision. Serialize saves per document and destination, coordinate filesystem access, revalidate the destination and project containment, and use a verified atomic-replacement path. Preserve supported file permissions/metadata; reject files whose link or attribute semantics cannot be preserved safely. Do not silently replace a symlink itself or break hard-link relationships. An error leaves the local buffer dirty and reports what failed. A successful save marks only captured content saved; later edits remain dirty.

Before replacement, compare the current disk revision with the expected baseline. Noncooperating external programs can race coordinated saves; do not claim filesystem-wide transactional isolation. Prototype revision checks and recoverable replacement, retaining conflicting disk content when a race is detected rather than reporting an unconditional clean save. Do not suppress watcher events by time window: suppress only events verified against the exact self-write revision, and verify the destination after writing.

For an external change to a clean document, reload only after stable reading and generation revalidation; preserve/clamp selection and scroll, reset obsolete undo, and show that it reloaded. Defer replacement during marked-text composition. For a dirty document, retain both local content and the new disk revision, mark **Changed on Disk**, and offer **Compare**, **Reload from Disk**, or **Save Copy**. Reload explicitly discards local edits; replacement of the external version requires a separate deliberate action with a freshly checked revision. No automatic merge or overwrite is implied.

External deletion leaves the buffer visible with **File Missing**. A positively identified rename can update its reference; ambiguity does not guess. Save cannot silently recreate a deleted file. Save As uses a native picker inside the active project, prevents collisions with another open document or pending save, and requires explicit replacement of an existing destination. An inaccessible or changed parent keeps the document open.

## Explicit file operations

Add native context-menu and keyboard-accessible **New File**, **New Folder**, **Rename**, **Move…**, and **Move to Trash** after save coordination passes. User-invoked reversible operations need no generic extra approval. Validate names/destinations at commit; expose failures without guessing replacements. New empty files use normal extension-aware opening.

Operations stay within the active project. Protect its root from rename/move/trash; reject outside-root destinations, directory moves into descendants, unsupported special files, and ambiguous symlink targets. Operate on an explicitly selected link itself, never recursively through its target. Reject name collisions, including case/normalization aliases, without replacing existing entries. Handle legitimate case-only renames deliberately. Bound preflight enumeration; do not silently expand a move into a recursive cross-volume copy/delete workflow.

Serialize mutations with document saves and task 07's settings writer. Capture source/destination identities and project generation; revalidate before changing disk. Rename/move updates affected open-document paths, descendant references, tree selection, and pending-save routing without replacing document UUIDs, dirty buffers, undo, or SQL sessions. A stale operation fails rather than acting on a newly created item at the old path. Reconcile watcher events against the completed mutation; failures preserve accurate paths and recoverable buffers.

Use native recoverable Trash with no permanent-delete fallback. Gather affected dirty-file **Save Copy**, **Discard and Close**, or **Keep Open** decisions first; cancellation/save failure leaves the target intact. Close file tabs only after success. SQL worksheets retain text and sessions as missing-file documents; trash never cancels SQL or rolls back. Unavailable Trash support is an error.

## Close, project switching, and recovery

Individual dirty-file close offers **Save and Close**, **Discard Changes**, and **Keep Open**. Close Project or switching projects gathers decisions for every owned file document and task 11 terminal before changing project identity or releasing watchers/access. Keep Open, save failure, or a new edit invalidates closure. Clean file tabs close with the old project; query/grid tabs retain their independent captured context. This explicitly refines task 07's earlier blanket statement that replacing a project does not close tabs.

Whole-workspace close and app quit also review dirty source files. SQL draft preservation does not silently cover source files: this slice has explicit saves/discards, with no source-text autosave or crash recovery. Gather all file/terminal/database decisions before destructive teardown. Completed explicit saves remain saved if a later decision cancels closing; keep all tabs and the project available. Revalidate document revisions and external conflicts after modal decisions and recovery writes.

Extend the versioned mixed-tab recovery record with clean file references, project identity, order, selected tab, cursor/scroll, and format metadata. Do not persist source contents, undo stacks, or conflict copies as ordinary workspace recovery. Reopening the same approved project may restore its file references through bounded reads; missing or replaced files show unavailable state. Restoration never writes files or executes code. Keep existing SQL snapshots compatible, including their separate draft policy. If the workspace becomes empty, create the usual disconnected query only after checking all tab kinds.

## Delivery and acceptance

1. Define shared tab/document identities, resource admission, injectable file I/O, and revision/conflict contracts. Align with tasks 07/09/11 before creating duplicate workspace models.
2. Implement lazy Explorer and lifecycle reconciliation with synthetic trees; add bounded file classification/read and retained native plain-text documents.
3. Add exact-format saves, external-change comparison, dirty-close decisions, project-switch coordination, and compatible reference-only recovery.
4. Add explicit create/rename/move/trash commands after document coordination, including affected-document and watcher reconciliation.
5. Verify responsiveness, memory limits, keyboard/focus behavior, and accessibility; wire Explorer into task 13's primary-sidebar controls.

- [ ] Large/deep directories, permissions, hidden entries, packages, symlink cycles/outside targets, dropped events, root removal, and project-switch races have bounded, truthful states.
- [ ] SQL files preserve worksheet behavior; file tabs allocate no database resources; mixed selection/commands/close/reorder and capacity never target hidden SQL.
- [ ] Duplicate paths, in-project aliases, atomic replacement, delete/recreate, external rename, and Save As collisions preserve the correct document identity.
- [ ] UTF-8/BOM, CRLF/LF/mixed endings, final newline, Unicode/IME, tabs, binary data, large lines, read-only files, oversized paste, and undo-budget eviction preserve exact supported text.
- [ ] External changes before/during save, dirty conflicts, verified self-write events, permission/disk failures, and concurrent managed project-settings writes never silently lose the local draft.
- [ ] Create/rename/move/trash cover case-only names, collisions, root protection, descendants, symlinks, dirty descendants, pending saves, failures, and external races; Trash stays recoverable and database sessions remain intact.
- [ ] Cancelled project switch or quit preserves all unsaved work and live owners; successful close releases watchers, descriptors, hosts, and queued work; legacy SQL recovery remains valid.
- [ ] Files edited by a project terminal, Claude Code, or Codex update Explorer without stealing focus or replacing dirty buffers; opening a file sends no model request and executes no command.

Use sanitized fixtures and focused headless model/native-view tests first, followed by local builds. Interactive screenshots, UI-state inspection, and mouse/keyboard automation require fresh explicit computer-control permission under the workspace instructions. This is a planning task only.
