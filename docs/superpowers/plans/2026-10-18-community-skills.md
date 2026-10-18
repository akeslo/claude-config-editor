# Community Skills in Discover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Community skills" tab in Discover that lists skills from four curated lists and installs them: marketplace repos the official way, and other repos by copying chosen `SKILL.md` folders into `~/.claude/skills`.

**Architecture:** `ConfigCore/Community.swift` holds the list definitions, the four parsers, the daily fetch/cache choice (same pattern as `Advice`), the repo download, the skill finder, and the install copy. The `Fix` enum gets `.installSkills`, so installs go through the existing preview-and-confirm `FixSheet`. `DiscoverView` gets a Plugins / Community skills picker.

**Tech Stack:** Swift 6, SwiftUI, macOS 15, swift-testing, `URLSession`, `/usr/bin/tar`, local `claude` CLI.

**Spec:** `docs/superpowers/specs/2026-10-17-best-practices-design.md` (section "Follow-on: Community skills in Discover")

## Global Constraints
- Lists, verbatim (the user approved these four):
  1. `video`: `https://raw.githubusercontent.com/zhuyansen/awesome-claude-video-skills/main/data/skills.json`, as JSON `{kinds:[{id,icon,en}], skills:[{repo_full_name, path, stars, description, kind, ...}]}`, with category = `kinds[id==kind].icon + " " + en`.
  2. `anthropic`: `https://raw.githubusercontent.com/anthropics/skills/main/.claude-plugin/marketplace.json`, read as marketplace `plugins[]`. Every row is `marketplace: true` with repo `anthropics/skills`.
  3. `awesome-claude-code`: `https://raw.githubusercontent.com/hesreallyhim/awesome-claude-code/main/THE_RESOURCES_TABLE_NEW.csv`. Columns: `ID, Display Name, Category, Sub-Category, Link, Author Name, Author Link, Active, Date Added, Last Checked, Description, Stale`. Keep only rows whose Link is a github.com repo/tree URL and where `Stale` isn't true.
  4. `composio`: `https://raw.githubusercontent.com/ComposioHQ/awesome-claude-skills/master/README.md`. Bullets match `^\s*[-*] \*{0,2}\[([^\]]+)\]\((https?://[^)]+)\)\*{0,2}\s*[-–:]\s*(.+)$`, and the category is the last `##`/`###` heading. Keep only github.com links.
- GitHub URLs parse to `slug = owner/repo` plus an optional `path` (taken from `/tree/<branch>/<path>` or `/blob/<branch>/<path>`, dropping a trailing `SKILL.md`).
- Fetch each list at most once per 86_400 s (UserDefaults `communityCheckedAt.<id>`), the same way `AppModel.loadAdvice` does. Cache to `Paths.claudeDir.appending(path: "config-editor-community/<id>")`. A list that fails to fetch or parse uses its cache; a list with no cache contributes nothing. The other lists still show.
- Rows are de-duplicated by `slug + path`.
- Install target: `Paths.claudeDir.appending(path: "skills/<name>")`. **Never overwrite**: an existing name is refused in the preview and skipped on apply.
- The repo download is `https://codeload.github.com/<slug>/tar.gz/HEAD` into a fresh temp dir under `FileManager.default.temporaryDirectory`, then `/usr/bin/tar -xzf` with no shell. The download is capped at 50 MB. The slug must match `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`.
- Copying refuses symlinks that point outside the skill folder. Copied files keep their permissions.
- The preview lists every file to be copied. It flags scripts (executable bit, or extension in `sh py js ts rb pl ps1 bash zsh mjs cjs`) with "⚠ runs code". It includes the repo link and says "Only install skills you trust: scripts in a skill can run on your machine."
- Marketplace route: when the repo has `.claude-plugin/marketplace.json` (checked in the downloaded tree, or for `anthropic` list rows), install is `.cli(args: ["plugin", "marketplace", "add", slug], dryRun: nil, cwd: nil)`. Its plugins then appear in the existing Plugins tab.
- No new dependencies.

