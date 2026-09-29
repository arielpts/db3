# 11 — Native project terminal, Claude Code, and Codex CLI

**Status:** planned; this task does not implement a terminal or launch an agent.  
**Planning date:** 2026-09-29.  
**Scope:** a native terminal tab available only for an opened local project, supporting an interactive shell, Claude Code, and Codex CLI.  
**Depends on:** [04 — Tabs](04-tabs.md) and the generic folder identity/access/lifecycle slice of [07 — Projects](07-projects.md); Odoo inspection need not be complete.  
**Coordinates with:** [09 — Grid mode](09-grid-mode.md) for shared tab kinds/recovery, [12 — Files explorer](12-files-explorer.md) for source changes, and [13 — Workspace layout](13-workspace-layout.md) for moving the retained terminal beside other tabs or into the bottom panel.

## Outcome and native experience

With a project open, choose **Open Terminal**, **Open Claude Code**, or **Open Codex**. db3 opens a terminal tab in its existing workbench row and starts the selected program in that project's folder. The process, screen, scrollback, and input survive switching to a query or file. Task 13 subsequently lets this same terminal sit beside a source file/query or in the bottom panel.

Use native AppKit terminal rendering within the SwiftUI workbench: native tab chrome, launch picker, project label, toolbar/menu commands, context menus, font/appearance settings, copy/paste, search, focus, and accessibility. Match db3's spacing and system light/dark appearance; use a native monospaced font and normal macOS text selection conventions where the terminal protocol permits them. The CLI continues to draw its own interactive interface inside the terminal. This is the meaning of **as native as possible** for this task; rebuilding either conversation UI would be separate work.

```text
┌─────────────────────┬──────────────────────────────────────────┐
│ Project: odoo       │ Query 1 ×   models.py ×   Terminal ×     │
│ Explorer/Databases  ├──────────────────────────────────────────┤
│                     │ odoo · [Shell / Claude Code / Codex]     │
│                     ├──────────────────────────────────────────┤
│                     │ Native terminal                          │
│                     │                                          │
└─────────────────────┴──────────────────────────────────────────┘
```

First delivery permits **one terminal tab for the active project**, independently of the four-database-tab limit and task 12's file-document budget. It allocates no worksheet, database connection, result store, or catalog session. Before file tabs, the row can therefore contain four database tabs plus one terminal. Multiple simultaneous terminal sessions are a follow-up; hiding, moving, or selecting the terminal never creates a second session.

Host the user's installed, unmodified CLIs. No VS Code extension extraction, Electron/browser shell, custom chat backend, Agent SDK integration, or automatic database-context bridge is required. db3 owns the terminal and launched session; each CLI owns its conversation, model selection, commands, permissions, authentication, and history.

## Project ownership and launch actions

- Enable terminal launch only when task 07 has resolved an accessible local project. With none, show **Open a project to use the terminal**. No database binding or connection is needed.
- Capture project ID, resolved folder reference, tab UUID, launch profile, and launch generation before asynchronous lookup/start. Revalidate before spawning and publishing completion. Project replacement or close invalidates pending launches.
- The first explicit launch action creates/selects the tab and starts its program. Opening/inspecting a project, restoring the workspace, selecting a stopped tab, and showing task 13's bottom panel never start a process.
- Repeating the action for an already running launch profile selects its existing terminal. Requesting another profile selects the tab and offers **Restart as Shell / Claude Code / Codex** through coordinated stop/restart. Never send a command into an unknown foreground program. Users can also type `claude` or `codex` themselves in the shell.
- Show the project and launch profile outside terminal output. A CLI typed into the shell retains Shell as its launch profile. Do not infer authoritative idle/running state from prompts or process-supplied titles; titles are bounded supplementary text.
- Set the initial working directory to the captured project root, separately from executable/arguments. Never interpolate a path into `cd … && …` or change db3's process-wide working directory. Cover spaces, quotes, Unicode, and shell metacharacters.
- The project association is not a filesystem sandbox. User commands and shell startup files may change directories, access other files, or contact servers. Label the root as **Project**, not **Current Directory**, unless validated shell integration can report the latter.
- Missing/moved folders leave a stopped tab with task 07's relocation/retry path. Never substitute the home directory, app bundle, or another project.

## Native terminal and launch architecture

