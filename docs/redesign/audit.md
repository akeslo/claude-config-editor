# Audit: ClaudeConfig, ConfigCore, claude-config CLI

Date: 2026-10-19. Branch: `redesign-agnostic` (from `main` at merge `a188e46`). Method: `ponytail:ponytail-audit` over `Sources/ConfigCore`, `Sources/claude-config`, `Sources/ClaudeConfig`, plus a manual review of environment/data model, IA, UX flows, visual design and accessibility. No code changed; the app was not launched.

**What this repo does:** A macOS SwiftUI app (and a small CLI) that reads and edits a person's Claude Code setup: settings, CLAUDE.md memory, skills/agents/commands, plugins, MCP servers, hooks, permissions, backups, and asks the model about it through a sandboxed `claude -p`. Assumed load: one person on one Mac, but sharing config files with a live Claude Code process that writes them at any time.

**Ranking rule:** how much each finding matters to someone running an LLM coding agent day to day. Data loss of agent state first, then trust/secret leaks, then things that make the daily loop slow or confusing.

Baseline: `swift build` OK; `swift test` 191 tests in 34 suites passed.

## Must fix

1. **A failed read can wipe `~/.claude.json`** (`ScopeMove.swift:270-277`, `Files.swift:90-106`, `Files.swift:115-134`)
   - What: `setJSON`, `updateSettingsKey`, `removeHooks` start from `readJSON(url) ?? [:]`.
   - Problem: if Claude is mid-write or the file is corrupt, the parse fails and the file is rewritten with only the edited key. Projects, MCP servers, OAuth state gone (backup exists but nobody knows where).
   - Fix: reuse the guard in `SettingsEdit.mutate:63` (existing file that won't parse throws).
   - If skipped: rare total loss of agent state.
2. **Ask AI can read secrets the app says it masks** (`AskClaudeBar.swift:131-143`)
   - Outside Skills, Ask grants `Read/Grep/Glob` with `--add-dir ~/.claude`: model can open `settings.json` env, `.credentials.json`, transcripts.
   - Fix: pass only the files the screen lists (copy them into the ask cwd), never the whole dir.
   - If skipped: API keys and private transcripts leave the machine on any Ask.
3. **Removing one memory line removes every identical line** (`Memory.swift:311-318`)
   - Filters by text, so deleting one `- ` bullet, blank line or `---` deletes all copies; no modified-time check. No test.
   - Fix: remove by line index, add `expectedModified` check, one test with duplicate lines.
4. **Four JSON writers, four rule sets** (`Files.swift`, `SettingsEdit.swift`, `ScopeMove.setJSON`, `FixSheet.swift:184`)
   - They disagree on corrupt-file guard, backup folder, file mode, empty-parent cleanup. Root cause of 1, 5, 13, 15.
   - Fix: `SettingsEdit.mutate` becomes the single writer; others call it.
5. **Move proceeds when its backup fails** (`ScopeMove.swift:147`, `_ = try? Backup.snapshot`)
   - Project outside home: snapshot throws, move goes ahead without a copy. Fix: stop unless the backup succeeded. Related: `Backup.swift:36-40` refuses all paths outside home, so such projects can't be edited at all; store them under `abs/<full path>`.
6. **Model calls can hang forever and fail silently** (`CLI.swift:50-72`)
   - Timeout optional and unset except in the menu-bar picker; task cancel doesn't kill the process; stderr goes to `/dev/null` so sign-in, rate limit, bad model all show as "is claude installed?". Prompt is passed in argv (about 1 MB limit).
   - Fix: default 120 s timeout, `withTaskCancellationHandler { p.terminate() }`, return stderr tail as error, send prompt on stdin.
7. **Undo backups may live inside Claude's own rotation** (`Backup.swift:28`)
   - `~/.claude/backups/config-editor`; `Files.swift:18` notes Claude keeps 5 entries in `~/.claude/backups/`. Not verified whether it prunes subfolders. Fix: `Paths.appBackups/undo`.
8. **Unpinned `npx -y ccusage@latest` through a login shell** (`Usage.swift:52-53`, `AnalyticsView.swift:159`)
   - Whatever npm serves runs with the user's full env and can read every transcript. Fix: pin a version, or cut Analytics (see cut list).
9. **⌘Z restores a deleted file instead of undoing typing** (`EditActions.swift`, UndoToast `keyboardShortcut("z")`)
   - For 8 s the toast owns ⌘Z window-wide. Fix: drop the shortcut.

## Should fix

10. **Trash summary lies about refused items** (`Apply.swift:64-69`): refusals aren't counted; "Moved 0 items" with no error. Count them and name the right file.
11. **Crash on `mcp remove` when `-s` is last** (`Apply.swift:74`): bounds-check `args[i+1]`. Also `cliScope!` in `ConfigViews.swift:70-73` guarded only by a disabled button: use `guard let`.
12. **Settings field can change a value's type** (`SettingsEditorViews.swift:169-172`): typing "yes" into a bool writes the string `"yes"`. Refuse type-changing edits.
13. **Shared temp name for atomic writes** (`Files.swift:82`, `SettingsEdit.swift:69`): `.<name>.tmp` collides on concurrent writes; add a UUID.
14. **Edits reformat whole files** (`SettingsEdit.swift:68` `.sortedKeys`; `Files.swift:85` forces 0600 on committed project files): noisy git diffs and changed permissions. Drop `.sortedKeys`, keep original mode.
15. **Hook removal matched by command text only** (`Files.swift:120-124`): two hooks with the same command under different matchers both go. Match `matcher` too, like `ScopeMove.move(hook:)`.
16. **Secrets redaction covers one layout** (`ConfigViews.swift:79-86`): `--api-key x`, `Bearer ...`, `?token=` shown in clear. Also mask flag values and `sk-`/`ghp_`/`Bearer` prefixes.
17. **Main-thread work on every redraw**: `AppModel.issues` re-runs `Checks.run` about 18 times per refresh; `BackupsView.swift:82-88` re-diffs files each redraw (large `.claude.json.bak` freezes); file reads in `AgentFilesView.swift:157`, `SettingsEditorViews.swift:16`, `AskClaudeBar.swift:160`. Cache in state / `.task(id:)`.
18. **Untested write paths**: `ScopeMove.setJSON`/`editJSON` rollback, `Memory.removeLines`, `Apply.run` `.trash`/`.cli`. One test each (corrupt file, duplicate line).
19. **App caches written into `~/.claude`** (`AppModel.loadAdvice/loadCommunity`): clutters the folder the app tidies, errors ignored. Move to `~/Library/Caches/<bundle id>`.

## Nice to have

20. One `git check-ignore --stdin` per repo instead of one process per file (`Scanner.swift:392,430`). Merge the two `reveal()` helpers (keep the `open -R` one, which doesn't steal focus). Delete dead `AnswerBlocks.codeBlocks`, `Backup.list` (tests only). CSV export `try?` (`BulkUI.swift:122`) should surface errors.

## Manual review

### Environment and data model
- Almost entirely Claude-specific: `Paths` hardcodes `~/.claude`, `~/.claude.json`, managed settings, Claude Desktop config, `/private/tmp/claude-<uid>`. `Scope`, `Target`, `ComponentKind`, `InstructionFile.Kind` are closed Claude enums. `Snapshot` is one flat Claude snapshot with no provider key. Hook/permission schemas, `trashRefusal`, `BackupFiles.rule`, Analytics transcript parsing and `ClaudeCLI.ask` flags all assume Claude.
- Already neutral, keep as shared: `AgentFiles`, `AgentSkills` (`SkillAgent` already knows `.agents`, `.codex`, `.config/opencode`, `.gemini/extensions`), `Backup`, `BackupFiles` (minus `rule`), `Bulk`, `SkillSearch`, `Community` install.
- Becomes the Claude provider: `Paths`, `Scanner`, `Model.swift` types, `ScopeMove`, `SettingsEdit`, `Apply`, `CLI.swift`, `Checks`, `SkillStates`, `Memory`, `Staleness`, Claude rules in `Advice`/`Recommendations`.
- Ollama has no agent config tree; it is a model backend only.

### Information architecture
- 16 screens in 5 groups. Internal names swapped: `mySkills` = "Skills", `skills` = "Agents & Commands" (`Checks.swift:5-6`).
- Overlaps: Review / Guide / Context Budget; Storage / Projects & History / Backups (all disk); Discover / Community (both catalogues); Ask bar / skill analysis / menu-bar picker (three AI entry points).
- `docs/screenshots` is stale (old names "Health", "CLAUDE.md Browser").

### UX flows
- Edit flow is good: mtime check, backup, atomic write, undo toast.
- Toast holds one undo for 8 s; a second action loses the first. Link to Backups from it.
- "Fix..." buttons apply immediately; ellipsis implies a dialog.
- Ask auto-copy overwrites the clipboard unasked; make it opt-in.
- Settings and keybindings share one picker, so `keybindings.json` looks like a settings scope.

### UI and visual design
- `Theme.swift` (92 lines) has `Space`, `brand`, `spark`, `Card`, but 18 raw `.red/.green/.orange` and 3 `.font(.system(size:))` bypass it. No semantic danger/warning/success, no radius token (10 vs 6).

### Accessibility
- 7 accessibility modifiers in the whole app.
- Sankey (Skill map) and Analytics charts have no VoiceOver summary; Skill map has no keyboard focus.
- Toast dismiss button has only `.help`. Fixed 70/140 pt columns and 28 pt icon frames truncate at larger text. `.tertiary` text low contrast in dark mode. Backup diff relies on red/green (keeps +/- so passable).

Verdict: fix 1-5 first (they can destroy or leak agent state), then 6 (daily friction).
Lean: about -1,500 lines possible via the cut list in `plan.md` (Skill map 685, Analytics/Usage, Guide, Glossary, stars, updater, one catalogue).
Not checked: `SkillsView`, `SkillGridView`, `MenuBarSkills`, `FixSheet`, `AgentFilesView` mostly skimmed; `Advice`/`Recommendations`/`SkillMap`/`SkillPick` logic not traced; whether Claude prunes `~/.claude/backups/` subfolders (finding 7).
