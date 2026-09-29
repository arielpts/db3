# 07 — Projects, model metadata, and value choices

**Status:** planned; no project inspection has been implemented.  
**Planning date:** 2026-09-29.  
**First project:** `~/Projects/odoo`, with an Odoo 18 inspection adapter.  
**Depends on:** [04 — Query tabs](04-tabs.md), [05 — Objects](05-objects.md), and [06 — Editing](06-edit.md).  
**Coordinates with:** [08 — Odoo connections](08-odoo-json-rpc.md) for application connections and ORM behavior; project inspection is independent of connection transport.

## Outcome

Open a local project folder, discover connection candidates, and inspect its source to enrich database objects and editors with model names, logical namespaces, relationships, computed-field metadata, and searchable value choices. Keep inspection current in the background while the user edits the project elsewhere.

Projects are a general db3 capability. Odoo is the first adapter, not the only supported architecture. The common contracts must accommodate later Django, SQLAlchemy, Prisma, Rails, and other adapters without making their implementation part of this task. A folder without a recognized framework still supports reviewed connection discovery and user-defined namespaces.

The object list groups objects by **logical namespace**, initially Odoo modules such as `igual_case` and `igual_research`. Framework/core objects belong to **Base**, controlled by a **Show Base** toggle. PostgreSQL schema remains a separate, visible identity; namespace names never become SQL schema names.

User namespace changes and project preferences are saved in `.db3/project.json` inside the opened folder. Machine-specific folder access, private caches, and credentials live outside that file. Enum/selection pickers, including native PostgreSQL enum choices deferred from task 06, belong to this task.

## Project workspace

- Add native **Open Project Folder…**, **Close Project**, and **Recent Projects** actions. Use a folder picker and a small Projects section/status area; preserve the independent query-tab and browser selections established by tasks 04/05.
- Initially allow one active project folder per workspace. Opening another replaces project inspection after handling unsaved project-file conflicts; it does not close tabs, change their profiles, or discard staged database edits.
- Store a durable folder reference/bookmark in Application Support, resolve stale references, and request relocation through the normal folder picker when unavailable. Retain recent-project labels and paths privately; do not persist a full source tree.
- Show **Inspecting**, **Up to date**, **Changed**, **Partially inspected**, or **Unavailable**, with last successful refresh and actionable diagnostics. Show incomplete coverage honestly; an empty result is not a successful inspection of excluded or unreadable files.
- Provide **Refresh Project** and **Reveal Project Settings File**. Folder inspection alone never connects to a server. Explicitly binding a project to a saved profile establishes where its metadata may be used.
- A project may have several discovered profiles and bindings. SQL tabs, PostgreSQL object browsing, and task 08's Odoo model browsing retain their own captured connection contexts.

## Shared adapter contract

Introduce `ProjectInspectionAdapter` with a stable adapter ID/version and explicit capabilities:

| Contract | Result |
| --- | --- |
| Detection | Framework/version evidence and confidence; competing matches remain selectable. |
| Source roots | Bounded roots, exclusions, module/import graph, and watch dependencies. |
| Configuration | Typed connection candidates with environment/source provenance and unresolved requirements. |
| Models | Logical model identity, physical mapping candidates, namespace ownership, and source ranges. |
| Fields | Declared type, storage/computed/related status, relationships, display hints, and selection choices. |
| Refresh | Changed-source invalidation, immutable versioned snapshots, and completeness diagnostics. |

Each fact carries adapter version, file/range, source digest, snapshot generation, and confidence/resolution state. Database catalog evidence is a separate provenance source. Adapters return data; they cannot execute project code, issue SQL, modify profiles, or write user overrides.

Keep detection separate from transport: an Odoo project can bind to a PostgreSQL profile, an Odoo application profile, or both. A PostgreSQL profile remains usable without any project. An Odoo-only connection does not require PostgreSQL credentials; task 08 owns authentication, RPC model browsing, and the optional link to a separate PostgreSQL profile. Do not introduce a third mixed connection type.

## Connection discovery and environments

