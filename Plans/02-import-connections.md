# 02 — Import connections

**Status:** planned; no connection or password migration has run.  
**Planning date:** 2026-09-29.  
**Scope:** a native menu wizard, with **Navicat** as the first source; PostgreSQL connections, saved passwords, connection colors, and retained SSH settings.  
**Depends on:** [01 — Native scaffold](01-scaffold.md).  
**Follow-up:** [03 — SSH tunnels](03-ssh-tunnels.md) enables imported SSH connections.

## Outcome

Add **File → Import Connections…**. The user chooses a source, sees the connections found there, selects all or some, reviews what will be imported, and imports those profiles into db3. Navicat is the only source offered initially. Keep the source adapter separate from the wizard so another importer can be added later without changing the flow.

Preserve the details that make the existing connection list useful: names, database settings, passwords saved in Keychain, and each connection's assigned color. The supplied screenshot is the visual reference for colored rows. Import saves profiles without opening a database connection, starting a tunnel, running SQL, or changing the active worksheet.

This task implements the import experience. SSH transport execution belongs to task 03. An imported SSH profile remains visible with **SSH support required** until that task is implemented; it must never fall back to a direct connection.

## Evidence and source compatibility

Read-only file inspection during planning found:

| Observation | Consequence |
| --- | --- |
| Installed Navicat Premium Essentials **15.0.37** | Make this installation the first compatibility fixture; do not assume a newer Navicat schema. |
| The app-container connection file has **38 PostgreSQL** and **2 SQLite** records | Show all discovered records; SQLite is visible but unavailable for import into this PostgreSQL-only app. Counts are a planning snapshot, not constants. |
| Five PostgreSQL records have `usetunnel = true`; one has `usessl = true` | Preserve and classify transport settings before marking profiles ready to connect. |
| All 38 PostgreSQL records have `savepassword = true` | This indicates saved-password intent, not proof that db3 can retrieve the corresponding Keychain items. |
| All local PostgreSQL `nsy_id` and `nsy_project_uuid` values are empty; no `connection_uuid` field is present | Use an explicit fallback source identity. Do not deduplicate empty IDs or match passwords by display name alone. |
| The non-container `conn.plist` contains a different dataset | Present candidate locations and counts; never silently merge or choose the first file found. |
| Sibling `pref.plist` has five assigned colors among the active PostgreSQL records: two `#69F0AE`, two `#FF5252`, one `#B388FF` | Import exact saved colors, with full alpha; the other 33 records are uncolored. |
| Appearance preferences contain 88 PostgreSQL names, including 50 absent from the connection file | Join appearance data to active source records; stale preferences are not additional connections. |

The observed active source is:

```text
~/Library/Containers/com.prect.NavicatPremiumEssentials12/Data/Library/
  Application Support/PremiumSoft CyberTech/Navicat CC/Common/conn.plist
```

This is a detected installation path, not a universal bundle ID to hard-code. Check the installed application's identity and a small set of known Navicat locations, including the standard `~/Library/Application Support/PremiumSoft CyberTech/Navicat CC/Common/conn.plist`, applicable containers, and a user-selected location. Avoid scanning unrelated application data.

