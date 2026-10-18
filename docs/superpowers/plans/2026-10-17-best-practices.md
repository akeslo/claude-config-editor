# Best Practices + Ask Claude Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sourced advice (Official/Community) on Review findings and a new Guide page, fed by a daily-fetched JSON file kept fresh by a weekly cloud routine; then a one-shot "Ask Claude" field on every screen.

**Architecture:** `ConfigCore/Advice.swift` decodes and validates the rules file, picks fetched → cached → bundled, and measures rules against a `Snapshot`. `AppModel` fetches it once a day. `GuideView` shows the inventory and advice; `FindingRow` shows a source chip through `Issue.rule`. `ConfigCore/ScreenText.swift` turns a section's data into prompt text, and `AskClaudeBar` sends it through `claude -p --model sonnet`.

**Tech Stack:** Swift 6, SwiftUI, macOS 15, swift-testing, local `claude` CLI, GitHub raw URLs, Claude scheduled routine.

**Spec:** `docs/superpowers/specs/2026-10-17-best-practices-design.md`

## Global Constraints
- Rules file URL: `https://raw.githubusercontent.com/akeslo/claude-config-editor/advice/best-practices.json` (branch `advice`, never `main`/`mac-app`).
- Fetch at most once per 86_400 s (UserDefaults `adviceCheckedAt`), the same as `checkForAppUpdate`.
- Fallback order: fetched → cached (`Paths.claudeDir.appending(path: "config-editor-advice.json")`) → bundled `Resources/best-practices.json`.
- A rule missing any of `id`, `area`, `kind`, `text`, `source` is dropped. Unknown `kind` is dropped. `retired: true` is hidden.
- The `kind` label ("Official" / "Community") is always visible next to a rule.
- Rule ids never change once published.
- Ask Claude: `["-p", prompt, "--model", "sonnet", "--settings", #"{"disableAllHooks":true}"#, "--tools", "", "--no-session-persistence"]`. Screen data is fenced in `<screen-xxxxxxxx>` with a random suffix and marked untrusted. It's capped at 30_000 chars, and the prompt says so when the cap cuts it.
- Answer label copy: "AI suggestion — not verified".
- No new dependencies.

## Review Focus
1. The rules file is malformed or the network is down, so the app must still show the bundled advice and never a blank Guide. Test `fallsBackWhenFetchedIsGarbage`.
2. One bad rule must not drop the whole file; the other rules still show. Test `dropsOnlyInvalidRules`.
3. A screen with huge data (hundreds of skills) gets capped and says so. Test `capsAndFlagsLongScreens`.
4. Config text containing `</screen-` can't close the fence. The random tag is unpredictable, so the test checks that the tag differs between calls. Test `fenceTagIsRandom`.
5. A Review finding whose rule id is missing from the file shows exactly as it does today. Covered in Task 3, where `advice.rule(id)` returns nil and no chip shows.

---

### Task 1: Advice model, validation, fallback