The inspected Odoo folder supplies these candidate sources; the plan intentionally records no actual endpoints, usernames, passwords, or tokens:

| Source | Candidate interpretation |
| --- | --- |
| Root `.env`: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Development PostgreSQL group; the inspected password entry is empty, which must remain distinct from a missing key. |
| Root `.env`: `PRODUCTION_DB_*` | Separate production PostgreSQL candidate, never combined with development keys. |
| `DATALAKE_DATABASE_URL`, `CHATWOOT_DATABASE_URL` | Separate PostgreSQL URL candidates; inspected URLs contain credentials but no explicit TLS query setting. |
| `ODOO_BASE_URL`, database-name configuration, token presence | Odoo candidate evidence for task 08; database role names are not Odoo login identities and must not be guessed as such. |
| `config/odoo-*.conf` | Placeholder-based configuration references, not concrete resolved credentials. |
| Makefile configuration | Evidence of development/test `PGSSLMODE=prefer`, remote `require`, and a configure/admin-role fallback; never execute it to discover values. |

Parse `.env` as bounded data, supporting documented literal quoting, comments, and interpolation only from already defined, explicitly allowed variables. Never source it, invoke a shell, expand command substitutions, evaluate Python, or inherit arbitrary process environment to fill gaps. Preserve missing/empty/unresolved distinctions and diagnostics without echoing secret values. Do not use the administrative configure fallback as the application's default connection user.

Present candidates grouped by source and environment, with masked credentials and editable connection details. Accepting a candidate uses the normal profile editor and explicit Save/Connect flow. Deduplicate only after comparing resolved nonsecret configuration and provenance; never silently merge production and development candidates or overwrite an existing profile.

Keep db3's `verify-full` default. The repository's `prefer`/`require` settings are evidence for review, not instructions to weaken TLS or interchangeable settings: `prefer` is not one of db3's current supported TLS modes. Missing URL TLS settings remain unresolved and are reviewed explicitly through the profile UI; do not silently translate `prefer` to `require` or disable verification.

Environment policy is shared with task 06: default to manual commit; a profile explicitly classified as development may opt into auto-commit; production profiles never enable auto-commit. Unknown environment remains manual. Never infer development from `localhost`, which may be a tunnel. A `PRODUCTION_` source records production provenance that an auto-commit toggle cannot remove; any explicit environment reclassification is a separate reviewed profile change with provenance retained.

Detected changes produce a new candidate revision and a visible diff. They do not rotate saved passwords, overwrite profiles, reconnect tabs, rerun queries, commit/roll back work, or silently enable auto-commit. Live sessions keep their captured endpoint and transaction ownership. If refreshed evidence invalidates a development classification, suspend automatic submission and invalidate mutation previews until the binding is reviewed; never keep auto-commit enabled through a production/unknown classification conflict. Apply current policy validation again when connecting and preparing a mutation, without committing an existing transaction to change its mode.

Persist accepted passwords only through the existing opt-in Keychain flow. Store source key names and candidate fingerprints privately, never raw `.env` contents. Redact secrets from diagnostics, logs, crash metadata, copied previews, project files, and test fixtures.

## Odoo source inspection baseline

Use an embedded, pinned Tree-sitter Python parser through a C/Swift package target, with a narrow typed extraction layer. Prototype grammar compatibility, packaging, incremental parsing, license obligations, parser timeouts/resource bounds, and release bundle size before committing to that baseline. Do not require system Python or execute/import the project's Python, virtual environment, startup hooks, configuration, or Odoo server. [Tree-sitter documentation](https://tree-sitter.github.io/tree-sitter/).

Use repository configuration to identify active roots: inspected `odoo_repositories.json` identifies core `.odoo/odoo`, custom `src`, and active OCA roots under `.odoo/oca/{queue,server-tools,partner-contact,server-env,storage,automation}`. Inactive repositories are not indexed by default. Resolve roots within the selected folder; show missing roots and exclude build outputs, caches, virtual environments, `.git`, uploads, and unrelated dependency trees. Never modify `.odoo`.

