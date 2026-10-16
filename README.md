# Claude Config

A native macOS app for keeping a Claude Code setup lean: what fills your context window, what takes disk space, and what breaks best practice, with a preview before every fix.

Hover over anything for a short explanation; the right-hand panel explains what the selected item is, where it lives, when it loads into context, and links to the official docs.

## Sections

| Section | What it shows |
|---|---|
| Health | Ranked problems, warnings and suggestions, each with a doc-backed reason and a **Fix…** button |
| Context Budget | Estimated tokens loaded before your first message, every session and per project |
| Analytics | Past sessions from transcripts: tokens per day, peak context, compactions, cache use, tools, models |
| Storage | Scratch folders, transcripts, plugins, jobs, caches, backups: size, age, safety, auto-cleanup |
| Projects & History | Every folder Claude has run in, with transcript size; purge via `claude purge` |
| Permissions | allow / ask / deny rules from every scope, plus per-project approvals |
| MCP Servers | Servers in every scope (user, local, project, plugin, Claude Desktop) |
| Skills & Agents | Skills, subagents, commands, output styles: listing cost, usage, overrides |
| Plugins | Installed plugins with always-on token cost (`claude plugin details`) |
| Hooks | Every hook by event and source; missing scripts and bad matchers |
| Instructions & Memory | CLAUDE.md, CLAUDE.local.md, rules, and MEMORY.md files with problems |
| Settings | Every settings key by scope, keybindings, and `claude doctor` |
| Discover | Plugins from your marketplaces, by install count |

## Keyboard (Health)

| Key | Action |
|---|---|
| ↑ ↓ | Move between issues |
| Space | Check or uncheck the selected issue |
| ⌘A | Check or uncheck all |
| ⌘C | Copy the selected issue's AI prompt |
| ⇧⌘C | Copy one AI prompt for every checked issue |
| Return | Fix or open the selected issue |
| ⌘R | Rescan |

## Build and install

Requires macOS 15 and Xcode (Swift 6).

```sh
./build.sh          # builds, signs ad hoc, installs /Applications/Claude Config.app
swift test          # unit tests
```

## How changes are made

- The `claude` CLI is used where it has a command (`purge`, `mcp remove`, `plugin enable|disable|update|uninstall|install`); purge shows its `--dry-run` output first.
- Settings changes edit one key and keep the rest. The file is backed up to `~/.claude/config-editor-backups/` first, and the save is refused if the file changed after it was read.
- Deletes in Storage go to the Trash. Locations Claude needs (`plugins/`, Claude's backups) are view-only.
- Managed settings are shown, never edited.

Token numbers are estimates (about 4 characters per token) except plugin costs, which come from `claude plugin details`. Run `/context` in Claude for exact figures.

## License

MIT