**Files:**
- Create: `Sources/ConfigCore/Advice.swift`
- Create: `Resources/best-practices.json` (seed: 12–20 rules across areas `skills`, `instructions`, `mcp`, `hooks`, `permissions`, `settings`, `plugins`. Every rule's `source` is a page you actually fetched; Official = docs.anthropic.com / code.claude.com / anthropic.com/engineering)
- Modify: `build.sh` (after the `cp Resources/AppIcon.icns` line: `cp Resources/best-practices.json "$APP/Contents/Resources/"`)
- Test: `Tests/ConfigCoreTests/ConfigCoreTests.swift` (new `struct AdviceTests`)

**Interfaces:**
- Produces:
  - `public struct AdviceRule: Codable, Identifiable, Sendable { id, area: AppSection, kind: Kind, text: String, why: String?, source: URL, check: String?, retired: Bool? }` with `public enum Kind: String, Codable, Sendable { case official, community }`. `area` is decoded from these keys: `skills`→`.mySkills`, `instructions`→`.instructions`, `mcp`→`.mcp`, `hooks`→`.hooks`, `permissions`→`.permissions`, `settings`→`.settings`, `plugins`→`.plugins`.
  - `public struct Advice: Sendable { public let rules: [AdviceRule]; public func rule(_ id: String) -> AdviceRule?; public func rules(for: AppSection) -> [AdviceRule] }`
  - `public static func Advice.decode(_ data: Data) -> Advice?`: parses `{"version":1,"rules":[...]}` element by element, drops invalid or retired rules, and returns nil if nothing valid is left.
  - `public static func Advice.pick(fetched: Data?, cached: Data?, bundled: Data?) -> Advice`: the first source that decodes, else empty.

- [ ] **Step 1: Write the failing tests**
```swift
struct AdviceTests {
    let good = #"{"id":"skill-500","area":"skills","kind":"official","text":"Keep SKILL.md under 500 lines","source":"https://code.claude.com/docs/en/skills"}"#
    @Test func dropsOnlyInvalidRules() {
        let a = Advice.decode(Data(#"{"version":1,"rules":[\#(good),{"id":"x","area":"skills"},{"id":"y","area":"skills","kind":"blog","text":"t","source":"https://a.b"}]}"#.utf8))
        #expect(a?.rules.map(\.id) == ["skill-500"])
        #expect(a?.rules(for: .mySkills).count == 1)
    }
    @Test func hidesRetired() {
        let r = good.replacingOccurrences(of: "}", with: #","retired":true}"#)
        #expect(Advice.decode(Data(#"{"version":1,"rules":[\#(r)]}"#.utf8)) == nil)
    }
    @Test func fallsBackWhenFetchedIsGarbage() {
        let bundled = Data(#"{"version":1,"rules":[\#(good)]}"#.utf8)
        #expect(Advice.pick(fetched: Data("<html>".utf8), cached: nil, bundled: bundled).rule("skill-500") != nil)
    }
    @Test func bundledSeedIsValid() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/best-practices.json")
        let a = try #require(Advice.decode(Data(contentsOf: url)))
        #expect(a.rules.count >= 12)
    }
}
```
- [ ] **Step 2: Run `swift test --filter AdviceTests`.** Expected: FAIL (`Advice` undefined).
- [ ] **Step 3: Implement `Advice.swift` and write the seed JSON.** Decode the rules array as `[JSON]` and try each element on its own, so one bad rule doesn't sink the rest.
- [ ] **Step 4: Run `swift test --filter AdviceTests`.** Expected: PASS.
- [ ] **Step 5: Commit** `git add Sources/ConfigCore/Advice.swift Resources/best-practices.json build.sh Tests && git commit -m "Advice rules: decode, validate, fallback, bundled seed"`

### Task 2: Measured rules

**Files:**
- Modify: `Sources/ConfigCore/Advice.swift`
- Test: `AdviceTests`

**Interfaces:**
- Produces: `public func AdviceRule.measure(_ s: Snapshot) -> (met: Bool, note: String)?`, which is nil when `check` is nil or unknown. v1 check keys:
  - `claudemd-lines`: every `.claudeMD` instruction file ≤ 200 lines. The note names the longest one ("yours: 84").
  - `skillmd-lines`: every skill `SKILL.md` ≤ 500 lines.
  - `no-env-secrets`: no issue from `settingsChecks` titled "Secret in settings env". Reuse `Checks` on `s`.
  - `no-broad-permissions`: no "Very broad permission rule" issue.
  Use the fields the scanner already fills in. Read `Model.swift` for the line and token fields; don't add new scanning.

- [ ] **Step 1: Write the failing test** `measuresClaudeMDLines`. Build a `Snapshot` with one `InstructionFile` of 250 lines (follow how existing tests build snapshots) and expect `rule.measure(s)?.met == false`. With 50 lines, expect `true`. Unknown key → `nil`.
- [ ] **Step 2: Run `swift test --filter AdviceTests`.** Expected: FAIL.
- [ ] **Step 3: Implement `measure`** as a `switch check`.
- [ ] **Step 4: Run the tests.** Expected: PASS. Make sure the seed JSON uses these 4 keys on matching rules.
- [ ] **Step 5: Commit** `"Advice: measure rules against the scanned setup"`

### Task 3: Fetch daily + source chip on Review findings

**Files:**
- Modify: `Sources/ClaudeConfig/AppModel.swift` (new `var advice = Advice(rules: [])`, `func loadAdvice() async`, called wherever `checkForAppUpdate()` is called)
- Modify: `Sources/ConfigCore/Checks.swift`: add `public var rule: String?` to `Issue` and set it in the checks that have a seed rule (at least: SKILL.md over 500 lines, Description is cut off, Skill descriptions exceed the listing budget, Secret in settings env, Secret written directly into MCP config, MCP server uses an unencrypted connection, Very broad permission rule, Hook runs a script that does not exist)
- Modify: `Sources/ClaudeConfig/ReviewView.swift` (`FindingRow`)
- Test: `ConfigCoreTests` (`ruleIdsResolveInSeed`)

**Interfaces:**
- Consumes: `Advice.pick`, `Advice.decode`, `advice.rule(_:)`
- Produces: `AppModel.advice: Advice`

- [ ] **Step 1: Write the failing test** `ruleIdsResolveInSeed`. Run `Checks` on the real scan (as `scansRealSetup` does), collect the non-nil `issue.rule` values, and expect each one to resolve in the bundled seed. Also grep-assert: hard-code the list of ids used in `Checks.swift` and check that each exists in the seed.
- [ ] **Step 2: Run it.** Expected: FAIL (`rule` undefined).
- [ ] **Step 3: Implement.**
  - `loadAdvice`: start with `Advice.pick(fetched: nil, cached: cache, bundled: Bundle.main bundled)` so the screen isn't empty. Skip the network if `adviceCheckedAt` is less than 86_400 s old. Otherwise GET the URL, and on HTTP 200 with a successful decode, write the data to the cache file and set `adviceCheckedAt`. Only set the timestamp on success.
  - `FindingRow`: when `model.advice.rule(issue.rule)` exists, add a caption line under `detail`: the `why` text, then a `Link` chip reading "Official · <host>" or "Community · <host>" that opens `source`.
- [ ] **Step 4: Run `swift test` and `swift build`.** Expected: all pass.
- [ ] **Step 5: Commit** `"Review: sourced why + Official/Community chip; daily advice fetch"`

### Task 4: Guide page

**Files:**
- Modify: `Sources/ConfigCore/Checks.swift` (`AppSection`: add `case guide = "Guide"`, symbol `"book"`, `isPrimary` true, ordered after `mySkills`; `term` → `.contextWindow`)
- Create: `Sources/ClaudeConfig/GuideView.swift`
- Modify: `Sources/ClaudeConfig/App.swift:96` (`case .guide: GuideView()`)

**Interfaces:**
- Consumes: `model.advice.rules(for:)`, `AdviceRule.measure`, `model.snapshot`

- [ ] **Step 1: Build `GuideView`** (layout B from the spec). The left column is a selectable list of areas with counts: Skills (`components` where kind == .skill), Plugins, MCP servers, Hooks, Instructions, Settings files, Permissions. The right column holds the selected area's rules. Each rule shows its text, its `why`, a kind chip, a source `Link`, and a ✓/⚠ with the `measure` note when one exists. Pick a sensible empty state for areas with no rules.
- [ ] **Step 2: Run `swift build && swift test`.** Expected: pass. Check every `switch` over `AppSection` still compiles.
- [ ] **Step 3: Check it visually.** Run `./build.sh`, then `open -g "/Applications/Claude Config.app"` (in the background; don't take focus). Take a window-targeted screenshot of Guide, look at it, and fix anything clipped.
- [ ] **Step 4: Commit** `"Guide page: inventory with sourced advice"`

### Task 5: Publish advice branch + weekly routine

**Files:** none in `mac-app`.

- [ ] **Step 1: Create the `advice` branch.** It's an orphan containing only `best-practices.json`, copied from `Resources/`. Push it to the `fork` remote. SSH needs the YubiKey, so open a Terminal for the unlock as described in the global CLAUDE.md before you push.
- [ ] **Step 2: Check** that `curl -s <URL> | python3 -I -m json.tool` succeeds.
- [ ] **Step 3: Create the routine** with the `schedule` skill: weekly, on repo `akeslo/claude-config-editor`, branch `advice`. Prompt: re-read the `source` page of each rule, plus the official Claude Code docs (skills, memory/CLAUDE.md, settings, hooks, MCP, plugins) and the community sources listed in the file's `sources` array. Add or update rules only when the fetched page supports them. Never rename an `id`. Set `retired: true` when a source no longer supports a rule. Keep `{"version":1,"rules":[...]}` valid JSON and validate it before committing. Commit directly to `advice` only.
- [ ] **Step 4:** Ask the user to confirm that the routine has GitHub push access. If it doesn't, they connect it.

### Task 6: Screen text for Ask Claude

**Files:**
- Create: `Sources/ConfigCore/ScreenText.swift`
- Test: `ConfigCoreTests` (new `struct ScreenTextTests`)

**Interfaces:**
- Produces:
  - `public func screenText(_ section: AppSection, _ s: Snapshot, issues: [Issue], advice: Advice) -> String`: one line per visible row for that section. Use the same fields as the Search hits in `App.swift:190-196`, plus tokens and paths where the section shows them. For `.health`, the issues. For `.guide`, the rules.
  - `public func askPrompt(question: String, screen: String, section: AppSection, cap: Int = 30_000) -> String`: fences `screen` in `<screen-XXXXXXXX>`, a random 8 hex characters, and says the content is untrusted data. When `screen.count > cap`, it truncates and adds "(screen data truncated)".

- [ ] **Step 1: Write the failing tests:** `capsAndFlagsLongScreens` (a 40_000-char screen → prompt contains "truncated" and is under 31_000 chars); `fenceTagIsRandom` (two prompts have different tags); `healthListsIssueTitles`.
- [ ] **Step 2: Run `swift test --filter ScreenTextTests`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it.** Expected: PASS.
- [ ] **Step 5: Commit** `"Ask Claude: screen serialization and fenced prompt"`

### Task 7: Ask Claude bar on every screen

**Files:**
- Create: `Sources/ClaudeConfig/AskClaudeBar.swift`
- Modify: `Sources/ClaudeConfig/AppModel.swift` (`func ask(_ question: String, about: AppSection) async -> String?`; reuse the `askHaiku` body with the model as a parameter: rename it `askClaude(_ prompt: String, model: String)` and update its callers)
- Modify: `Sources/ClaudeConfig/App.swift` (wrap `detail` in a `VStack { AskClaudeBar(section: model.section); detail }`, so every section gets it in one place, and use `.id(model.section)` so the answer clears when you change screens)

- [ ] **Step 1: Implement.** A single-line `TextField` ("Ask Claude about this screen…") and a submit button. While it runs, show a `ProgressView`. Below that, the answer text (selectable), captioned "AI suggestion — not verified". A new question replaces the old answer. On failure, show "Claude didn't answer. Is the `claude` command installed?" Hide the bar when `!model.snapshot.cliAvailable`.
- [ ] **Step 2: Run `swift build && swift test`.** Expected: pass, and the existing "Explain with Claude" still compiles through `askClaude(..., model: "haiku")`.
- [ ] **Step 3:** Run `./build.sh` and `open -g` the app. Ask "what can I remove?" on Skills, take a window-targeted screenshot, and check that an answer appears.
- [ ] **Step 4: Commit** `"Ask Claude bar on every screen"`