## Review Focus
1. One list's URL returns 404 or garbage HTML, and the other three lists still show. Test `pickSkipsBrokenList`.
2. A README with odd bullets: non-GitHub links, nested bullets, links with `#anchors`. These must not crash, and only github rows come through. Test `composioParsesOnlyGitHub`.
3. Installing a skill whose name already exists. The preview says it's skipped and apply leaves the existing folder untouched. Test `installRefusesExisting`.
4. A malicious tarball with `../` paths or a symlink to `/etc` can't write outside the temp dir or the target. Test `copyRefusesEscapingSymlink`. `tar` refuses `..` members by default; the finder only walks inside the extract dir.
5. A repo with several skills at different depths (`skills/a/SKILL.md`, `.agents/skills/b/SKILL.md`, root `SKILL.md`). All of them are found, each named from its frontmatter `name:`, falling back to the folder name. Test `findsSkillsAtAnyDepth`.

---

### Task 1: Catalog model and parsers

**Files:**
- Create: `Sources/ConfigCore/Community.swift`
- Test: `Tests/ConfigCoreTests/ConfigCoreTests.swift` (new `struct CommunityTests`; inline fixture strings)

**Interfaces:**
- Produces:
  - `public struct CommunitySkill: Identifiable, Sendable, Hashable { id: String (slug + "/" + path or slug), name: String, description: String, category: String, stars: Int?, slug: String, path: String?, list: String, marketplace: Bool, link: URL }`
  - `public enum CommunityList: String, CaseIterable, Sendable { case video, anthropic, awesomeClaudeCode = "awesome-claude-code", composio }` with `url: URL`, `title: String`, `func parse(_ data: Data) -> [CommunitySkill]?` (nil when the data is unusable)
  - `public func githubRef(_ url: String) -> (slug: String, path: String?)?`
  - `public static func CommunityCatalog.merge(_ lists: [[CommunitySkill]]) -> [CommunitySkill]` (dedupe by id, keeping the first)

- [ ] **Step 1: Write the failing tests:** `githubRefParsesTreeAndBlob` (`https://github.com/a/b/tree/main/skills/x` gives `("a/b","skills/x")`; `.../blob/main/skills/x/SKILL.md` gives `("a/b","skills/x")`; `https://example.com/x` gives nil), `videoParses` (a 2-entry fixture, where the category for kind `promo` is `"📣 Promo & demos"`), `anthropicMarketplaceRowsAreMarketplace`, `csvSkipsStaleAndNonGitHub` (with a quoted comma inside Description), `composioParsesOnlyGitHub`, `pickSkipsBrokenList` (`parse(Data("<html>".utf8)) == nil` for every list).
- [ ] **Step 2: Run `swift test --filter CommunityTests`.** Expected: FAIL.
- [ ] **Step 3: Implement.** The CSV parser handles RFC-4180 quoting, written by hand in about 20 lines. Don't use a dependency.
- [ ] **Step 4: Run `swift test --filter CommunityTests`.** Expected: PASS.
- [ ] **Step 5: Commit** `"Community skills: list parsers"`

### Task 2: Repo download, skill finder, install

**Files:**
- Modify: `Sources/ConfigCore/Community.swift`
- Modify: `Sources/ConfigCore/Checks.swift` (`Fix`: add `case installSkills([SkillCopy])`; `summary` reads "Install N skill(s) into ~/.claude/skills")
- Test: `CommunityTests`

