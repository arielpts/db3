# 10 — Multi-row copy and paste in edit mode

**Status:** planned; no multi-cell selection or clipboard editing implemented by this task.  
**Planning date:** 2026-09-29.  
**Scope:** native cell-range and row selection, multi-row copy/paste, spreadsheet interchange, and single-value fill, staged as undoable edits.  
**Depends on:** [06 — Inline editing](06-edit.md) for eligible row snapshots, drafts, validation, previews, and transactions.  
**Coordinates with:** [09 — Grid mode](09-grid-mode.md), [07 — Projects and value choices](07-projects.md), and [08 — Odoo ORM edits](08-odoo-json-rpc.md).

## Outcome

Select several rows or a rectangular block of cells, copy with **⌘C**, move to another editable range, and paste with **⌘V**. Support copying between db3 tabs and exchanging tabular values with spreadsheet applications. A single copied value can fill a selected rectangle. The destination shows changed cells immediately after validation, with one undo step for the complete paste.

The interaction reference is Airtable's range selection, copy/paste, and single-value fill, documented in its [keyboard shortcuts](https://support.airtable.com/articles/7980233311-airtable-keyboard-shortcuts). Airtable also supports copying records into newly added records; its [record-copy workflow](https://support.airtable.com/articles/4087973664-adding-duplicating-and-deleting-airtable-records) is a reference for a later insert slice. The transaction and validation rules below are db3 decisions.

First delivery copies cells/rows in any readable grid and pastes into **existing, eligible rows in explicit Edit mode**. Task 09's ordinary Open Data grids and arbitrary SQL results remain read-only. Task 06's PostgreSQL update restrictions still apply. Pasting does not turn on editing, create records, edit primary keys, or submit changes to the server. **Paste as New Rows**, row duplication, cut/delete, series generation, and a drag-fill handle are follow-ups; a block extending past the current page never creates or fetches more records implicitly.

## Selection and native commands

- Track the active cell, selection anchor, rectangular bounds, and result revision independently from row highlighting. Mouse drag, Shift-click, and Shift-arrow keys extend a rectangle. Scroll at the edge while dragging without selecting unseen server pages.
- Clicking the row gutter selects all visible data columns in that row; Shift-click extends adjacent rows. Command-click can add/remove rows for copying. Disjoint cell ranges and pasting into disjoint row selections are outside the first slice; explain that an adjacent destination range is required.
- Use visible column order. Hidden columns, the row-number gutter, internal primary-key/version metadata, and pagination lookahead rows are excluded from copying and positional paste. Visible primary-key/generated columns remain copyable but cannot be updated.
- **⌘A** with grid focus selects the current loaded page/result range, with its scope/count visible. It never means every matching database row or initiates Fetch All. Task 09 selection ends at its displayed page; ordinary result grids select only their retained, addressable fetched rows within copy limits.
- Route **⌘C**, **⌘V**, **⌘Z**, and **⇧⌘Z** to the actual first responder. Inside a text editor, they operate on text; grid paste only runs when the grid itself owns focus. Return/F2 enters the cell editor, and Escape cancels range extension or a pending paste without discarding earlier drafts. Keep SQL-editor and grid undo histories separate.
- Provide matching Edit-menu/context-menu commands and VoiceOver announcements for anchor, range size, row/column names, read-only state, and validation errors. Selection must not open the inspector. Header-divider dragging and double-click auto-fit retain their current behavior.

## Copy contract

Default **Copy** exports values without headers; **Copy with Column Headers** is a separate action. Whole-row copies include visible columns in visible order, and selected rows in displayed order. Row numbers, connection details, credentials, hidden concurrency tokens, and source session handles never enter the clipboard payload.

Read complete values asynchronously from the captured result snapshot, including local draft overlays in edit mode. Do not copy truncated cell previews, formatted numeric approximations, or FK/enum display labels in place of stored keys. Label the command/help as copying displayed values including pending edits; **Copy Original Values** may provide the fetched baseline explicitly. A successful copy captures one draft/result revision rather than mixing values that changed during loading.