Prioritize custom modules and their imported metadata dependencies, then index necessary active core/OCA model declarations under the same resource limits. Parse manifests and `__init__.py` imports as data to build module/import ordering; files present on disk do not prove a module is installed in the connected database.

Bounded inspection of the current custom source found 166 files in model/wizard/mixin directories and 147 classes directly using Odoo model bases: 113 regular, 17 transient, and 17 abstract. Source occurrences include 89 `fields.Selection`, 82 `EnhancedSelection`, 7 selection-like `LlmComputed`, 216 `Many2one`, 1 `ForwardMany2one`, and 334 `computed(...)` wrappers. These are planning observations, not hardcoded runtime registry totals or complete database coverage.

Representative source patterns for synthetic acceptance fixtures:

| Relative path | Required interpretation |
| --- | --- |
| `src/igual_base/models/enhanced_selection_field.py` | Enhanced tuple shapes, metadata, and related selection hints. |
| `src/igual_case/models/appointment.py` | Module-level choice constants reused by other files; named palette metadata. |
| `src/igual_case/models/filing_auto_rule_condition.py` | Class constants and runtime lambda selections; the latter stay unresolved. |
| `src/igual_case/wizards/appointment_cancel_wizard.py` | Imported, filtered choice vocabulary; do not substitute an unfiltered source list. |
| `src/igual_research/models/cnj_djen/claim.py` | Explicit `_table`, `_auto=False`, `ForwardMany2one`, and enum-like `LlmComputed`. |
| `src/igual_case/models/defendant.py` | `_inherits` delegation to `res.partner`, computed fields, and display-name hints. |

Recognize model bases/import aliases before reading `_name`: non-model action classes also use that attribute. Extract `_name`, `_table`, `_inherit`, `_inherits`, `_auto`, `_rec_name`, field constructors, `selection_add`, and known helper semantics. Default dotted-model table naming is only a candidate; explicit table names, delegated fields, schema/search-path resolution, and live catalog identity take precedence.

Resolve safe literal lists/tuples, module/class constants, and statically resolvable imports without executing them. Extract independently known tuple components: a symbolic color must not discard literal keys/labels. For `EnhancedSelection`, two elements mean key/label, three add color, four add **description**, five add icon then description, and six add short label. Preserve declared order. `LlmComputed` selection variants may be character columns rather than native PostgreSQL enums.

Callable/method selections, comprehensions, dynamic inheritance, arbitrary expressions, unresolved imports, and ambiguous override order remain unresolved with source links. Do not fabricate choices or claim a partial list is complete. Related selections can reuse choices only when every relationship edge and final field is resolved. Merge `selection_add` only when the base and ordering are known.

## Catalog binding, relations, and computed fields

Require an explicit project-to-profile binding before decorating live results. Match the captured server/database identity, schema/relation, actual column, and compatible type; use task 05's catalog identity/generation. Duplicate names, changed search paths, absent tables, ambiguous module versions, or drop/recreate require revalidation. Local source is advisory; PostgreSQL constraints and actual columns remain authoritative for SQL execution.

Native PostgreSQL enums obtain exact stored labels from the type's catalog identity. Source selections enrich compatible ordinary columns with labels/help. Keep these providers distinct and show provenance; neither overrides a database type constraint or enables edits task 06 otherwise rejects. PostgreSQL FK constraints remain authoritative for its FK lookup; inferred `Many2one`/`ForwardMany2one` edges are labeled source hints, never invented physical constraints.

`_inherits` delegates fields to parent tables, not the child's row. Abstract models, nonstored fields, views/projections, and `_auto=False` require explicit mapping rather than guessed write targets. A nonstored field may leave an obsolete physical column behind; catalog presence does not prove the current application maintains it. Runtime display names or domains are not executable SQL expressions.

