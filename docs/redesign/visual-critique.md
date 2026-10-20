# Visual critique (after the cuts)

Date: 2026-10-19. Build after step 2. Screenshots: `shots/before/<screen>-<light|dark>.png` (9 screens × 2 modes, captured headless with `open -g` + `screencapture -l`).
`/swiftui-design-skill` and `/ui-craft` are not installed in this environment; this audit applies their usual checklist by hand: generic-AI tells, hierarchy, space, density, contrast, native idiom.

## What reads as generic AI UI

1. **Pill-badge confetti on Hooks.** Every hook carries 2–4 tinted capsules (blue "Every project", amber "May add text to context", purple "May block tools"). Four hues, all equal weight, decorate instead of rank. Primer's role colours are applied as decoration.
2. **Blue-link scope menus everywhere** ("👤 User ⌄", "Local ⌄", "Project ⌄") in tint colour on every row of Settings, Skills, MCP, Permissions. A column of identical blue links is the loudest thing on every screen, and it's the field you change least.
3. **Big empty-state hero** ("Select a file" with a 48pt icon and two lines of help) occupying half of Memory and Backups. Template-ish, and the split stays even when nothing is selected.
4. **Prose subtitles under everything**: Settings' "Changes save immediately (a backup is taken; Undo appears below). Precedence: managed › …"; Hooks' multi-line raw comments as descriptions; Memory's "Project CLAUDE.md · Project" restating the Scope column.
5. **Lightbulb / sparkle / clock glyphs** sprinkled inline in names (Memory rows, Skills' "Always (plugin)"), no legend.

## Broken hierarchy

- Window title (sidebar-chrome grey 13pt) is weaker than the table header. The screen has no visible "what am I editing": on Settings the actual subject (`~/.claude/settings.json`) sits in a popup in the content area.
- **Settings' key names, values and actions are the same weight.** Values are right-aligned into small fields far from their key, so the eye ping-pongs ~500pt across each row.
- **Toolbar has no order**: Ask, Rescan, Inspector, then screen-specific items (Open File, segmented filters, search) wedged between, different per screen. On Agents the type filter (All/Subagents/Commands/Output styles) lives in the toolbar; on Skills the equivalent tab picker lives in the content.
- The "Select items to act on several at once" row is the first thing under the toolbar on 5 screens — the least important control gets the top slot.
- Sidebar: four providers × 7 identical rows = 28 rows of the same weight; the provider headers are 11pt grey and don't separate groups. Non-Claude providers mostly hold 1 file per screen.

## Wasted space

- **Settings: content is a ~690pt column centred in a ~1780pt pane** (`.formStyle(.grouped)` max width). ~60% of the window is empty on both sides at 1440+ widths while values truncate (`enabledPlugins`, `skillOverrides` end in "…").
- **Memory / Backups: fixed 50/50 HSplitView** with an empty detail pane by default. The list's Name column truncates paths at ~45 characters while 900pt of the right side shows a placeholder.
- **Codex/Gemini/opencode screens**: one row (`config.toml` + Edit/Reveal) on an otherwise empty full-height pane. These provider screens are file lists of 0–2 items each; seven sidebar rows for that is more navigation than content.
- Skills: 200pt+ of "Always (plugin)" text repeated per row in the State column for rows that can't change state.

## Density

- Rows are mixed heights: 2-line rows (name + description) in Skills/MCP/Memory, 1-line rows in Permissions, 3–5-line rows in Hooks. Scanning speed differs per screen.
- Hooks is the least dense and least scannable: no table, wrapped prose, duplicated rows (`task-ledger-hook.sh` twice, one per event) with the whole description repeated.
- Permissions is the best page: one line per rule, monospaced, sortable. Use it as the reference density for every list.
- Inline segmented "Always | On demand | Off" (244pt) per skill row is heavy; a compact popup or a single-letter state with a context menu would fit a keyboard workflow better.

## Contrast

- **Dark mode secondary text** (description lines, "Runs: …", sidebar section headers) is ~#8b8b90 on #2a2a2e ≈ 4.0:1, under 4.5:1 for 11–12pt text.
- **Light mode**: the Primer `attention` amber ("Overridden by User (local)", lightbulbs) on the grey grouped-form background is ~3.6:1.
- Disabled-looking icons: the toolbar uses `.secondary` SF Symbols that read as disabled in light mode next to the bright "Open File"/"Add key" buttons.
- Tinted Hooks pills in dark mode (purple on 10% purple) fall to ~3:1.

## Native idiom gaps

- Only Skills uses native Table selection + context menu; other lists still use a custom checkbox column + BulkBar.
- Settings is a `Form` not a `Table` — no sorting, no keyboard row navigation, no multi-select.
- Hooks is a hand-built list, not a Table.
- The inspector shows a term title + facts but nothing editable; Memory and Backups have their own home-made detail panes instead of using `.inspector`.
- Search lives in three places (sidebar "Search everything", toolbar `.searchable`, inline "Filter …" fields).

## What to keep

Sidebar + NavigationSplitView, monospaced values, Permissions' one-line table, the scope concept (but quieter), the undo toast, the confirm sheet.