Publish both:

1. **Interoperable text/TSV:** tabs between fields and newlines between records, with defined quoting for tabs, newlines, and double quotes. Preserve Unicode, exact decimal/integer text, leading/trailing spaces, and trailing empty cells. Copy emits LF; paste accepts LF/CRLF while preserving embedded line breaks. A terminal record separator must not invent an extra destination row; define and test intentional blank records separately. Test actual interoperability with Numbers, Excel, and Airtable instead of assuming identical quoting behavior.
2. **A private, versioned db3 payload:** bounded dimensions, column labels/type hints, and typed cell values that distinguish SQL NULL from empty text, literal `NULL`, zero, and false. It contains values, not authority to write: destination metadata and permissions remain authoritative, including across connections.

Plain TSV represents SQL NULL as an empty field and cannot preserve the NULL/empty-text distinction. In-app copies use the typed payload for exact round trips. External empty fields mean empty text by default; nullable numeric/date destinations can therefore report a conversion error. **Paste Options** may explicitly map empty fields or a chosen token to SQL NULL, with the affected count shown before staging. Never automatically interpret the text `NULL`, `DEFAULT`, or `\N` as a special value. Header handling is also explicit: default paste treats every row as data; **First Row Contains Headers** enables a reviewed mapping rather than guessing from the first record.

Treat incoming private payloads as untrusted data: validate version, rectangular dimensions, types, sizes, and strings before use. Unknown/malformed private formats yield an error and an explicit **Paste as Text** option; do not silently fall back and lose NULL semantics. Database values resembling SQL or spreadsheet formulas remain literal data; db3 never evaluates them. Read or write the system clipboard only for an explicit user command, with no clipboard history or logging of contents.

## Paste placement and mapping

Capture the destination tab, source/connection revision, relation, transaction epoch, result revision, visible column order, anchor, selected rows, and draft revision before any asynchronous read or validation. Resolve each destination row to task 06's full primary key and original version token. Screen row numbers and copied source identities never become UPDATE predicates.

| Clipboard and destination | Behavior |
| --- | --- |
| One value, one selected cell | Stage that value in the cell. |
| One value, a rectangular selection | Fill every selected destination cell, validating against each destination type. |
| An R × C block, one active cell | Use that cell as the top-left anchor and target exactly R rows × C visible columns. |
| An R × C block, a selection of the same shape | Replace the selected range positionally. |
| Other shape mismatch or disjoint destination rows | Preserve the existing drafts and explain the expected/actual dimensions. No implicit repetition or truncation. |
| Block exceeds the displayed page/column bounds | Reject with a boundary error; no cross-page fetch, hidden-column overwrite, insert, or silent clipping. |
| Range intersects read-only/protected cells | Reject the default positional paste and identify those cells; never skip them silently. |

**Paste Options** presents a native mapping sheet for header-aware or full-row pastes, including those containing visible primary keys/generated fields. Show each source column, destination column, and explicitly excluded column, along with row/cell counts. Require deliberate exclusion of protected source fields before staging. Mapping targets only writable destination columns; it does not enable primary-key updates, match records by pasted IDs, infer upserts, or create columns. Reject duplicate/ambiguous header names and many-to-one mappings until resolved. Unmapped destination cells remain unchanged.

The pending paste belongs to its captured destination. Switching tabs cannot redirect it. A refresh, new result, sort/filter/page change, schema or metadata change, reconnect, transaction transition, or later draft edit invalidates it. Before staging, recheck all relevant generations and either publish the complete captured batch or leave the prior draft untouched. Pending work must never reattach to a different row that occupies the same screen position.

## Validation, drafts, and database application

Parse the complete clipboard block, load required full baselines, resolve mapping, validate every destination, and reserve its entire draft/undo budget before changing observable drafts. Invalid cells receive row/column-specific errors with a focused correction path. A failure in the last cell rejects the entire new paste, preserving previous drafts and selection. Do not offer an automatic “paste valid cells only” path in the first delivery.

