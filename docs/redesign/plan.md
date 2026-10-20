# Provider-Agnostic Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn ClaudeConfig from a Claude-Code-only editor into an app that detects every installed LLM coding agent and lets a person operate each one's config, with Claude Code as the first provider.

**Architecture:** A `Provider` protocol in ConfigCore describes one agent: how to detect it, its config paths, the config kinds it supports, and how to ask its model. Today's Claude code moves behind `ClaudeProvider` unchanged in behaviour. The app sidebar groups screens by detected provider and shows only the kinds that provider reports. Visual layer is rebuilt on GitHub Primer tokens.

**Tech Stack:** Swift 6 package, SwiftUI (macOS 14+), Swift Testing (`Tests/ConfigCoreTests`), no new dependencies in v1.

**Spec:** this document (sections "Decisions" to "Cut list") plus `docs/redesign/audit.md`. The user was not available to brainstorm (they opted out of questions), so every decision below is the planner's call unless marked otherwise.

## Open questions (need the user)

1. **TOML writes for Codex.** `~/.codex/config.toml` is TOML; there is no TOML library in the package. v1 plan: Codex settings/MCP are shown parsed read-only and edited as whole-file text (with backup). Should we add a TOML dependency (e.g. TOMLKit) for structured edits?
2. **Keep Discover or Community?** The plan keeps Community (install skills into any provider) and cuts the Discover screen. Reverse if Discover is the one you use.
3. **Analytics.** The plan cuts Analytics/ccusage (audit #8, unpinned npx). If you look at cost charts weekly, say so and we pin `ccusage` instead.
4. **Which provider answers Ask AI** when several are installed: plan defaults to the provider whose screen is open, falling back to Claude Code. Do you want one global choice instead?
5. **App and CLI names.** "ClaudeConfig" / `claude-config` no longer fit. Plan keeps the names in v1 (renaming touches bundle id, backups path, user habits). Rename later?

## Installed on this machine (checked 2026-10-19)

| Provider | Binary | Config found | Status |
|---|---|---|---|
| Claude Code | `claude` (cmux shim on PATH; app looks in `~/.local/bin` etc.) | `~/.claude/`, `~/.claude.json` | installed, first provider |
| Codex CLI | `/opt/homebrew/bin/codex` 0.163.0 (cask; PATH copy is a cmux wrapper) | `~/.codex/config.toml`, `hooks.json`, `rules/default.rules`, `skills/` | installed |
| Gemini CLI | `/opt/homebrew/bin/gemini` 0.46.0 | `~/.gemini/settings.json` (keys `security`, `hooks`), `GEMINI.md`, `extensions/superpowers` | installed |
| opencode | not on PATH | `~/.config/opencode/opencode.jsonc`, `skills/` | config only: detect as "config present, CLI missing" |
| Cursor (cursor-agent) | not found | no `~/.cursor`, no `/Applications/Cursor.app` | not installed; provider written, tested on fixtures only |
| Ollama | not found | no `~/.ollama` | not installed; model backend only |

Detection lesson: PATH lookups hit wrappers (cmux shims). Detection checks fixed install spots first, then PATH, and records the resolved path.

## Decisions

- **Provider = an agent with a config tree.** Ollama is a `ModelBackend` only (no config kinds), shown under "Models" in Settings, never as a sidebar group. My call.
- **Kinds:** `settings, memory, skills, agents, commands, mcp, hooks, permissions`. Each provider returns the subset it supports; the UI hides the rest (no disabled rows).
  | Kind | Claude | Codex | Gemini | Cursor | opencode |
  |---|---|---|---|---|---|
  | settings | `~/.claude/settings*.json` | `~/.codex/config.toml` | `~/.gemini/settings.json` | `~/.cursor/cli-config.json` | `~/.config/opencode/opencode.json[c]` |
  | memory | `CLAUDE.md`, `CLAUDE.local.md` | `~/.codex/AGENTS.md`, project `AGENTS.md` | `~/.gemini/GEMINI.md`, project `GEMINI.md` | project `.cursor/rules/*.mdc`, `AGENTS.md` | `~/.config/opencode/AGENTS.md`, project `AGENTS.md` |
  | skills | `~/.claude/skills` | `~/.codex/skills` | `~/.gemini/extensions/*/skills` | - | `~/.config/opencode/skills` |
  | agents | `~/.claude/agents` | - | - | - | `~/.config/opencode/agent` |
  | commands | `~/.claude/commands` | `~/.codex/prompts` | `~/.gemini/commands` (toml) | - | `~/.config/opencode/command` |
  | mcp | `~/.claude.json`, `.mcp.json` | `config.toml [mcp_servers]` | `settings.json mcpServers` | `~/.cursor/mcp.json` | `opencode.json mcp` |
  | hooks | settings `hooks` | `~/.codex/hooks.json` | settings `hooks` | - | - |
  | permissions | settings `permissions` | `~/.codex/rules/*.rules` (read-only v1) | settings `tools.allowed/exclude` | `cli-config.json permissions` | `opencode.json permission` |
  Paths are taken from each tool's docs as of this date; Task 3 pins them in tests so a wrong guess fails loudly. Gemini "commands" are TOML: read-only v1.
- **Model calls:** `Provider.ask` generalises `ClaudeCLI.ask`: fresh empty temp cwd, scrubbed env (HOME/USER/LOGNAME/TMPDIR/LANG/PATH only), no user config/MCP/hooks, prompt on **stdin**, default 120 s timeout, kill on cancel, stderr tail returned as error (fixes audit #6). Per-provider read-only flags:
  - Claude: existing `askArgs` (`--setting-sources ""`, `--strict-mcp-config`, `disableAllHooks`, etc.).
  - Codex: `codex exec --sandbox read-only --skip-git-repo-check --ephemeral -` (verify `--ephemeral` exists in 0.163; if not, drop it).
  - Gemini: `gemini -p` with `--approval-mode default` and `--sandbox`; no tools allowed.
  - Cursor: `cursor-agent -p --output-format text` (no `--force`), when installed.
  - Ollama: `ollama run <model>` on stdin; no tools exist.
  A provider whose sandbox can't be confirmed in a test returns `nil` for `askCommand` and the UI hides Ask for it.
- **Writes:** one writer, `ConfigWriter.mutate` (today's `SettingsEdit.mutate` generalised, audit #4): refuses unparseable existing files, backs up to `Paths.appBackups/<provider>/...` before every write, unique temp name, keeps file mode and key order, mtime check. Every path is checked against `provider.ownedPaths(home:projects:)`; anything else throws `WriteError.outsideKnownPaths`.
- **Design system: GitHub Primer (Primer Primitives, MIT).** Reason: it was built for developer tools that show code, config, diffs and status all day, and its functional color roles (`fg.default/muted`, `accent`, `success`, `attention`, `danger`, `done`) come with light, dark and high-contrast themes whose contrast GitHub tests; that fixes the audit's raw `.red/.green` use and dark-mode `.tertiary` contrast directly. Its type stack is the system font, so on macOS it maps to SF Pro / SF Mono with no font bundling. Considered and dropped: IBM Carbon (heavier enterprise look, IBM Plex bundling), Radix Colors (palette only, no component vocabulary).
  - Tokens (`Sources/ClaudeConfig/Primer/Tokens.swift`): `PColor` roles above, each with `.emphasis/.muted/.subtle` variants and light/dark/high-contrast values from Primer Primitives `functional/themes`; `PSpace` 4-pt scale `0,4,8,12,16,24,32,40`; `PRadius` `small 3, medium 6, large 12, full`; `PType` `title (20 semibold), subtitle (16 semibold), body (13), caption (11), mono (SF Mono 12)` all via `Font.TextStyle` so Dynamic Type scales; `PBorder` `default 1pt borderColor.default`.
  - Components (`Primer/Components.swift`): `PButton` (`.primary/.default/.danger/.invisible`), `PLabel` (state pill with text, never color alone), `PCounter`, `PFlash`/`PBanner` (info/success/warning/danger, replaces toast styling), `PBox` (border box with header/rows, replaces `Card`), `PBlankslate` (empty state with one action), `PSegmented` (scope switcher). Icons stay SF Symbols (Octicons would need an asset pipeline: skipped).
  - Restraint: one accent (Primer `accent` blue) for primary actions and selection only; provider identity shown by name and SF Symbol, not by per-provider colors.

## Information architecture (new sidebar)

```
Overview            one Review list across all providers (issues + context budget folded in)
Claude Code         Settings · Memory · Skills · Agents · Commands · MCP · Hooks · Permissions · Plugins
Codex               Settings · Memory · Skills · Commands · MCP · Hooks · Permissions
Gemini CLI          Settings · Memory · Skills · Commands · MCP · Hooks · Permissions
opencode (no CLI)   ...kinds it reports
Library             Skills catalogue (Community install, target = any provider) · Backups · Disk (Storage + Projects & History merged)
```
Only detected providers appear. A provider's group shows only `supportedKinds`. Plugins stays a Claude-only extra kind (`.plugins`), not part of the shared table.

## Cut list (doesn't help a person operate their agent)

| Cut | Files | Why |
|---|---|---|
| Analytics + ccusage | `AnalyticsView.swift`, `Analytics.swift`, `Usage.swift` | cost history, not an action; unpinned `npx` risk (audit #8); `ccusage` exists standalone |
| Skill map Sankey | `SkillMapView.swift` (685 lines), `SkillMap.swift` | pretty view of a list the table shows; no a11y |
| Guide screen + glossary | `GuideView.swift`, `Glossary.swift` | generic advice Review "why" lines already give |
| Discover screen | `DiscoverView.swift` | duplicate catalogue of Community (open question 2) |
| GitHub stars loader | `AppModel.loadStars` | popularity isn't operation; burns API calls |
| App update checker | `AppModel.checkForAppUpdate` | `git pull` covers it |
| Daily automatic skill analysis at launch | `AppModel.analyzeSkillsIfNeeded` trigger | unasked model calls; keep the button |
| Context Budget as its own screen | `context` section | folded into Overview |
| Overlapping rankers | `Advice` + `Recommendations` + `SkillMap` ranking | keep `SkillPick`, delete the rest |
| `--backups` CLI flag | `Sources/claude-config/main.swift` | hidden second tool; Backups screen covers it |
| Other-tool `.bak` manifest guessing | `BackupFiles` manifest/README parsing (~80 lines) | guesswork restore of foreign files |
| Dead code | `AnswerBlocks.codeBlocks`, `Backup.list` | no callers |

Merges (not cuts): Storage + Projects & History into Disk; three Ask entry points keep one engine (`Provider.ask`).

## Global Constraints

- Back up every file before any write; backups go under `~/.claude/config-editor-backups/<provider-id>/` (kept path for continuity), never inside a provider's own rotating backup folder.
- All model calls go through `Provider.ask` / `ModelSandbox.run`: temp empty cwd, scrubbed env, no user config, prompt on stdin, 120 s default timeout, process killed on cancel.
- No write outside `provider.ownedPaths`; enforced in `ConfigWriter`, tested.
- Tests live in `Tests/ConfigCoreTests` and use fixture homes (`CLAUDE_CONFIG_EDITOR_HOME`), never the real `~`.
- The app runs headless/background only during development and verification: `open -g`, no `activate`, no focus-stealing tools; screenshots by window-targeted capture. Subagents are told the same.
- No new package dependencies in v1.
- Every existing test keeps passing at every commit (`swift test`).

## Review Focus

1. **Corrupt or half-written config file** (Claude mid-write): writer must refuse, not rewrite with one key. Test in Task 2.
2. **Binary on PATH is a wrapper/shim** (cmux): detection must still find the real install and report it; test in Task 3 with a fake shim dir.
3. **Config present but CLI missing** (opencode here): provider shows config, hides Ask. Test in Task 3.
4. **Project outside home** (`/Volumes/...`): backup and write must work or fail loudly before writing. Test in Task 2.
5. **Model CLI hangs or isn't signed in:** call ends at timeout with the stderr reason, no orphan process. Test in Task 4 with a fake executable that sleeps / prints to stderr.

## File structure

- Create `Sources/ConfigCore/Providers/Provider.swift` (protocol, `ConfigKind`, `ProviderID`, `Detection`, `ModelBackend`)
- Create `Sources/ConfigCore/Providers/{Claude,Codex,Gemini,Cursor,OpenCode}Provider.swift`, `OllamaBackend.swift`, `ProviderRegistry.swift`
- Create `Sources/ConfigCore/ModelSandbox.swift` (generalised `ClaudeCLI.ask` runner)
- Create `Sources/ConfigCore/ConfigWriter.swift` (from `SettingsEdit.mutate`)
- Modify `Files.swift`, `ScopeMove.swift`, `SettingsEdit.swift`, `Memory.swift`, `Backup.swift`, `CLI.swift`, `Checks.swift` (`AppSection`)
- Create `Sources/ClaudeConfig/Primer/{Tokens,Components}.swift`; delete `Theme.swift` in Task 8
- Modify `App.swift`, `AppModel.swift`, all views for tokens
- Tests: `Tests/ConfigCoreTests/{ProviderDetectionTests,ProviderPathTests,ConfigWriterTests,ModelSandboxTests}.swift`, fixtures under `Tests/ConfigCoreTests/Fixtures/providers/<id>/`

---

### Task 1: Provider protocol and ClaudeProvider (no behaviour change)

**Files:** Create `Providers/Provider.swift`, `Providers/ClaudeProvider.swift`, `Providers/ProviderRegistry.swift`. Test `ProviderDetectionTests.swift`.

**Interfaces (Produces):**
```swift
public enum ConfigKind: String, CaseIterable, Sendable { case settings, memory, skills, agents, commands, mcp, hooks, permissions, plugins }
public struct ProviderID: RawRepresentable, Hashable, Sendable { public let rawValue: String } // "claude", "codex", "gemini", "cursor", "opencode"
public struct Detection: Sendable { public let executable: URL?; public let configRoot: URL?; public var installed: Bool { executable != nil || configRoot != nil } }
public struct AskCommand: Sendable { public let executable: URL; public let args: [String]; public let env: [String: String] }
public protocol Provider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var symbol: String { get }                        // SF Symbol
    func detect(home: URL, env: [String: String]) -> Detection
    var supportedKinds: Set<ConfigKind> { get }
    func paths(for kind: ConfigKind, home: URL, project: URL?) -> [URL]
    func ownedPaths(home: URL, projects: [URL]) -> [URL]   // roots a write may touch
    func askCommand(model: String?, detection: Detection) -> AskCommand?  // nil = no sandboxed ask
}
public enum ProviderRegistry { public static let all: [any Provider]; public static func detected(home: URL, env: [String: String]) -> [(any Provider, Detection)] }
```
- [ ] Step 1: Test `claudeDetectedFromFixture`: fixture home with `.claude/settings.json` → `ProviderRegistry.detected` contains id `"claude"`, `supportedKinds == [.settings,.memory,.skills,.agents,.commands,.mcp,.hooks,.permissions,.plugins]`.
- [ ] Step 2: Test `claudePathsMatchPaths`: `paths(for: .settings, home: h, project: nil)` equals `[h/.claude/settings.json, h/.claude/settings.local.json]`; `.mcp` includes `h/.claude.json`; project `.mcp` adds `p/.mcp.json`.
- [ ] Step 3: Run `swift test --filter ProviderDetectionTests` → FAIL (types missing).
- [ ] Step 4: Implement; `ClaudeProvider` reads from existing `Paths` (no path duplication), `askCommand` wraps `ClaudeCLI.askArgs`/`askEnvironment` without the prompt (prompt goes on stdin in Task 4).
- [ ] Step 5: `swift test` → all pass. Commit `feat(core): Provider protocol with ClaudeProvider`.

### Task 2: Single safe writer (`ConfigWriter`), audit #1 #3 #4 #5 #13 #14 #15

**Files:** Create `ConfigWriter.swift`; modify `SettingsEdit.swift`, `Files.swift` (`updateSettingsKey`, `removeHooks`, `safeWrite`), `ScopeMove.swift` (`setJSON`, move backup), `Memory.swift` (`removeLines`), `Backup.swift`, `FixSheet.swift:184`. Test `ConfigWriterTests.swift`.

**Interfaces:**
```swift
public enum WriteError: Error, Equatable { case unparseable(URL), changedOnDisk(URL), outsideKnownPaths(URL), backupFailed(URL) }
public enum ConfigWriter {
    public static func mutateJSON(_ url: URL, provider: any Provider, home: URL, projects: [URL], expectedModified: Date?, _ edit: (inout [String: Any]) throws -> Void) throws -> URL  // returns backup URL
    public static func writeText(_ text: String, to url: URL, provider: any Provider, home: URL, projects: [URL], expectedModified: Date?) throws -> URL
}
public static func removeLines(at indices: IndexSet, in url: URL, expectedModified: Date?) throws  // Memory
```
- [ ] Step 1: Tests: `corruptFileIsRefused` (file `{"a":` → throws `.unparseable`, bytes unchanged); `writeOutsideOwnedPathsRefused` (`/tmp/x.json` → `.outsideKnownPaths`); `backupBeforeWrite` (backup exists under `config-editor-backups/claude/` with old bytes); `keepsKeyOrderAndMode` (file mode 0644 and key order preserved); `projectOutsideHomeBacksUp` (project at a temp dir outside fixture home → backup under `abs/`); `removeLinesByIndexKeepsDuplicates` (three `- ` lines, remove index 1 → two remain); `hookRemovalMatchesMatcher`.
- [ ] Step 2: Run → FAIL.
- [ ] Step 3: Implement; existing four writers become calls into `ConfigWriter`; `Backup.relative` stores out-of-home paths under `abs/<full path>`; undo dir moves to `Paths.appBackups/undo` (read old `~/.claude/backups/config-editor` for restore, write new only).
- [ ] Step 4: `swift test` → all pass, including existing `SettingsEditTests`, `ScopeMoveTests`, `MemoryTests`. Commit `fix(core): one guarded writer for every config file`.

### Task 3: Codex, Gemini, Cursor, opencode providers + detection

**Files:** Create the four provider files; register in `ProviderRegistry.all`. Fixtures `Fixtures/providers/{codex,gemini,cursor,opencode}/`. Test `ProviderPathTests.swift`, extend `ProviderDetectionTests.swift`.

**Interfaces:** each conforms to `Provider` (Task 1). `supportedKinds` and paths exactly as the "Decisions" table.
- [ ] Step 1: Per provider, test `<id>PathMapping`: every row of the table for that provider equals the expected URL under fixture home `h` (and project `p` where listed). Test `<id>KindsHideUnsupported`: e.g. Codex `supportedKinds` lacks `.agents`, Cursor lacks `.skills,.hooks`.
- [ ] Step 2: Detection tests: `shimOnPathResolvesRealBinary` (env PATH has a dir with a `codex` script; fixture `/opt/homebrew/bin`-equivalent passed via an injected `installSpots: [URL]` default param → detection prefers install spot); `configWithoutCLI` (opencode config only → `installed == true`, `executable == nil`, `askCommand == nil`); `nothingInstalled` (empty home → detected list empty).
- [ ] Step 3: Run → FAIL. Step 4: implement. Codex/Gemini-commands TOML parsed read-only with a minimal key/table reader for display only (`shortcut: display only, upgrade with a TOML lib if structured edits are needed`, open question 1).
- [ ] Step 5: `swift test` → pass. Commit `feat(core): Codex, Gemini, Cursor, opencode providers`.

### Task 4: `ModelSandbox` generalises `ClaudeCLI.ask` (audit #2 #6)

**Files:** Create `ModelSandbox.swift`, `Providers/OllamaBackend.swift`; modify `CLI.swift` (`ClaudeCLI.ask` → thin call), `AskClaudeBar.swift` (no `--add-dir ~/.claude`: copy listed files into the ask cwd instead). Test `ModelSandboxTests.swift` (existing `AskSandboxTests`, `CLIIsolationTests` must still pass).

**Interfaces:**
```swift
public struct AskFailure: Error, Sendable { public let reason: String }  // stderr tail or "timed out after 120s"
public enum ModelSandbox {
    public static func run(_ cmd: AskCommand, prompt: String, files: [URL] = [], timeout: TimeInterval = 120) async -> Result<String, AskFailure>
}
public protocol ModelBackend: Sendable { var id: String { get }; func detect(home: URL, env: [String: String]) -> URL?; func askCommand(model: String, exe: URL) -> AskCommand }
```
- [ ] Step 1: Tests with fake executables in a temp dir: `promptGoesOnStdin` (script echoes stdin → result equals prompt); `timeoutKillsProcess` (script `sleep 30`, timeout 1 → `.failure` containing "timed out", process gone); `stderrSurfaced` (script writes "not logged in" to stderr, exit 1 → failure reason contains it); `envScrubbed` (script prints env → only allowed keys); `cwdIsEmptyTemp`; `filesCopiedNotDirGranted` (listed file readable in cwd, `~/.claude` not passed); per-provider `askArgs` snapshot tests (Claude args unchanged from today; Codex contains `--sandbox read-only`; Gemini contains `--sandbox`).
- [ ] Step 2: FAIL. Step 3: implement with `withTaskCancellationHandler { process.terminate() }`. Step 4: pass. Commit `feat(core): sandboxed asks per provider, stdin prompt, timeout, real errors`.

### Task 5: Primer tokens and components

**Files:** Create `Sources/ClaudeConfig/Primer/Tokens.swift`, `Components.swift`. (UI module has no test target; verify by build + headless screenshot.)

**Interfaces:** `PColor`, `PSpace`, `PRadius`, `PType`, `PButton`, `PLabel`, `PCounter`, `PFlash`, `PBox`, `PBlankslate`, `PSegmented` as in "Decisions". Colors via `Color(nsColor: NSColor(name:dynamicProvider:))` switching on `appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])`, hex values copied from Primer Primitives v10 `light`, `dark`, `light_high_contrast`, `dark_high_contrast`.
- [ ] Step 1: Implement tokens; every component takes a text label and sets `.accessibilityLabel`; `PLabel` always renders text plus color.
- [ ] Step 2: `swift build` passes. Commit `feat(ui): Primer tokens and components`.

### Task 6: Provider-grouped sidebar; unsupported kinds hidden

**Files:** Modify `Checks.swift` (`AppSection` → `enum Screen: Hashable { case overview, kind(ProviderID, ConfigKind), library(LibraryScreen) }`; rename swapped `mySkills`/`skills`), `App.swift`, `AppModel.swift` (snapshot per provider: `[ProviderID: Snapshot]`, cached `issues` recomputed only in `refresh`, audit #17). Test `ScreenContextTests`/`SkillsScreenTests` updated; new test `sidebarHidesUnsupportedKinds` in ConfigCore (`Screen.sidebar(for: detected)` is pure and lives in ConfigCore).

**Interfaces:** `public static func sidebar(for detected: [(any Provider, Detection)]) -> [(title: String, screens: [Screen])]`.
- [ ] Step 1: Test: detected = [Claude, Cursor] → Claude group has 9 screens incl. `.plugins`; Cursor group has exactly `settings, memory, mcp, permissions`; no Codex group.
- [ ] Step 2: FAIL. Step 3: implement; non-Claude screens reuse the existing generic views (`AgentFilesView` for memory, skills table, settings JSON editor, MCP list) fed by `provider.paths(for:)`; Claude screens keep current views.
- [ ] Step 4: `swift test` pass; launch headless (`open -g` the built app with fixture `CLAUDE_CONFIG_EDITOR_HOME`), capture the window with `screencapture -l <windowID>`, check groups. Commit `feat(ui): sidebar grouped by detected provider`.

### Task 7: Apply the cut list

**Files:** delete files in the cut table; remove their `Screen` cases, `AppModel` loaders, tests that only cover cut code (`SkillMapTests`, Recommendations-only tests); drop `--backups` from `main.swift`. Merge Storage + Projects & History into `DiskView` (reuse both views' bodies).
- [ ] Step 1: Grep each symbol before deletion (`grep -rn <name> Sources Tests`) and remove callers.
- [ ] Step 2: `swift build && swift test` pass. Commit `chore: cut features that don't help operate an agent`.

### Task 8: Move every view onto Primer; delete Theme.swift; accessibility pass

**Files:** all `Sources/ClaudeConfig/*.swift`; delete `Theme.swift`.
- [ ] Step 1: Replace `Card`→`PBox`, `Space`→`PSpace`, raw `.red/.green/.orange`→`PColor.danger/success/attention`, `.font(.system(size:))`→`PType`; fixed widths → `@ScaledMetric`.
- [ ] Step 2: Accessibility: label every icon-only button (toast dismiss), VoiceOver summary for remaining charts, drop the toast's window-wide ⌘Z (audit #9), Ask auto-copy off by default.
- [ ] Step 3: `grep -rn "Theme\.\|Card(\|\.foregroundStyle(\.red\|\.system(size:" Sources/ClaudeConfig` → no hits. `swift build && swift test` pass. Headless screenshot in light, dark, high contrast. Commit `feat(ui): Primer across the app; accessibility fixes`.

## Self-review

- Coverage: Provider protocol (T1, T3), detection + path tests (T1, T3), model calls per provider (T4), UI grouped/hidden (T6), design system tokens/components replacing Theme.swift (T5, T8), cut list (T7), constraints (Global Constraints, T2 writer, T4 sandbox). Installed providers noted above.
- Audit Must-fix items 1-9 each land in T2, T4, T7 or T8; Should-fix 10-12, 16, 19 are not in a task: fix them inside T2 (10-11 touch `Apply`) or as follow-ups after this plan.
- Execution: recommend subagent-driven, because T2-T6 share interfaces (`Provider`, `ConfigWriter`, `Screen`) and a shipped writer mistake destroys agent config.