Carry `computed`, `stored`, `related`, `inverse`, and provenance through the shared adapter contract. Database-generated and nonstored fields remain read-only. A stored ORM-computed field that task 06 proves database-writable may be edited only after an explicit warning acknowledgement: **Direct SQL does not run ORM recomputation, inverse methods, onchange behavior, or application validation.** Repeat that warning in the query preview; acknowledgement is scoped to the captured field/source revision. ORM recomputation is future work, not part of this task.

Unresolved or stale computed/storage metadata is uncertainty, not evidence that an edit is safe. Retain the last known caution, show the stale/unresolved state, and require revalidation before offering any newly inferred editability. Choice metadata alone never authorizes SQL, and source changes never silently loosen task 06's write restrictions.

## Namespaces and saved user changes

Extend task 05 with namespace grouping, a namespace filter, and **Show Base**, off by default and saved per project. The Odoo adapter assigns initial ownership from defining modules; extending a core model via `_inherit` does not move its table from Base into the extension module. The custom module `igual_base` keeps its own namespace for tables it defines; its name alone does not place them in the framework Base bucket. Distinguish module ownership from PostgreSQL schema and retain the schema label in rows. Ambiguous ownership appears in **Unclassified** until resolved or overridden. Other adapters supply their logical namespaces; generic projects permit manual groups.

User assignments, namespace display names/order, and Show Base preference override inference. Save them in a versioned `.db3/project.json`; use nonsecret logical binding keys plus qualified object names, not credentials, endpoints, transient OIDs, or machine paths. Resolve those names only within their explicit binding and current catalog generation. Preserve unmatched overrides as orphans after rename/drop/recreate; do not silently attach them to a new object with a reused name/OID.

Synthetic example:

```json
{
  "version": 1,
  "adapter": "odoo",
  "namespaces": { "showBase": false, "order": ["sales", "custom", "base"] },
  "bindings": { "local-app": { "sourceGroup": "DB_" } },
  "objectOverrides": [
    { "binding": "local-app", "schema": "public", "relation": "example_order", "namespace": "sales" }
  ]
}
```

Keep device-specific saved-profile UUID binding resolution privately in Application Support; the logical key is portable but never auto-selects a matching remote endpoint. Serialize writes, compare the loaded revision/digest, write atomically, preserve unknown keys, and suppress only verified self-write events. Concurrent external edits produce a visible reload/merge conflict; never overwrite them silently. A read-only folder shows **Changes not saved** and a retry/revert path rather than claiming persistence.

Search retains task 05's server-backed completeness: namespace filtering cannot just hide rows in the first loaded catalog page and claim no matches. Resolve a bounded complete membership set or use a paginated catalog query constrained by verified object identities/names; mark incomplete inspection and permit narrowing the search. Base visibility and namespace grouping apply to the resulting search, with stable sorting and accessible group headings. Odoo transport model browsing uses task 08's separate identity/pagination contract.

## Searchable choice editor

- Use an anchored native popover for short lists and a resizable native sheet/modal for larger lists, sharing one choice model. Include a focused search field, current value, source status, and a virtualized list.
- Match label, stored key, and description case-insensitively with literal substring search. Display key beside label where they differ; supplementary color/icon/short label never replaces readable text. Search the complete bounded local choice set, not just rendered rows.
- Keyboard arrows select, Return stages a choice, Escape cancels, and VoiceOver announces key/label/current selection. For large sets, show the list limit and refine-search action; no synchronous main-thread scan of project files.
- Persist the exact stored key. Treat SQL NULL distinctly from an empty string, literal `"False"`, false booleans, and Odoo's runtime false/unset conventions; determine mapping from the actual database type and task 06's value representation.
- Preserve an unknown/legacy current key verbatim and show that it is absent from the known choices. Do not silently replace it, add it to a native enum, or infer validity from source. Unresolved choices fall back to the appropriate task 06 editor with an honest metadata status.
- Choosing a value stages the task 06 edit; it issues no SQL. Preview and transaction policy still apply. Keep an open editor's choices/version stable; if source or catalog meaning changes, invalidate its pending preview and require revalidation instead of changing the user's selected key beneath them.

## Background refresh and resource ownership