- Reuse task 06's scalar conversion rules, exact numeric text, timezone handling, nullability, editable-column eligibility, original values, primary keys, and conflict tokens. Blank, SQL NULL, untouched, and database DEFAULT remain separate concepts.
- Coalesce edits with existing drafts against the original baseline. Pasting the original value removes that cell's pending change; a no-op paste makes no undo entry. A successful paste/fill is one native undo group; undo restores the exact pre-paste draft state, including earlier edits.
- FK values are stored keys, including complete composite relationships where applicable. Validate the resulting tuple using task 06's lookup/validation provider. Never guess by display label or create a missing referenced record. A searchable lookup can resolve a reported FK error explicitly.
- PostgreSQL enums and task 07 application choices use their stored keys. Where a metadata provider supplies allowed values, validate against its current revision; stale, dynamic, or unresolved choices use its normal blocked/unknown state. Do not create new enum values or execute project Python to resolve a paste.
- Stored ORM-computed/derived fields retain task 06's warning. A batch acknowledgement lists the affected fields and row count, and remains scoped to field/source metadata revisions. Cancel stages nothing; acknowledging never unlocks generated, nonstored, or otherwise read-only fields. ORM recalculation remains deferred.
- Copying can include pending drafts. Sorting, paging, refreshing, or closing must follow task 06's draft-resolution rules; pasted drafts cannot disappear simply because they no longer match a filter.

After staging, task 06's **Preview Changes** shows the complete batch, exact SQL and bound parameters, keys, before/after values, field warnings, and environment. The executed plan is the reviewed immutable plan. Pasting, editor blur, and tab switching never send SQL, even in development Auto mode.

**Apply** uses the existing serialized, parameterized update path and one savepoint-protected batch. A conflict, error, cancellation, or unexpected affected-row count rolls back the entire apply batch while preserving earlier work in the user's transaction. Manual mode leaves successful changes **Applied — not committed**. Production and unknown environments always require an explicit Commit; an explicitly configured development tab may use task 06's deliberate **Apply & Commit**. There is no per-row auto-commit or automatic retry after an uncertain outcome. Local undo after Apply is not a database rollback.

The clipboard/selection layer should accept a capability-aware draft sink so task 08 can reuse it later. The first implementation targets PostgreSQL SQL editing. An Odoo ORM tab must eventually use its guarded atomic helper, lower payload/record limits, request preview, company/user context, and explicit ORM commit; a pasted SQL range never switches to JSON-RPC automatically.

## Responsiveness, limits, and lifecycle

Use compact range descriptors and virtualized cell highlights, not one SwiftUI model per selected cell. Parsing, full-value reads, conversion, metadata/FK validation, encoding, and plan construction run off the main actor. Verify the clipboard adapter's threading behavior against AppKit; UI callbacks must not synchronously scan the result store, fetch database rows, or ask a lazy clipboard provider to generate an unbounded payload. Publish only bounded presentation updates.

Initial limits:

- At most **1,000 selected/pasted rows** and **50,000 cells** per clipboard operation, within task 06's **1,000 changed-row** limit across the current edit set.
- At most **1 MiB per editable value** and **8 MiB of encoded clipboard data across formats**. Also bound decoded clipboard/preparation memory to **8 MiB app-wide**, with one admitted preparation operation at a time; account for parsed strings and staging buffers, not just the incoming bytes.
- Share task 06's **8 MiB app-wide draft/original/undo/preview budget**. Reserve additional undo/baseline cost before staging and release preparation buffers after handoff. The two budgets are explicit and cannot be multiplied per tab. Platform clipboard copies can add transient memory; these are payload budgets, not a process-RSS guarantee.
- Retain existing result-cache/spool limits and page fetch backpressure. A copy too large for these limits directs the user to bounded export or a smaller selection; it never silently truncates cells or rows.

Show progress and Cancel for slow copy/preparation. Preparation failure or cancellation leaves the previous clipboard and drafts unchanged. Publish both clipboard formats together only after preparation succeeds, and report platform publication errors honestly. For an asynchronous Copy, capture the pasteboard change count and operation generation: do not overwrite clipboard content the user copied elsewhere while values were being loaded, including during an attempted recovery from a publication failure. A closed/source-changed tab cannot publish late clipboard data or drafts. A new preparation cancels/supersedes the previous one; cleanup and budget release precede its replacement.