**Interfaces:**
- Produces:
  - `public struct FoundSkill: Sendable, Hashable { name: String, dir: URL, files: [String] (relative paths), scripts: [String] }`
  - `public struct SkillCopy: Sendable, Hashable { from: URL, name: String }`
  - `public func downloadRepo(_ slug: String) async throws -> URL`: returns the extracted root dir. Validates the slug, enforces the 50 MB cap, extracts with `/usr/bin/tar` via `Process`.
  - `public func findSkills(in root: URL) -> [FoundSkill]`: every dir containing `SKILL.md`. Its name comes from frontmatter `name:`, else the dir name. The name is sanitised to `[A-Za-z0-9._-]` and must be non-empty.
  - `public func hasMarketplace(_ root: URL) -> Bool`
  - `public func installSkill(_ c: SkillCopy, into skillsDir: URL = Paths.claudeDir.appending(path: "skills")) throws -> Bool`: false (skipped) when the target exists. Throws on a symlink escaping `c.from`.

- [ ] **Step 1: Write the failing tests** using temp dirs, not the network: `findsSkillsAtAnyDepth`, `flagsScripts` (a `run.sh` and an executable file both land in `scripts`), `installRefusesExisting`, `installCopies` (files and exec bit preserved), `copyRefusesEscapingSymlink`, `rejectsBadSlug` (`downloadRepo("a/b;rm")` throws).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** Copy by walking `FileManager.enumerator` and creating dirs and files. Resolve each symlink's destination and refuse it unless it lies under `c.from`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass. Every `switch` over `Fix` compiles; add `.installSkills` to the `editsSettings` default branch.
- [ ] **Step 5: Commit** `"Community skills: download, find, install"`

### Task 3: Fetch/cache + Discover UI + FixSheet

**Files:**
- Modify: `Sources/ClaudeConfig/AppModel.swift` (`var community: [CommunitySkill] = []`, `func loadCommunity() async`, called from `DiscoverView`'s `.task`)
- Modify: `Sources/ClaudeConfig/ConfigViews.swift` (`DiscoverView`: a segmented `Picker` for "Plugins" / "Community skills"; the existing table is unchanged under Plugins)
- Create: `Sources/ClaudeConfig/CommunityView.swift` (the table and install flow)
- Modify: `Sources/ClaudeConfig/FixSheet.swift` (`makePreview` and `run` cases for `.installSkills`)

**Interfaces:**
- Consumes: Task 1 and Task 2 interfaces, `model.propose(_:_:)`, and the existing `search` field (filter on name, description and category).

- [ ] **Step 1: Implement `loadCommunity`** per the Global Constraints. Fetch the four lists concurrently with a `TaskGroup`, then `CommunityCatalog.merge` in `CommunityList.allCases` order.
- [ ] **Step 2: Implement `CommunityView`:**
  - **Table columns:** Skill (name plus a 2-line description), Category, List (title), Stars, Installed. A row counts as installed when `~/.claude/skills/<name>` exists, or for marketplace rows when the marketplace is already in `known_marketplaces.json`.
  - **Toolbar:** "Hide installed" and "Install…".
  - **Install… for marketplace rows:** propose the `.cli` marketplace add.
  - **Install… for other rows:** show a progress state, `downloadRepo`, then `hasMarketplace`; if true, propose the marketplace route. Otherwise `findSkills`, narrowed to the row's `path` when set. With one skill, propose `.installSkills` directly; with several, a small sheet with checkboxes lets the user pick, and its "Continue" proposes `.installSkills`. Show download errors inline.
  - **Selecting a row** sets `model.info` the way plugins do, with the link.
- [ ] **Step 3: FixSheet.** The preview lists each skill: `→ ~/.claude/skills/<name>`, the "SKIPPED (already exists)" note when applicable, its files with "⚠ runs code" on scripts, the repo link, and the trust warning text. `run` calls `installSkill` for each and reports installed and skipped counts.
- [ ] **Step 4: Run `swift build && swift test`.** Expected: pass.
- [ ] **Step 5: Check it visually without stealing focus.** Run `./build.sh`, then `osascript -e 'quit app "Claude Config"'`, then `open -g "/Applications/Claude Config.app" --args -section Discover`. Capture the window by id with `screencapture -l`, and check that the Community skills tab lists rows from all four lists. Leave the app running.
- [ ] **Step 6: Commit** `"Discover: Community skills tab with install"`
