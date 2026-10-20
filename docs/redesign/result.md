# Redesign result

Branch `redesign-agnostic`, uncommitted. Direction: **A · Ledger** (`mocks/a-ledger.html`).

## Counts (before = `396c71e`, after = working tree)

| | Before | After |
|---|---|---|
| Destinations per Claude Code sidebar | 10 kinds + Overview + 3 Library + menu-bar picker + Preferences = 16 | 7 kinds + Backups = 8 |
| Swift files | 63 | 49 |
| Swift lines (all targets) | 10,001 | 6,566 |
| Swift lines (app UI, `Sources/ClaudeConfig`) | 4,578 | 2,377 |
| Control declarations in UI code (Button/Toggle/Picker/TextField/Menu/Link/TableColumn/SelectBox/ScopeMenu) | 282 | 171 |
| Tests | 191 → 153 (cut features' tests removed) | 153 pass |

## What changed in step 5

- Primer tokens and components deleted; `Ledger/Ledger.swift` holds the whole system: one ink-blue accent, four scope hues + plugin, `Gap` spacing, `ScopeRule` gutter.
- Every screen is a native `Table` at full window width: Settings (was a 690pt centred Form), Memory and Backups (were 50/50 split panes), Hooks (was a hand-built list), provider file lists.
- Scope: the blue "User ⌄" link menus are gone. Scope shows as a 3pt rule in the first column plus plain text; moving is right-click › Move to.
- Selection: checkbox columns, "Select items to act on several at once" bars and BulkBar are gone; native multi-select (⌘/⇧-click, ⌘A) + context menu + ⌫ delete + double-click/↩ primary action.
- One inspector (`.inspector`) for every screen, on by default: monospaced title, facts as label/value rows, advice, file actions, raw text (Settings shows every file's value for the key; Backups shows the diff).
- Toolbar: filters and file pickers are toolbar menus; one `.searchable` per screen.
- Footer key-hint bar with the scope colour legend; Go menu with ⌘1–⌘7 for Claude Code screens, ⌘0 Backups.
- Hooks: pills replaced by one plain "Effect" column; Skills state is a compact popup instead of a 244pt segmented control.

Screenshots: `shots/before/` (after the cuts, before restyle), `shots/after/` (light + dark), `shots/compare/` (original app vs final, dark).
