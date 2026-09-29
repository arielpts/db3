# 08 — Odoo edits through JSON-RPC

**Status:** planned; no RPC client, server add-on, or ORM edits implemented.  
**Planning date:** 2026-09-29.  
**Scope:** native browsing and updates to existing Odoo 18 records through the ORM, with local drafts, a request preview, and an explicit commit.  
**Depends on:** [04 — Query tabs](04-tabs.md), [05 — Objects](05-objects.md), [06 — Inline editing](06-edit.md), and the project adapters and field metadata in [07 — Projects](07-projects.md).

## Outcome and transaction contract

Open a verified Odoo model in an **Odoo ORM** tab, edit values using the native grid, preview the requested model/field changes, and choose **Commit via ORM**. Changes remain local until that action. The SQL editing path in task 06 remains available with its own capabilities and warnings.

An Odoo RPC operation uses its own database cursor. The Odoo 18 dispatcher calls the model method through `retrying`, which flushes and commits before returning. `/jsonrpc` dispatches service calls without preserving a browser session. Therefore an ORM write request cannot implement SQL-style **Apply now, Commit later** across separate requests. These facts were checked in the local Odoo 18 sources and the official upstream implementation. [Model service](https://github.com/odoo/odoo/blob/18.0/odoo/service/model.py), [RPC controller](https://github.com/odoo/odoo/blob/18.0/odoo/addons/base/controllers/rpc.py).

| Action | ORM behavior |
| --- | --- |
| Edit a cell, choose an enum, or select a relation | Update a local draft only. |
| Preview Changes | Show the immutable request plan; perform no write. |
| Commit via ORM | Send one guarded batch request; successful acknowledgement means committed. |
| Discard drafts | Remove local changes; no server rollback is needed. |
| Undo after a confirmed commit | Stage a new change for review; never claim a previous transaction can be rolled back. |
| Switch tab, lose focus, close a popover, or background the app | Never send a write. |

**Production never auto-commits edits.** Production and unknown environments always require the explicit commit action. Development may later offer an explicit per-tab opt-in to automatic submission, disabled by default; that is outside the first delivery and cannot be inherited from a project refresh or another tab. Enforce environment policy in the operation coordinator as well as the UI. A production commit is a deliberate user action, not an automatic RPC sent when editing ends.

## Connection types, tab ownership, and project integration

Add **Odoo** as a first-class connection type alongside **PostgreSQL** in the new-connection flow. An Odoo connection works on its own with a base URL, Odoo database, login, and API credential; it requires neither PostgreSQL network access nor an opened project folder. Live model/ACL metadata and the compatible helper are sufficient for supported ORM browsing/editing. Task 07's project metadata is optional enrichment. Existing PostgreSQL connections keep their SQL behavior. There is no third “mixed” connection type.

An Odoo profile can optionally link an existing PostgreSQL profile by stable profile ID for direct SQL access. Pairing is explicit and independently validated: matching database names alone cannot establish that two endpoints reach the same database. Use verified server/helper identity where available, and leave an unverified pair visibly unlinked. PostgreSQL and Odoo credentials, runtime owners, connection failures, and transaction state remain separate.

The Odoo connection's browser lists permitted models through RPC and opens ORM data tabs using live metadata and bounded reads. SQL actions are available only through its verified linked PostgreSQL profile. A standalone Odoo connection never falls back to SQL; a PostgreSQL connection never silently sends ORM writes. Task 07's project adapter type describes the project and remains independent from either connection protocol.

- Each tab binds one execution backend: **PostgreSQL SQL** or **Odoo ORM**. Show the mode, environment, database, endpoint, and effective user. The mode controls preview, commit actions, lookup provider, and read-only reasons.
- Bind ORM tabs to the Odoo connection/adapter identity, runtime capability revision, reviewed endpoint/database mapping, authenticated user, and allowed company context. When a task 07 project is linked, additionally capture its metadata revision; folder changes cannot silently retarget an open tab. A tab without a project remains fully supported within the live adapter's capabilities.
- Model names and record IDs are ORM identities obtained from live model metadata. A table name with underscores is not proof of its model; when a project is linked, verify task 07's mapping against the live model. Inherited, delegated, abstract, transient, and nonstandard-table models require explicit capability decisions.
- Opening an ORM view from SQL creates a separate tab after verifying the model and SQL-key-to-ORM-ID mapping; fetch the record anew through RPC under current ACLs. Do not send an RPC for a row with local SQL drafts or uncommitted SQL edits; resolve that work first. A clean SQL tab can remain open as an independent snapshot.
- Changing a tab's backend requires resolving drafts and transactions, then reading a new baseline. Never carry SQL `xmin`, row numbers, or SQL transaction controls into an ORM request.
- Task 07's Python inspection supplies hints and provenance. Runtime model metadata, access rights, record rules, and the guarded server endpoint decide whether a field is writable. Source discovery never executes project Python.

## Connection and authentication

Create an `OdooConnectionProfile` separate from the PostgreSQL profile: reviewed base URL, Odoo database, login, environment, adapter version, Keychain reference, and optional linked PostgreSQL profile ID. Discovery may suggest values from recognized project configuration; it does not authenticate automatically or display secret values. `ODOO_BASE_URL` and `ODOO_USER_TOKEN` are candidate configuration keys, but the token's name establishes neither an API-key type nor its login. Leave those unresolved until validated; never substitute `DB_USER`, an administrator, or a database master credential. PostgreSQL passwords and Odoo API credentials are never interchangeable.

For Odoo 18, check `common.version`, authenticate with `common.authenticate(db, login, apiKey, {})`, then use `object.execute_kw` with the returned user ID. The API key occupies the password argument in this legacy RPC interface. Prefer an API key; do not interpret an arbitrary variable named `TOKEN` as proof of a compatible Odoo credential. Confirm the selected credential's intended service during setup. The implementation must cover rejection, revocation, expiry, and deployments that require API keys for noninteractive access. [Odoo authentication entry point](https://github.com/odoo/odoo/blob/18.0/odoo/service/common.py), [API-key authentication](https://github.com/odoo/odoo/blob/18.0/odoo/addons/base/models/res_users.py).

Store saved API keys in a separate Keychain item scoped to endpoint/database/login. Project manifests and normal profile JSON hold only references. Avoid credentials in URLs, request previews, logs, analytics, exported diagnostics, and user-facing server tracebacks. Changing endpoint identity requires rebinding the credential; do not forward it through a cross-origin redirect.

Use HTTPS with normal certificate/hostname verification. A deliberately configured local development HTTP endpoint may be supported and visibly identified; production cannot use that exception. Preserve an explicitly configured reverse-proxy base path when constructing `/jsonrpc`. Verify Odoo 18 compatibility and required add-on capabilities before enabling writes; other Odoo versions remain read-only until their adapter is tested.

## Native RPC client and bounded reads

Add a narrow Odoo transport/module behind task 07's adapter interfaces, using asynchronous `URLSession`. Keep JSON encoding/decoding, network work, conversion, and diff generation away from the main actor. Publish small immutable UI updates. Use an ephemeral session without browser cookies or a persistent response cache.

- Implement the JSON-RPC 2.0 `call` envelope with `service`, `method`, and `args`; validate response IDs, result/error shape, HTTP status, content type, and bounded body size. A JSON-RPC request ID correlates a reply; it is not an idempotency key.
- Serialize writes per ORM tab and allow at most two reads per endpoint, with a bounded queue. Cancel obsolete searches/reads and fence replies by project, profile, auth, tab, metadata, and editor generations.
- Start with 50-record pages plus a next-page indicator, explicit requested fields, 5 MiB response bodies, 1 MiB commit payloads, and a 15-second read deadline. Bound pending drafts with task 06's budgets and initially cap a commit at 100 records. Report limits instead of silently dropping changes.
- Browse using `search_read`, or `search` followed by `read` where required. Use deterministic ordering with `id` as a tie-breaker; explain that pagination across separate requests is not a single database snapshot. Do not call `search_count` on every page or keystroke; exact totals are optional explicit work.
- Cache bounded `fields_get` results by endpoint/database/user/company/language and metadata generation. Request only needed attributes and fields. Read the actual record baseline through the guarded helper before enabling an editor.
- Treat RPC access failures, unavailable metadata, empty results, invalid credentials, and transport errors as distinct states. HTTP 200 with an RPC error is a failure. Redact backend diagnostics before presentation.

## Fields, relation search, and enum choices

Reuse task 06's single active editor, exact-value loading, local undo, draft markers, and keyboard/accessibility behavior. Task 07's adapter chooses the provider; the grid does not contain Odoo-specific field-name guesses.

| Field kind | First-delivery behavior |
| --- | --- |
| Char/text, boolean, supported integer/date/datetime | Typed editor with Odoo conversion and server validation. |
| Selection | Searchable choice list from live `fields_get`, showing label and stored key; preserve unknown existing values. |
| Many2one | Searchable record picker with record ID and display name; stage the ID, never the label. |
| Float/monetary | Preserve input text and validate declared digits; clearly use Odoo's numeric semantics, not a promise of arbitrary SQL decimal precision. |
| One2many/many2many, binary, reference, JSON and unsupported custom fields | Inspect/read-only initially; x2many command generation and specialized editors are later work. |
| Computed/related fields | Apply runtime write eligibility and the warning rules below. |

Distinguish untouched, unset, empty text, false, and zero in the draft model. Map unset to Odoo's expected `False` only for supported field types; do not globally substitute JSON null or empty text. Many2one read values may contain `[id, label]`, while write values contain an ID or `False`. Preserve large integers without routing through `Double`; reject values the tested server/codec cannot round-trip. Dates and datetimes use a tested UTC/time-zone conversion contract. A PostgreSQL exact numeric column does not imply an exact-decimal Odoo field.

For relation search, call the verified comodel's `name_search` with a bounded limit after roughly 200 ms debounce. Resolve field domain/context through a supported, typed adapter contract; do not evaluate Python or arbitrary expression strings in db3. If a dynamic domain cannot be established safely, explain why the picker is unavailable. Keep duplicate labels distinguishable by ID and offer an explicit clear action only when permitted. Search may run model-defined display logic; permissions and business validation still apply at commit.

Carry a reviewed, allowlisted context such as language, time zone, and authorized company IDs through reads, relation searches, and commit. Do not accept arbitrary context, `sudo`, model methods, or RPC method names from source files or project configuration. Company switches invalidate baselines and pending previews. Runtime selection values can depend on that context; stale or unavailable choices must not silently fall back to source literals.

### Computed fields and recalculation

A stored ORM-computed/derived field shows a warning before editing, including the field/model and the applicable behavior. In **SQL** mode, task 06 warns that direct edits bypass ORM computation. In **ORM** mode, computed fields without a supported inverse remain read-only; a warning never unlocks them. An inverse-backed or related field is editable only when the live capability contract allows it, with a warning that the inverse may update other values.

Ordinary ORM `write` runs applicable model overrides, constraints, inverse handling, and dependency-driven recomputation. It is not a simulation of the Odoo form client and does not promise every onchange, workflow button, external integration, or business action will run. Display fresh server values after success. A separate **Recalculate through ORM** command is much later work and is explicitly absent here.

## Guarded server add-on: required for writes

Stock `write` can update a recordset with one value dictionary, but a sequence of RPC calls with different row patches commits separately. A preliminary client-side `read` followed by `write` is also not an atomic compare-and-set. The first writable release therefore requires a small versioned companion add-on with a narrow guarded batch API. Without a compatible helper, db3 provides browsing and previews only; it does not downgrade to unguarded writes.

Proposed helper contract: `capabilities`, `read_edit_snapshot`, `commit_changes`, and `operation_status` on a dedicated gateway model. The model/method names are fixed in the adapter, not supplied by the project. Restrict access to an explicitly assigned editor group and to reviewed model/field capabilities, while retaining normal user model access and record rules. The helper does not accept arbitrary SQL, Python, domain code, methods, or arbitrary context.

1. Validate protocol version, source context, user/company identity, batch size, unique record identities, writable fields, and a stable operation UUID plus payload hash.
2. Check model/field access and record rules in the authenticated user's normal environment; never use `sudo` for records or writes. Read snapshots contain only permitted values and a supported concurrency token.
3. Lock target rows in deterministic model/key order within this request, after access checks, using a reviewed mapping to actual storage. Recheck existence/access, invalidate stale ORM cache, and read baselines under the locks. Models with unsupported delegated/storage layouts remain read-only until their lock strategy is tested.
4. Compare the snapshot's original typed fields and version with current values. A `write_date` string alone is insufficient as a universal token: models can disable access logging, timestamps can be coarse, and direct SQL changes can bypass it. The helper must bind a baseline to all stored inputs covered by its conflict guarantee, using canonical values and a tested version strategy; unsupported models stay read-only.
5. Reject the whole batch before writes when a record changed, disappeared, or became inaccessible. Report bounded per-record conflict details only where the user may read them. Refresh/rebase is deliberate; no force-overwrite path ships here.
6. Execute each row's `write` through the ORM, flush applicable computations/constraints, then read fresh permitted fields and tokens. Raise on any failure so the entire request rolls back. Do not catch-and-continue or call `commit` inside the helper.
7. Record an operation receipt bound to user, database, UUID, and payload hash in the same transaction. Return fresh records, warnings, and receipt identity; the outer Odoo request commits. A reused UUID with a different payload is rejected, and receipt access is permission-scoped.

Atomicity requires participating model overrides to honor the request transaction. Enable only reviewed models whose writes do not commit internally; test their inheritance chain and integrations. Database rollback cannot undo external side effects already sent by custom code. Odoo may internally retry serialization/deadlock failures, so add-on/model design must also avoid duplicating nontransactional effects. This is a release gate for the supported models, not a claim that arbitrary installed modules are safe.

The helper is separately packaged and installed deliberately by the server operator. Opening a project or connecting db3 never installs it, alters the database, changes a user's groups, or enables an unsupported model automatically.

## Request preview and commit lifecycle

**Preview Changes** shows backend **Odoo ORM**, environment, endpoint/database, model, record IDs, field keys/labels, before/after typed values, computed-field warnings, and the exact helper method/arguments excluding credentials. It states **This request commits these changes on the server**. SQL preview is unavailable for this mode because db3 cannot truthfully enumerate the ORM's generated SQL or all side effects.

```text
Backend: Odoo ORM · Manual submission · Production
Method: db3.edit.gateway.commit_changes
Record: example.record / 17
Changes: title = "Reviewed title", owner_id = 42
Precondition: original snapshot + source/context revision
Action: Commit 1 record via ORM
```

The preview is an immutable `ORMEditPlan` consumed unchanged by execution. Editing values, refreshing metadata, changing companies/profile/user, or rebasing conflicts invalidates it. UI filtering does not remove hidden changes from the batch. Copying a preview is explicit and excludes authentication material.

States are **Draft**, **Ready to commit**, **Submitting**, **Committed**, **Rejected**, and **Outcome unknown**. Once a write has been sent, cancelling local waiting or losing the response does not prove rollback. Stop additional writes for that operation and preserve its identity. Never automatically replay a write after timeout, connection failure, cancellation, app relaunch, or malformed response.

Use `operation_status` as a read-only reconciliation step after an ambiguous result; only a matching committed receipt can confirm this operation. Matching current field values alone is not proof. A missing receipt can remain inconclusive while the original request is still executing; do not present it as permission to resend. Keep a minimal local unresolved-operation journal with source identity/UUID/hash and no credentials or record values. Explicit recovery must settle the original outcome before a new reviewed plan is submitted.

After confirmed success, replace draft overlays with returned server values and invalidate related cached reads. SQL tabs pointing at the same database become **Refresh required**. An existing repeatable-read SQL transaction may still see its old snapshot; never commit or roll back unrelated SQL work merely to refresh the ORM edit. Closing a tab with drafts offers keep/discard; closing during submission explains the possible server outcome instead of claiming cancellation undoes it.

## Delivery order and acceptance

1. Implement standalone Odoo profiles, the typed transport, Odoo 18 capability/auth checks, bounded read adapter, and optional project/PostgreSQL bindings; ship read-only with synthetic fixtures.
2. Add native typed editors, live selection/relation providers, local drafts, and truthful request previews. Unsupported fields/models explain their restriction.
3. Implement and review the companion add-on, guarded snapshots/locking/comparison, atomic batch writes, scoped receipts, and failure recovery on a disposable Odoo 18 instance.
4. Enable explicit **Commit via ORM** for the reviewed model set after end-to-end tests. Production and unknown environments retain manual submission in every path.

Acceptance tests use a fake JSON-RPC server and a disposable Odoo 18 fixture with purpose-built models; never discovered real credentials, the user's current Odoo database, or production endpoints.

- Authentication: correct and expired keys, false authentication result, endpoint changes, redirects, unexpected versions, HTTP/RPC errors, malformed IDs, oversized bodies, and redacted diagnostics.
- Editors: exact integer boundaries, decimal conversion limits, false/unset/empty distinctions, timezone round trips, stale enum choices, duplicate relation labels, forbidden records, domains, company changes, and late search replies.
- Transactions: multi-row success, failure on the last row rolling back earlier writes, concurrent changes between preview and commit, same-record contention, hidden-field conflicts, deleted records, and unsupported lock mappings.
- Permissions: field/model ACLs, record rules, company restrictions, guessed IDs, arbitrary method/context attempts, and receipt access by another user cannot bypass normal ORM access.
- Recovery: response loss after commit, cancellation after send, server retry, process restart with unresolved receipt, duplicate UUID/payload mismatch, and absent helper never trigger an unguarded or automatic rewrite.
- UX: standalone Odoo works without PostgreSQL or a project folder; optional profile links require verified identity; leaving a cell performs zero write calls; production cannot enable automatic submission; preview and payload agree; SQL and ORM cannot commit each other's work.
- Responsiveness: large field metadata, rapid search, slow servers, and bounded commit batches keep native scrolling/editing responsive and stay within memory/request budgets.

No native UI change, local Odoo server execution, live network authentication, or production write is part of this planning task.