Prototype a pinned SwiftTerm package with its AppKit `TerminalView` and PTY-backed local-process support. SwiftTerm documents a reusable macOS view and `LocalProcessTerminalView` for running Unix commands through a pseudo-terminal; its current main documentation describes the 2.0 API. Pin a tested release/revision and its license during the spike instead of mixing 1.x examples with 2.x interfaces. [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

A retained native host owns terminal presentation. A separate `ProjectTerminalSession` owns immutable project context, launch generation, lifecycle state, PTY/process identity, I/O, and teardown. Adapt that division to the library after proving ownership in the prototype. Never launch from `body`, `onAppear`, or view reattachment. Do not use a stdout text view in place of terminal emulation.

Support controlling-terminal/job-control semantics, alternate screens, ANSI colors, cursor movement, Unicode/graphemes, IME, bracketed paste, selection/find, scrollback, and resize. Use a reviewed spawn facility appropriate for a multithreaded GUI; do not run arbitrary Swift/Foundation work in a post-fork child. Send PTY dimension changes to the running foreground application. Serialize launch, output, resize, exit, and shutdown against the session generation.

Use small built-in launch descriptors, with shared PTY/lifecycle code:

| Profile | Launch contract |
| --- | --- |
| Shell | Validated user account shell or machine-local override, with its supported interactive/login arguments and project-root initial directory. Normal shell startup configuration runs as part of explicit launch. |
| Claude Code | Resolved `claude` executable in normal interactive mode, with the captured project root and no automatically submitted prompt. |
| Codex | Resolved `codex` executable in interactive mode, with the captured project root; use the supported isolated-session option described below. No automatically submitted prompt. |

Use executable URLs and argument arrays. Resolve from a documented bounded search of `PATH`, supported install locations, and a native executable picker/override. Validate again at launch. Finder-started db3 must work despite its restricted environment; do not scrape shell startup output or recursively search repositories for executables. Discovery must not execute project files. Document the exact supported shell/environment policy during the spike.

Keep executable paths, terminal preferences, and the preferred launch profile in private machine settings; portable `.db3/project.json` is not a launch script. Supply terminal/locale variables consistent with the tested emulator. Preserve ordinary CLI configuration locations; do not rewrite `HOME`, `CODEX_HOME`, authentication storage, or user config to disguise db3 as another product. Do not source `.env`, inject saved db3 database credentials, or log process environments.

CLIs remain user-installed and user-updated. A missing/invalid executable shows a native actionable state with **Choose Executable**, **Retry**, and an official installation link. No automatic installer/updater, package manager, or privilege escalation is part of this task. Detect capabilities with bounded version/help checks against the explicitly resolved executable; record a tested compatibility baseline, and report unsupported required options without silently weakening lifecycle behavior.

### Claude Code

Leave Claude Code's standard interactive permissions and authentication intact. Users sign in through its own flow; db3 neither reads nor proxies credential files/tokens. Anthropic's current documentation permits platforms to host the unmodified binary with users authenticating and paying under their own accounts, while a custom SDK product has different subscription-login constraints. Keep db3 branding and accurately label the launcher. [Installation](https://code.claude.com/docs/en/setup), [hosting/authentication rules](https://code.claude.com/docs/en/legal-and-compliance).

The CLI handles its project instructions, settings, skills, history, and resume commands. db3 does not regenerate those files, parse transcripts into native chat, or add permission-bypass flags. The user's explicit launch may load/execute normal CLI configuration, unlike passive project inspection.

### Codex CLI

Support the actual interactive `codex` program, not `codex exec` or the VS Code addon. Official documentation describes starting it in a project directory and authenticating through ChatGPT or an API key. Keep that flow inside Codex's own onboarding; account eligibility and usage remain governed by the user's account. [Codex CLI](https://learn.chatgpt.com/docs/codex/cli), [authentication](https://learn.chatgpt.com/docs/auth).

The installed CLI's `--help`, inspected on the planning date, exposes `--cd`, `--no-daemon`, and `--no-alt-screen`. For the direct Codex launcher, require a tested CLI version with `--no-daemon` and launch with that option plus the captured root via `--cd`/child working directory. This gives the tab a session it can own instead of attaching to an unrelated shared background server. Confirm this behavior in the process spike; a help flag alone is not proof of complete descendant cleanup. Never stop a shared Codex daemon or other app's sessions to close db3's terminal.

Use normal terminal mode by default; a tested native preference may expose inline mode through `--no-alt-screen` when users prefer terminal scrollback. Keep model, approvals, sandbox, project trust, and resume choices under Codex's supported configuration/UI. Do not add worktree creation, approval/sandbox bypass, global profile rewrites, or a forced model. Users may resume through Codex's own commands; db3 does not reconstruct conversation state from terminal bytes.

When a user manually starts an agent from Shell mode, it follows that tool's own configuration, including possible shared/background services. db3 owns its shell/PTY and verified descendants, not every service that command contacts. Closing the terminal must not claim to stop independently hosted work. Native status describes terminal-process state, not inferred agent task completion.

## Shared tab model, commands, and focus

Use one explicit workspace tab identity/kind for query, object grid, project file, and terminal, with separate resource owners/admission budgets. Coordinate this with tasks 09/12/13; do not create a competing tab registry or a dummy `Worksheet`.

The current `WorkbenchModel.active` falls back to the first worksheet when selection does not match one. Replace visible command routing with a typed selected tab and optional/capability-checked database target. Otherwise selecting a terminal could run, save, cancel, or close a hidden query. Audit toolbar/menu actions, keyboard shortcuts, close coordinators, inspector, sample-data actions, and connection editing.

| Action | Terminal behavior |
| --- | --- |
| Tab selection/reorder/next/previous | Preserve live process and screen; restore terminal focus in visible order. |
| Position shortcuts | Use `⌘1`–`⌘9` for the first nine mixed tabs, disabling absent positions. Initially at most five positions exist; task 12 adds files and task 13 scopes these keys to the active group. Later positions stay reachable through cycling/overflow/menu. |
| `⌘T`, existing `⌘N`, tab-row `+` | Continue to create a query tab; expose project launch profiles through native project/menu actions or the add menu. |
| `⌘W`, close button, middle-click | Close the captured terminal through its lifecycle coordinator, including inactive-tab close. |
| SQL Run/Cancel/Save, export, transaction commands | Unavailable; `⌘Return`/`⌘.` must never reach hidden worksheet callbacks. |
| Copy/Paste/Select All/Find | Route to the actual terminal responder and its supported native behavior. |
| `Ctrl-C`, `Ctrl-D`, arrows, Option combinations | Send terminal input according to its key mapping/line discipline; do not translate to database commands. |
| Inspector | Hide database inspector content for terminal selection while preserving its workspace preference. |

Keep sidebar connection selection independent. A new query from terminal focus uses the explicitly selected browser profile or no profile, not a hidden worksheet's fallback. SQL/grid/file state and undo survive terminal navigation.

Inactive terminal hosts remain retained but excluded from hit testing/accessibility. Continue bounded PTY consumption/emulation while reducing offscreen rendering. Restore focus without stealing it from sheets or interrupting another view's IME composition. Validate actual VoiceOver, selection, terminal mouse reporting, and key behavior on the selected SwiftTerm version.

## Close, project switching, and recovery

Model **Stopped**, **Starting**, **Running**, **Stopping**, **Exited**, and **Failed**. Running means the terminal process is alive; db3 does not assume a shell is idle. Preserve bounded output and exit code/signal after exit with an explicit **Restart** action. Do not retry/restart automatically on silence, tab selection, wake, or application restoration.

Use one idempotent path for stop/restart, tab close, project close/replacement, workspace close, and quit:

1. Capture project/tab IDs and process generation. For a live/starting terminal, offer **Stop and Close** / **Keep Open**, explaining that commands may be interrupted. Already stopped/exited tabs need no process-stop decision.
2. Gather terminal and existing SQL/grid/file decisions before destructive teardown. Revalidate after awaits. Cancelling any decision or failing required recovery persistence keeps the original project and sessions open.
3. After approval, block new input/starts, cancel pending launch, and perform bounded orderly PTY/session shutdown. Handle foreground/background job-control groups, reap owned children, and release descriptors/read sources exactly once. Escalation targets only verified owned processes; never kill by name or reused PID. Prove descendant cleanup rather than assuming parent exit stops all jobs.
4. Fence late output/start/exit callbacks, drain only a bounded tail, and release the host after confirmed teardown. A shutdown failure stays visible and blocks unverified replacement sessions.

Task 07's project replacement gains a terminal exception: stop/remove the old project's terminal before completing replacement; **Keep Open** cancels the project change. Preserve SQL/grid tabs. Task 12 coordinates its file-document decisions in this same operation. Never rename a running terminal to the new project or send a `cd` command to retarget it. Watcher/project publication follows the accepted transition.

Closing the active terminal selects its right neighbor, otherwise its left. Create task 04's fresh disconnected query only when the entire workspace has no tabs, not merely when its last worksheet closes while files/terminal remain. Window/app teardown creates no replacement. Task 13 carries this invariant across groups and dock placement.

Version recovery once across the new tab kinds. Store terminal identity/order, original project reference, and launch profile/preferences privately; never store PTY bytes, scrollback, typed commands, PIDs, environment, credentials, or agent transcripts. Shell/CLI history remains those programs' responsibility.

Restore a **stopped placeholder**. Explicit Start requires resolving its original project, with no fallback to the currently selected folder. Do not replay input, restart jobs, or reuse saved PIDs. Persistent daemons, disowned jobs, or survival across app crashes are not guaranteed; report cleanup limits honestly rather than claiming control of independently detached processes.

## Performance and terminal output

Keep executable/filesystem work, PTY I/O, waiting/reaping, and process inspection off the main actor. Feed the emulator in bounded ordered batches and coalesce rendering; use only library-supported concurrency. If its view requires main-thread feeds, prove bounded short feeds rather than moving AppKit work to detached tasks.

| Resource | Initial target to validate |
| --- | --- |
| Live terminals | One per active project/workspace. |
| Scrollback | 10,000 lines and 16 MiB accounted storage, whichever binds first; account for long lines/cell attributes. |
| Pending output | 1 MiB queued application bytes, with backpressure and no dropped/reordered escape-sequence bytes. |
| Paste queue | 1 MiB per paste initially; reject oversize explicitly rather than truncating. |
| UI work | Coalesced display updates; target main-thread slices below 5 ms, investigate any above 50 ms. |
| Disk recording | Disabled; scrollback is memory-only. |

Bound screen/parser/title/link/search storage and optional image buffers too. Disable image/recording features initially unless demonstrably bounded. Revise unsupported budgets based on the prototype, not assumed library behavior. These are terminal-buffer targets, not total memory ceilings for child programs; measure app and agent CPU/memory separately.

Honor bracketed paste; when unavailable, confirm multiline/control-character paste because newlines may execute commands. Clipboard access follows explicit Copy/Paste; terminal-initiated clipboard access is disabled initially. Output may not silently open URLs, execute host commands, resize the app window, or change project association. Support explicit HTTP(S) link activation through the terminal delegate boundary.

Terminal programs execute outside db3's SQL review workflow. They receive no automatic connection binding or selected-row context. Explain in terminal help that db3's preview/commit controls do not govern database clients a user launches manually. Project file edits from either agent use task 07's reconciliation and task 12's external-change conflict handling.

## Delivery and verification

1. **Native spike:** pin SwiftTerm, prove packaging, PTY job control, both interactive agent CLIs, Unicode/IME, resize, bounded output, accessibility, and cleanup. Verify the supported CLI capabilities without relying on private extension binaries or undocumented protocols.
2. **Shared tabs:** implement kind-aware routing, independent admission, retained hosts, project capture, and compatible stopped-placeholder recovery.
3. **Launch profiles:** implement Shell/Claude Code/Codex, executable settings/discovery, native launch/error/restart controls, and official installation/authentication guidance.
4. **Lifecycle:** coordinate stop/project switch/quit with existing document and database decisions, including pending-launch and late-callback races.
5. **Acceptance:** run focused headless/process tests and Debug/Release builds, then native interaction and real CLI checks. Use fake agent fixtures for routine tests; they do not establish actual Claude/Codex compatibility.

- [ ] No project, passive inspection, restoration, sidebar/panel visibility changes, and stopped-tab selection spawn nothing. Explicit launch uses the captured root, including unusual path characters.
- [ ] Four database tabs plus terminal/file budgets work independently; position shortcuts, reorder, inactive close, focus, and final-tab fallback work across kinds.
- [ ] Terminal focus cannot run/save/cancel/commit a hidden query. SQL/grid/file undo, drafts, transactions, inspector preference, and new-query connection rules remain correct.
- [ ] Shell and both real CLIs handle alternate screen, colors, Unicode, multiline prompts, paste, copy/find, resize, and tab switching. Full-screen fixtures and noisy output demonstrate bounded buffers and responsive SQL editing.
- [ ] Missing/replaced/non-executable paths, Finder-style environment, unsupported required flags, normal login, CLI exit, and explicit restart yield actionable states without automatic installation/credential copying.
- [ ] Codex direct launch is isolated from shared daemon sessions. Shell-launched shared services are never killed or falsely reported stopped.
- [ ] Start/close, exit/restart, output/teardown, project replacement, and quit races release verified owned processes/descriptors. Cancelled decisions and recovery-write failures preserve live sessions.
- [ ] Old snapshots migrate; restored terminals stay stopped; missing/mismatched projects never launch elsewhere. Recovery/logs exclude terminal data, credentials, and environment.
- [ ] Repeated open/start/stop/close cycles release hosts and observers. Measure app and child memory/CPU, launch latency, and input/resize response independently.

Local builds, tests, and app launch/restart through CLI follow existing development authorization. Screenshots, UI-state inspection, browser automation, and mouse/keyboard computer control require fresh explicit permission immediately before that verification session. Real agent verification uses the user's normal login and an explicitly authorized prompt; routine fixtures do not spend model usage.

## Follow-ups

Multiple terminals, richer shell integration, explicit **Ask Claude/Codex** context attachments, MCP tools, opening proposed SQL in a worksheet, and fully native chat are separate scopes. A later native Codex client can evaluate its documented app-server interface; that is not needed to embed its CLI. Any context bridge must define shared source/schema/result data and preserve db3's query review/execution contracts.
