# Best Practices: sourced advice in Review + a Guide page

## Why
The user keeps second-guessing their Claude Code setup: what belongs in the config, what doesn't, what skills are even installed. The app already flags problems (Review, ~25 checks in `Checks.swift`) but never says *why* or *according to whom*, and offers nothing when there's no problem to flag. Success: the user can open one page, see what they have, and read trustworthy, current advice per area, each item traceable to a source.

## Goals
1. **Sources on Review findings.** Every Review finding shows a one-line *why* and a source chip (`Official` or `Community`, linking out).
2. **A new Guide page** (layout "B", chosen by the user): an inventory of what the user has on the left (counts per area: Skills, Plugins, MCP servers, Hooks, CLAUDE.md/instructions, Settings, Permissions), and on the right the advice for the selected area. Each advice item shows its text, Official/Community label, and source link. Where the app can measure a rule against the user's setup, it shows met / not met (e.g. "CLAUDE.md under ~200 lines — yours: 84").
3. **Stays up to date without app releases.** The advice lives in one JSON file in the `akeslo/claude-config-editor` repo; the app fetches it daily and caches it.
4. **Kept fresh automatically.** A scheduled Claude routine rereads sources (~weekly) and commits changes to that file **directly** (user chose: no PR review).

## Non-goals
- No live AI summarising inside the app; the app only shows the fetched file.
- Not a replacement for Review: Guide explains, Review flags and fixes.
- No new auto-fix actions in this project.

## Anti-goals
- Advice with no source link. Every rule must link to the page it came from.
- Blurring official and community: the label must always be visible.
- The page breaking or going blank offline or when the fetch fails.

## Constraints / decided
- Sources: Anthropic's official docs (Claude Code docs, skills/plugins docs, engineering blog) **and** well-known community people/repos, labelled separately.
- Advice file in the user's fork repo, fetched via `raw.githubusercontent.com`, mirroring the existing daily update check in `AppModel.swift` (~line 264): at most once per 24h, UserDefaults timestamp.
- Fallback order: last cached copy → copy bundled in the app at build time.
- Review findings link to rules by a stable rule `id`; the check in `Checks.swift` names the id it corresponds to. If the id is missing from the file, the finding shows as today (no chip).
- Updates go straight to the file with no human review (user's choice). Safeguard (builder's call on mechanism): the routine only writes rules whose source URL it fetched and whose text it can tie to that page, and the app ignores entries missing `id`, `text`, `source` or `kind`.

## Decided after builder check (Claude's calls)
- **Separate branch.** The file lives on its own `advice` branch of `akeslo/claude-config-editor` (the `fork` remote), never on `main`/`mac-app`, so routine commits don't trigger the app-update badge. The fetch URL is `raw.githubusercontent.com/akeslo/claude-config-editor/advice/best-practices.json`.
- **Ids are permanent.** The routine may add rules and edit `text`/`why`/`source` of existing ids. It never renames an id. When a source stops supporting a rule, the routine sets `retired: true` instead of deleting the rule, and the app hides retired rules.

## Decided by the user
- The routine gets push access to the whole `akeslo/claude-config-editor` repo (no separate repo). By convention it only commits to the `advice` branch.

## Left to the builder
- Exact JSON schema (minimum: `id`, `area`, `kind` official|community, `text`, `why`, `source` URL, optional measurable-check key).
- Which rules get a measured met/not-met state for v1. Start with what the scanner already knows.
- Choosing the initial community sources, the routine's prompt and schedule (via the `schedule` skill), and the sidebar position/icon for Guide in `AppSection`.
- Seeding the first version of the file and writing the per-check rule ids.

---

# Follow-on (approved in chat): Ask Claude on every screen
Built after the Best Practices work above.
- A one-line "Ask Claude" field at the top of every section screen, Guide included. One question gets one answer, shown below the field; asking again replaces it. Answers aren't kept after leaving the screen.
- The prompt is the question plus that screen's visible data serialized as text (rows: names, paths, token costs, findings), with no extra file contents. Oversized data is truncated and the answer notes it.
- Runs the local `claude -p` the same way `AppModel.askHaiku` does (tools off, hooks off, no session persistence), but with `--model sonnet` (Claude's call).
- Screen data is fenced in a random tag and marked as untrusted data, as in `AppModel.explain`.
- Answers are labelled as an unverified AI suggestion.