Navicat documents `.ncx` connection exports and a macOS `conn.plist` location. These documents do not establish the private schema, color storage, Keychain item identifiers, or whether passwords are portable across versions. Support the observed local format first, and support `.ncx` metadata only for versions covered by fixtures. Unknown or encrypted export variants get a clear unsupported-format message, with local-source/manual-entry alternatives. [Navicat migration instructions](https://help.navicat.com/hc/en-us/articles/218281627-How-to-get-the-connection-information-when-migrating-Navicat-to-new-computer), [Navicat connection storage](https://help.navicat.com/hc/en-us/articles/219566088-How-secure-is-Navicat).

No Keychain secrets were retrieved during planning. Color storage was identified through bounded structural inspection; production decoding and exact credential matching still require the discovery gate below before implementation can claim complete migration support.

## Wizard

### 1. Choose source

- Open a native sheet from **File → Import Connections…**; optionally expose the same action in the connections sidebar menu.
- Show a source picker with **Navicat** as its only enabled option. Do not advertise unavailable providers.
- Offer **Find on this Mac** and **Choose File…**. The latter accepts a supported Navicat connection file/export; sibling appearance metadata must be explicitly associated with that source.
- Show detected installation/version when available, source location, and record counts. If there are multiple candidates, let the user choose one; distinguish an empty source, inaccessible source, and unknown format.
- Discovery and parsing run in the background. **Cancel** remains available. Discovery does not read password values or start Keychain authorization prompts.

### 2. Select connections

- Display a searchable native table with checkboxes and columns for **Name**, **Host / Port**, **Database**, **User**, **Color**, **Transport**, and **Status**. Show details for the focused row without exposing passwords.
- Provide **Select All**, **Deselect All**, and individual selection; optionally **Select Filtered** when searching. All means all eligible rows in the chosen source, including rows outside the current filter. Filtering never silently changes selection. Show both selected and filtered counts.
- Initially select valid PostgreSQL records that have not already been imported. SSH records remain selectable because their metadata can be saved; clearly label them as requiring task 03. Unsupported engines and structurally invalid records remain visible, unchecked, with a reason.
- Preserve distinct connections that share a name, host, user, or database. Do not collapse them using an endpoint-only match. For a proven source-identity match, show **Already imported** with **Skip** (default) or **Import separate copy**. Choosing a copy makes that row eligible for selection/counts and allocates a new destination UUID; it never updates the existing profile.
- Do not present a stored-password flag as **Password available**. Before retrieval, display **Saved in Navicat; not checked** or **Not saved in source**.
- **Next** is disabled when no eligible connection is selected. Keyboard selection, checkbox state, table navigation, and VoiceOver descriptions must work without color as the only signal.

### 3. Review

- Summarize selected profiles, colors, password policy, duplicates skipped, and profiles needing follow-up. The final action reads **Import N Connections**.
- **Include saved passwords** is on by default. Explain that this includes recognized database passwords, SSH passwords, and key passphrases from Keychain or supported source fields. macOS may request access during import; unavailable passwords can be entered later. Turning it off imports metadata only. Review lists each applicable credential role and any unsupported role explicitly.
- **Preserve connection colors** is on by default. Show the resulting swatches before committing.
- Identify SSH requirements, unsupported TLS/authentication settings, missing files, and source formats whose password lookup is unavailable. Preserve supported metadata for incomplete profiles and make their connection restriction explicit.
- Provide **Back** and **Cancel**. Neither changes db3 or Navicat. Choosing another source invalidates the previous preview and selection.

### 4. Import

- Freeze the selected source snapshot and selection, including both `conn.plist` and associated `pref.plist`/appearance files. Revalidate all participating files if they changed after preview; require a refreshed review rather than mixing snapshots.
- Read credentials only for selected records and selected credential roles. Process access requests serially, off the main thread; never issue dozens of concurrent Keychain prompts.
- Display progress by connection and aggregate counts, never password text. Access denial or a missing credential can produce a profile needing a password; it must not become an empty saved password or silently erase another credential.
- Cancel stops new work and waits for any in-flight OS operation to return. Before the commit boundary, discard staged work and clean up credentials created by this attempt. During the short commit boundary, finish or recover deterministically, then report the actual result.

### 5. Result

- Report **Imported**, **Skipped**, **Needs password**, **Needs SSH support**, and **Failed**, with per-connection reasons. Distinguish metadata imported successfully from credentials copied successfully.
- **Done** returns to the existing workspace. New profiles appear in the sidebar with their colors. There is no automatic test connection or automatic selection of a production database.
- A profile missing a credential asks for it through the connection editor when the user explicitly connects; it does not attempt an empty-password connection merely because lookup failed.
- Closing or reopening the wizard does not repeat an import. A second run skips the same source records unless the user explicitly chooses to create separate copies.

## Mapping and retained settings

Parse the observed local hierarchy as `scope → project → engine → connection name → settings`, validating types and limits at every level. The current instance uses `0 → 0 → PostgreSQL`; other roots are not automatically equivalent. Use fixture-backed adapters for schema variations.

| Source information | db3 behavior |
| --- | --- |
| Connection dictionary key | Preserve display name exactly, including Unicode, spaces, and bracketed prefixes. |
| `host`, `port`, `defaultdatabase`, `username` | Map to the profile; validate the string port and required fields. Do not invent database/user values when semantics are unknown. |
| `savepassword`, source credential identity | Keep intent and lookup outcome separate; copy a retrieved secret into db3's Keychain namespace. |
| Connection color / appearance metadata | Decode the verified representation to optional sRGB RGBA; retain an uncolored connection as uncolored. |
| `usessl`, `ssl_param` | Map only equivalent supported TLS behavior. Preserve unsupported requirements and block connection until resolved. |
| `usetunnel`, `ssh_param` | Retain typed jump-host/authentication settings and credential references for task 03. Keep the database endpoint separate from the SSH endpoint. |
| `usehttptunnel` or other unsupported routing/authentication | Retain a typed unsupported-feature marker and explanation; never discard it and connect directly. |
| `customdblist`, `usecustomdblist`, timeout, encoding, groups/order if present | Preserve meaningful supported metadata; list unmapped behavior in the preview. A database-list filter is not a default database. |
| `autoconnect`, cached server version, session history, saved queries | Do not execute or restore activity. Cached version is not live connection validation. |

The observed `ssh_param` keys include `authtype`, `host`, `port`, `username`, `pkeyfile`, `pkeyfilebookmark`, `savepassword`, and `usecompression`. Verify enum values; do not infer authentication mode from a file name or connection label. Foreign app bookmarks do not establish usable file access in db3. Keep file references as references and request a replacement file selection when needed.

The observed `ssl_param` includes verification flags, a mode string, CA/client certificate/key references, and a client-key password field. Treat password-like fields as secrets even when embedded in an otherwise nonsecret dictionary. Do not serialize a raw source dictionary, unknown JSON blob, archive, or export into db3 metadata. Use an allowlist of typed fields.

db3 currently supports `verify-full`, `require`, and `disable`. Do not reduce certificate/hostname verification, map every enabled SSL connection to one default, or omit required client certificates. Unknown semantics produce a profile that needs configuration. Preserve a verified explicit source TLS choice and show it in review.

## Password migration

Create a source-specific credential resolver, separate from destination persistence. Establish the exact Navicat item class and identifying attributes using a disposable source connection with a known test password. Validate the installed version, local/cloud distinction, renamed connections, duplicate endpoints, database passwords, SSH passwords, and private-key passphrases as applicable.

- Query only items associated with selected Navicat records. Do not dump the Keychain, guess across unrelated accounts, alter Navicat's items, modify access controls, or put secrets in shell arguments, environment variables, logs, fixtures, reports, or `connections.json`.
- Use Security framework calls on a bounded background worker. macOS authorization is user-mediated; denial, cancellation, locked/inaccessible Keychain, ambiguous matches, and missing items are distinct outcomes. Access behavior must be verified for the actual app signing/distribution setup. [Apple Keychain query API](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)), [Security result codes](https://developer.apple.com/documentation/security/security-framework-result-codes).
- If exact matching cannot be established, import metadata with **Needs password**. A metadata-only `.ncx` import must not claim access to the originating Mac's Keychain.
- Discard embedded password-like fields from preview state. At import time, re-read only recognized selected-record secret fields when password import is enabled; interpret them only through a fixture-backed plaintext/encoding contract. Unknown encryption/encoding or unsupported credential roles produce a specific unresolved result, never a guessed password or a success claim. The toggle covers recognized database passwords, SSH passwords, SSH private-key passphrases, and TLS client-key passphrases; handling a secret does not make its currently unsupported transport ready to connect.
- Store database passwords under the existing service `app.db3.connection`, account = the destination profile UUID. Define separate role-specific services/references for SSH passwords and key passphrases, shared with task 03; never overwrite the database password with an SSH secret.
- Distinguish an explicitly empty credential from no saved credential and from a failed lookup. Refactor the current API where necessary: `LocalPersistence.password(for:)` currently collapses missing into an empty string, and `savePassword("")` deletes an item.
- Keep secret material short-lived and out of observable preview models. Swift string storage cannot promise secure zeroization; minimize copies and lifetime instead of claiming it.

Native Keychain prompts are part of the implemented user flow. During agent-driven development, any computer-control session still requires fresh explicit approval under the workspace instructions.

## Colors and sidebar behavior

For the observed Navicat 15 source, read the sibling `pref.plist` at:

```text
connpref → scope → project → PostgreSQL → connection name
  → "" → "" → "" → serverpref → markercolor
```

The current scope/project are both `"0"`. Join by the complete scope/project/engine/name path, only for active `conn.plist` records. Of the 38 records, 32 omit `markercolor`, one contains an explicit null archive, and five contain colors. Do not create profiles from the 50 stale preference entries.

`markercolor` is legacy non-keyed `NSColor` typedstream data, not a keyed plist archive. The observed color records use `NSColor`/`NSObject`, color-space byte `2`, and four float components. Implement a narrowly validated, bounded color-only decoder backed by synthetic fixtures, including the null representation; reject unknown variants without instantiating arbitrary source classes. Confirm color-space conversion and byte interpretation with known test colors before treating this as production support. Other Navicat versions/exports require separate evidence and may omit appearance metadata.

Store a framework-independent optional sRGB RGBA value. Validate finite components/ranges and the original color space. Do not estimate imported values from screenshot pixels or assign colors based on names such as “prod.” Unknown representations get a warning and a manual color choice, rather than a claimed exact match.

Render assigned colors on connection rows in the spirit of the supplied screenshot: a readable colored background when unselected and a persistent swatch/stripe when native selection would obscure it. Keep connection status indicators separate from user colors. Verify light/dark appearance, increased contrast, selection, and VoiceOver. Add color editing/clearing to the connection editor; color must survive restart, normal edits, and switching between URL and Manual Input.

Preserve an explicit source order/group path when its semantics are known. A plist dictionary's iteration order is not proof of sidebar order; otherwise use a documented deterministic name sort. Full folder/group navigation can remain a later UI feature, with verified group metadata retained.

## Architecture and persistence

| Area | Planned change |
| --- | --- |
| `App/DB3App/DB3App.swift` | File menu action. |
| `App/DB3App/WorkbenchModel.swift` | Wizard ownership and import coordination, independent of `saveAndConnect`. |
| New import wizard/model files | Source discovery, preview, stable selection, review, progress, cancellation, summary. UI state contains no secret values. |
| Testable package import module | Source adapter, bounded parsers, field mapping, diagnostics, source identities, injectable credential/store interfaces. Use a focused `DB3Import` target rather than importing AppKit into `DB3Core`. |
| `DB3Core/DatabaseTypes.swift` | Backward-compatible color, provenance, typed transport requirements, and configuration status. Missing new fields default correctly when loading existing profiles. |
| `App/DB3App/LocalPersistence.swift` | Typed credential outcomes, save-without-connect batch commit, recovery, and serialization with ordinary profile saves. |
| `WorkbenchView.swift`, `ConnectionSheet.swift` | Colored rows, status details, missing-password flow, and preservation of imported metadata while editing. |
| `DB3Postgres/PostgresConnectionURL.swift` | Preserve appearance/provenance while parsing URL transport settings deliberately; do not accidentally erase an imported SSH requirement or silently bypass it. |
| Package/project generation | Add the target/tests and update `Scripts/generate-project.py`'s explicit product dependencies; regenerate the Xcode project. |

Use a source identity consisting of a source namespace plus a verified nonempty stable record ID. For the observed local schema without IDs, use the chosen source namespace and full record path, including its name, and document the rename/move limitation. An unchanged source record must be recognized on reimport. Renames and cross-format imports without trustworthy identity require a visible possible-duplicate decision; never overwrite using host/name similarity alone.

The first version is additive: skip existing proven matches or explicitly create a separate copy with a new destination UUID. Updating/replacing existing profiles in bulk is deferred. A display-name collision alone is allowed and shown in review.

Serialize the complete import commit against all profile mutations and merge with the latest stored state. `saveAndConnect` is unsuitable because it mutates credentials, writes profiles, and then connects. A serial I/O queue does not serialize an entire operation across separate `await` calls.

For new profiles, stage validated metadata and create only destination-owned credential items with newly allocated UUIDs. Use create-only Keychain writes; a pre-existing item is a collision, never permission to overwrite it. Track ownership in a private, secret-free recovery journal before writes. Write metadata using a private temporary file with final permissions before atomic replacement; publish the UI model only after the outcome is known. On pre-commit failure, remove only items created by that attempt. On restart, reconcile journal entries against committed profile IDs so recovery cannot delete a committed password. A failure to clean up must remain visible and retryable. JSON and Keychain are separate stores; `.atomic` alone is not a cross-store transaction.

Keep existing directory/file permissions (`0700`/`0600`), source files read-only, and unrelated destination profiles untouched. Bound input size, nesting, record count, and string/archive lengths; disable XML external entity resolution for supported `.ncx` XML. All parsing, file access, and credential operations stay off the main actor, with cancellable work and bounded publication to the UI.

## Implementation stages

### 0. Prove the source format

- [ ] Create sanitized fixtures matching the observed Navicat 15 hierarchy, with representative direct, TLS, SSH, uncolored, colored, duplicate-name, and unsupported-engine records.
- [ ] Turn the observed `pref.plist` color path/join and typedstream format into validated fixtures; check any order/group variants and establish exact Keychain identifiers using disposable credentials. Record supported source versions and formats.
- [ ] Confirm source TLS/SSH enum semantics, file references, and credential roles. Do not mark discovery complete from saved-password flags alone.

**Exit:** every claimed imported field has a tested mapping; unavailable/unknown fields have an explicit preview outcome. Password and color support are release requirements, not optional follow-ups hidden behind a metadata-only success.

### 1. Build discovery and preview

- [ ] Implement the Navicat adapter and the source-selection step, including multiple detected installations and file selection.
- [ ] Implement the connections table, selection controls, search, eligibility/status details, and review counts.
- [ ] Add backward-compatible model fields, source identity rules, transport restrictions, and a save-without-connect pathway.

### 2. Import selected profiles

- [ ] Implement selected-record credential lookup and destination Keychain storage, including metadata-only import and manual recovery.
- [ ] Implement staged persistence, cancellation, failure compensation/restart recovery, duplicate handling, and a precise result summary.
- [ ] Render imported colors and preserve them through normal editing and relaunch.
- [ ] Preserve SSH settings/credential roles for task 03 and reject direct connection attempts for profiles requiring unsupported transport.

### 3. Verify and document

- [ ] Add fixture, mapping, state-machine, persistence, and regression tests below; run the existing suite and build.
- [ ] Verify the native wizard and colored sidebar after fresh computer-control approval, or record user-performed verification.
- [ ] Update the README with the import flow, supported Navicat versions/formats, credential behavior, and the task 03 dependency.

## Acceptance and verification

- **Selection:** importing one, several, or all eligible connections imports exactly that set. Filtering, sorting, Back, deselection, and unsupported records do not change hidden selections unexpectedly. Zero selections cannot commit.
- **Read-only preview:** source discovery/preview/cancellation writes nothing, requests no Keychain secret values, excludes embedded secret fields from preview state, and opens no database or SSH connection.
- **Mapping:** preserve names, host/port, database, user, color, and supported TLS settings. Use the observed 38 PostgreSQL / 2 SQLite dataset shape as a sanitized fixture, not a fixed runtime expectation. Five fixture SSH records retain their separate endpoints and remain blocked until task 03.
- **Credentials:** test success, explicitly empty, not saved, missing, locked, denied, cancelled, ambiguous, invalidly encoded, and destination-write failure; verify exact association for duplicate endpoints and separate database/SSH roles. Use fake stores for most tests and an isolated disposable Keychain fixture for integration.
- **Colors:** test verified source encodings, absence, invalid components, source/appearance join collisions, and legacy profile decoding. Compare known source colors with saved values; visual checks cover row selection and both appearances.
- **Persistence:** test idempotent reimport, duplicate-copy choice, concurrent ordinary saves, disk failure, permission failure, cancellation, crash boundaries, cleanup failure, and restart recovery. Existing profiles/passwords remain unchanged; no orphan silently counts as success.
- **Malformed input:** test missing fields, wrong types, invalid ports, unsupported engines/version, corrupt/oversized files, excessive nesting, XML external entities, and untrusted archives. Diagnostics contain no secrets or raw records.
- **Editing:** importing and later editing via either input mode preserves color/provenance and does not silently remove a required tunnel. Changes to endpoints cannot reuse a stale credential or source identity without a deliberate policy.
- **Workspace:** no implicit database connection, tunnel, SQL execution, worksheet replacement, or transaction change. Reopening the app restores imported metadata and obtains stored credentials through db3's own Keychain namespace.
- **Responsiveness:** a synthetic 1,000-record source remains searchable/selectable while parsing/credential work is in progress; no blocking file or Security call executes on the main actor. Cancellation and progress remain usable while macOS handles authorization.

Run headless tests/builds first. Automated desktop/browser inspection, screenshots, and clicks require fresh explicit permission immediately before the control session, as specified by the workspace's user instructions.