Workspace recovery currently preserves SQL documents, not result data or grid row drafts. Do not add clipboard contents, original row snapshots, or pasted values to that file silently. Follow task 06's draft-aware close behavior; persistent editable-row recovery needs its own explicit, versioned policy and fresh baseline validation. Uncommitted transactions keep their existing close/rollback warning.

## Implementation sequence

| Area | Work |
| --- | --- |
| `DB3Core` | Grid selection and clipboard matrix types; typed NULL/text representation; immutable paste mapping/plan; source/result/draft generations and capability interface. |
| `DB3Grid` | Native rectangular/row selection, keyboard and responder routing, highlight virtualization, menus, progress/errors, and range undo groups; preserve inspector and divider behavior. |
| Clipboard adapter | Prepared native pasteboard exchange, private type/version validation, interoperable TSV parser/encoder, explicit headers/NULL options, size limits, and stale-copy fencing. |
| Editing coordinator / `Worksheet` | Load complete original values, resolve captured row/column identities, validate and stage atomically into task 06 drafts, and keep preview/apply/commit ownership unchanged. |
| Project/FK providers | Reuse searchable FK and enum providers, computed-field acknowledgements, and metadata revision checks; no separate inference engine. |
| Verification and docs | Fake clipboard/services, deterministic range/codec/state tests, disposable PostgreSQL updates/conflicts, then native interaction and cross-application clipboard checks. |

Deliver selection/copy first, then positional paste and fill, then mapping/options and metadata validation. Enable paste only after task 06's update/preview/transaction contract is implemented and tested. Planning this task does not run SQL or modify live database data.

## Acceptance

- [ ] Native drag/Shift/keyboard selection covers cells and adjacent rows; disjoint row copy has defined ordering; Select All stays within the loaded scope. Header auto-fit and inspector-toggle behavior remain intact.
- [ ] Copy uses complete values and the captured draft revision. Typed db3 round trips distinguish NULL/empty/literal NULL/zero/false; TSV preserves quotes, tabs, embedded newlines, CRLF, Unicode, exact numerics, spaces, and trailing empty cells.
- [ ] Interchange with Numbers, Excel, and Airtable verifies the documented format. Headers and NULL mappings require explicit options; default paste never guesses headers, evaluates formulas/SQL, or converts empty text to NULL.
- [ ] Anchor expansion, exact-shape paste, scalar fill, reordered/hidden columns, full-row protected fields, mapping exclusions, page boundaries, and malformed matrices never shift or silently drop data.
- [ ] An invalid final cell, cancelled warning, unsupported type, stale metadata, permission failure, or quota failure preserves the complete pre-paste draft. One undo/redo restores/reapplies the entire local batch.
- [ ] Sorting, filtering, paging, reconnect, close, tab switch, result replacement, concurrent draft edits, and delayed clipboard providers cannot redirect or publish stale work. A later external copy is not overwritten.
- [ ] FK composite keys, duplicate labels, inaccessible/deleted references, enum keys, computed warnings, and generated/read-only columns use existing editing rules without bypasses.
- [ ] Preview and executed parameters match. A conflict on the final database row rolls back the whole batch, retains earlier transaction work, and preserves drafts for correction. Unknown commit outcomes never replay automatically.
- [ ] Production/unknown connections cannot auto-commit through any clipboard path; development Auto still requires the explicit Apply & Commit action. Paste and editor blur never write SQL.
- [ ] Limit/large-selection tests prove bounded preparation/draft memory and cancellation cleanup, with responsive tab switching and virtualized highlights. Existing checks and the native build pass before enabling the feature.
- [ ] Live keyboard, IME, VoiceOver, drag scrolling, clipboard interoperability, and slow-provider behavior are verified under the workspace's computer-control permission rules. No production credentials are used for fixtures.
