# Cut list

Date: 2026-10-19. Branch `redesign-agnostic` @ 396c71e. Inputs: `ponytail-audit` of `Sources/ClaudeConfig` + `Sources/ConfigCore` (the full findings are in `audit.md`, most already fixed), plus a pass over the running app (`build.sh`, `open -g`, 13 screens captured; Library › Disk not captured). Nothing changed yet.

Test for each item: **does this help someone running an LLM coding agent day to day?** If unsure, CUT.

Target: one sidebar, provider → {Settings, Memory, Skills, Agents/Commands, MCP, Hooks, Permissions}, each a native Table + inspector. Plus Backups.

## Screens

| Item | Verdict | Reason |
|---|---|---|
| Overview › Findings | MERGE → badges on each kind's sidebar row + inline row warnings | A separate triage page is a second place to look; the fix belongs where the item lives. |
| Overview › Problems & Cleanup (stale list) | CUT | "Not used in 96 days" is housekeeping, not daily operation. Delete is already on each screen. |
| Settings (per provider) | KEEP | Core. |
| Memory | KEEP | Core. |
| Skills | KEEP | Core. |
| Agents | MERGE with Commands → "Agents & Commands" | Same shape (markdown file + frontmatter, scope); two tabs of one table. |
| Commands | MERGE → above | Same. |
| MCP | KEEP | Core. |
| Hooks | KEEP | Core. |
| Permissions | KEEP | Core. |
| Plugins | MERGE → Skills (plugin rows already shown there) + MCP | Plugins are toggled for the skills/servers they bring; the separate page only lists them again. Keep enable/disable as a row action. |
| Codex/Gemini/Cursor/opencode kind pages | KEEP (same screens, provider-filtered) | Required: "per provider". |
| Library › Skills catalogue (community lists) | CUT | Browsing GitHub star counts is discovery, not operation; the CLI `search` covers it. Removes network fetch + caches. |
| Library › Backups | KEEP | Safety net for every write; restore must stay reachable. |
| Library › Disk (storage, projects & history) | CUT | Disk usage of transcripts is not agent config. |
| Menu-bar skill picker + Preferences window | CUT | Third AI entry point; one launcher feature, not config editing. |
| Inspector "how it fits into Claude Code" glossary panel | MERGE → native `.inspector` showing the selected item's file/fields; glossary lines become `.help()` tooltips | The panel is mostly static prose. |

## Panels, controls, columns

| Item | Verdict | Reason |
|---|---|---|
| Ask Claude bar on every screen | MERGE → one toolbar button (⌘K) opening a sheet; sandbox unchanged | Earns its place only as "explain/fix this config"; a full-width bar on every screen costs a row and reads as AI chrome. |
| Ask auto-copy of prompts, `autoAsk` default, ASK-ANSWER stdout | CUT | Debug/test hooks and clipboard side effects. |
| Recommendations JSON block / install picks from Ask | CUT | Tied to the catalogue being cut. |
| "Search everything" sidebar field | KEEP | Fast jump across kinds; native `.searchable`. |
| Per-screen filter fields | KEEP, move to `.searchable` toolbar | Currently three different placements. |
| "Select items to act on several at once" checkbox row + checkbox column | MERGE → native Table multi-select (⌘-click, ⇧-click) + context menu | Native selection does this with zero chrome. |
| Bulk CSV export | CUT | Nobody exports agent config to a spreadsheet. |
| Skills segmented control: By category / Always / On demand / Overlaps | CUT "By category" (keyword grid), CUT "Overlaps"; KEEP Always/On demand as a State column filter | Category grid is decoration; overlaps is cleanup. |
| Skills "Skills cost ≈2.4k tok every session" header | KEEP as one line in the footer | Token cost of always-on skills is real daily info. |
| Skills "Clean-up review" bar + review sheet (Claude suggestions) | CUT | Cleanup, plus another AI surface. |
| Skills columns: Skill, State, Tokens, Scope | KEEP | What you change daily. |
| Skills columns: Uses, Last used | KEEP (one column "Last used") | Tells you what's dead; merge counts into tooltip. |
| Skills columns: Installed, Suggestion | CUT | Installed date is trivia; Suggestion is the cut triage. |
| "Plugins are turned on or off in Plugins" footer link | CUT | Plugins merged. |
| Settings scope picker + precedence line | KEEP picker; precedence → `.help` | |
| Settings per-key scope menu (User ▾) + ⋯ menu | MERGE → one context menu (Move to…, Reset, Delete) | Two menus per row is noise. |
| Settings "Run claude doctor" | CUT | Runs a terminal command you'd run in the terminal. |
| Settings "Open File" | KEEP (Reveal/Open in context menu + toolbar) | |
| Settings narrow centered column | CUT (layout) | Use full width Table: Key / Value / Scope. |
| Memory filters: projects / types / levels / Empty toggle / Select Empty | KEEP project filter; MERGE types+levels → one "Kind" filter; CUT Empty toggle + Select Empty | Cleanup. |
| Memory columns Size, Created | CUT Created; KEEP Size (tokens) | Size = context cost. |
| Memory Spotlight scan of whole disk (iCloud CLAUDE.md) | KEEP | Finds project memory you'd otherwise miss. |
| MCP columns Name, Scope, Where, Type, Command/URL | KEEP; drop plugin description subline | Description repeats the plugin's marketing line on every row. |
| Permissions "Per-project approvals" toolbar button | KEEP (as Scope filter) | |
| Undo toast | KEEP, drop ⌘Z capture | Safety. |
| FixSheet confirm for irreversible fixes | KEEP | Never cut confirmation for data-changing actions. |
| Toolbar icons (copy-prompt, doc, sparkle, rescan, inspector) | KEEP rescan (⌘R) + inspector toggle; CUT copy AI prompt + sparkle | Unlabelled icons nobody can name. |
| Glossary / ScreenText long help strings | CUT to one-line `.help()` per term | Help text that explains UI means the UI is unclear. |
| Primer tokens/components | KEEP for now (replaced in step 5) | |

## Code that goes with the cuts

`CommunityView`, `Community`, `CatalogStatus`, `Recommendations`, `SkillPick`, `SkillGridView`, `SkillReviewPanels`, `CleanupFindings`, `ReviewView` (stale/cleanup half), `StorageViews`, `MenuBarSkills`, `HealthViews` (→ badges), `Glossary` long text, `Advice` (if only used by cut screens), `AnswerBlocks` auto-copy, `BulkUI` checkbox/CSV pieces, `Bulk` (if native selection covers it), `Resources/best-practices.json` (if only Overview uses it), matching tests. `SkillSearch` + CLI `search` stay unless they only read community caches (to verify while cutting).

## Kept invariants

Backups before every write (`ConfigWriter`), sandboxed Ask (`ModelSandbox`), writes only to known config paths, undo toast, confirm sheet for irreversible ops.

## Expected result

Screens: 16 sidebar destinations per Claude + 4 Library-ish → **7 per provider + Backups**. Controls per list screen: from ~8 chrome rows/controls to search + table + inspector.