Use FSEvents for selected local roots and source dependencies, observing file changes as invalidation hints. Events can be coalesced or indicate dropped history, so reconcile filesystem state and perform a full rescan when required. Keep watcher ownership outside views. [Apple FSEvents programming guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/Introduction/Introduction.html).

Debounce bursts by approximately 300 ms with a maximum wait to prevent starvation. Hash only candidate changed files after cheap metadata checks; invalidate dependent constants/imports/models. Reconcile on focus and sleep/wake and periodically while the project is active, with a slower idle cadence. Detect additions, deletions, renames, symlink/root changes, branch switches, manifests, settings files, and atomic editor saves. Never recurse through symlinks outside approved project roots or into cycles.

All enumeration, reads, parsing, matching, hashing, graph updates, and cache writes run off the main actor. Start with one bounded inspection worker plus one I/O task; cancel superseded generations and prioritize changed custom sources. Publish small immutable snapshots atomically. Parse errors retain last-good facts visibly marked stale while unrelated files continue refreshing. Closing/replacing the project cancels work and removes watchers before results from its generation can publish.

Initial measurable bounds: 2 MiB per source/config file, 50,000 indexed files, 64 MiB decoded metadata/cache, and bounded queues with overflow-to-rescan rather than unbounded event retention. Configure root-specific exclusions and report skipped coverage at limits. Keep parse trees bounded/evictable and cache only required facts/digests; do not retain whole-file text or raw `.env` contents. Persist optional private metadata caches under Application Support with adapter/schema version and root digest, never in Git-tracked project settings.

Targets to validate on the representative project: changed-file metadata visible within 1 second after debounce for ordinary files, app-controlled main-thread work slices below 50 ms, responsive SQL editing/scrolling during a cold scan, and stable memory after repeated edits/branch switches. These are provisional budgets, not performance claims. A changed `.env` only refreshes candidate data; background inspection never causes network calls, profile changes, query reruns, or transaction actions.

## Delivery and verification

1. Prototype the embedded parser on sanitized fixtures, measure packaging/performance, and lock adapter/provenance/snapshot contracts. Add generic folder lifecycle and exclusions before Odoo-specific interpretation.
2. Implement bounded configuration discovery and reviewed profile binding, including environment/TLS policy and Keychain handling. Coordinate Odoo candidate completion with task 08.
3. Add Odoo source extraction, dependency tracking, catalog matching, namespaces, saved overrides, and computed-field warnings. Keep unresolved coverage visible.
4. Add native PostgreSQL/source choice providers and searchable editors integrated with task 06 staging, query preview, and manual transaction defaults.
5. Add background reconciliation and conflict handling, then validate responsiveness, bounded resources, lifecycle cleanup, accessibility, and persistence.

Use synthetic fixtures modeled on the listed patterns; do not copy private project source, `.env` values, endpoints, or credentials into db3 tests/repository. Cover module/class constants, aliases, enhanced tuple lengths, palette references, selection extensions, callable/comprehension deferral, inheritance/delegation, related/stored/computed fields, missing modules, and conflicting definitions.

Test empty/missing dotenv values, quoting/interpolation cycles/limits, malicious shell-like text as inert data, distinct environment groups, TLS review, production auto-commit rejection, explicit development opt-in, and unchanged live-session snapshots after candidate refresh. Test invalid mapping, duplicate schemas/names, native enum changes, unknown keys, NULL, stored-computed acknowledgement, and no SQL before task 06 execution.

Test namespace overrides across reopen, Base toggling, search beyond first catalog page, unknown JSON keys, atomic save failure, read-only folders, external-write conflicts, orphan mappings, event storms/dropped events, branch switches, temporary syntax errors, dependency edits, closed-project late completions, and repeated project open/close without retained watchers. Verify the Odoo-only and PostgreSQL-only paths remain independently usable as task 08 lands.

This is a planning task only. Implementation will run focused headless tests and local builds first; screenshots, UI-state inspection, and mouse/keyboard automation continue to require fresh explicit computer-control permission under the current user instructions.
