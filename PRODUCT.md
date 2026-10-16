# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app, installed in and launched from `/Applications`. Not one of Impeccable's standard values (`web`, `ios`, `android`, `adaptive`); follow Apple's macOS Human Interface Guidelines.

## Stack

Native SwiftUI (user's choice). Reads and writes Claude's files directly; no Python server, no browser page.

## Users

One person: the owner, a developer who uses Claude Code heavily across many projects, with many skills, plugins, hooks and MCP servers installed. They open the app for maintenance sessions: when Claude feels slow, the context fills up early, or the setup has drifted and needs tidying.

## Product Purpose

A single place to keep a Claude Code setup lean, organized and current. Jobs, all confirmed:

- Shrink the config (`~/.claude.json` and related history) safely.
- Manage configuration (settings at every scope, CLAUDE.md files).
- Manage MCP servers.
- Manage skills.
- Find new skills worth installing.
- Check the setup against Claude Code best practices: keep things organized, avoid bloat, and keep the context window small.

Success: the setup stays small and understandable, sessions start with less context used, and nothing breaks or gets lost while cleaning.

## Positioning

A personal maintenance console for a Claude Code setup, opinionated by official best practice rather than a raw JSON editor.

## Operating Context

- Claude Code may be running while the app is open and writes `~/.claude.json` often; edits must not overwrite its newer changes.
- Files involved include `~/.claude.json`, `~/.claude/` (settings, CLAUDE.md, skills, plugins, agents, hooks, memory), and per-project `.claude/` folders and `.mcp.json`.
- Best-practice facts from the official docs (code.claude.com, researched 2026-10-16):
  - Settings precedence: managed > `--settings` > `.claude/settings.local.json` > `.claude/settings.json` > `~/.claude/settings.json`. Managed settings (`/Library/Application Support/ClaudeCode/`) are read-only to this app.
  - `~/.claude.json` is "a file it writes for itself"; Claude Code keeps 5 backups in `~/.claude/backups/`. Transcripts live in `~/.claude/projects/<project>/*.jsonl`, are plaintext, and are swept after `cleanupPeriodDays` (default 30).
  - `claude purge <path> [--dry-run]` is the official way to remove a project (transcripts, memory, history lines, and its `~/.claude.json` entry). Verified present in the installed CLI.
  - Context at session start: CLAUDE.md files (keep each under 200 lines), first 200 lines of auto-memory `MEMORY.md`, skill descriptions (listing budget about 1% of context; overflow drops least-used), MCP tool names (schemas deferred by tool search), SessionStart/UserPromptSubmit hook output. `/context` and `/skill-doctor` measure it.
  - Skills: `SKILL.md` under 500 lines; description + `when_to_use` truncated at 1,536 chars; `disable-model-invocation: true` removes a skill from the always-loaded listing; `skillOverrides` can set skills to name-only.
  - Official routes for changes: `claude mcp add|remove|list`, `claude plugin install|uninstall|enable|disable|update|list --json`, `claude plugin marketplace ...`. Official marketplaces auto-update.
  - Same-named MCP servers in several scopes: the winning scope's entry replaces the others entirely.
  - Unverified in the docs: why `~/.claude.json` grows, and whether editing it while Claude runs is unsafe.

## Capabilities and Constraints

- Replaces the current Python server + browser version, which will be retired.
- Must keep existing safety guarantees: backup before every write, refuse to save over newer on-disk changes, atomic writes, owner-only permissions on files holding secrets.
- Deleting a project in `~/.claude.json` also removes its allowed tools, trust setting and project MCP servers; the UI must say so.
- Prefer the official `claude` CLI (`purge`, `mcp`, `plugin`) over editing files; edit settings files at key level only, keeping unknown keys.
- Undecided: where skill discovery pulls from beyond the official marketplace (`anthropics/claude-plugins-official`).

## Evidence on Hand

- Real result: the owner's config went from 17 MB (87 projects) to 732 KB after cleanup.
- Screenshots of the old web version in `screenshots/`.
- No user base, testimonials or metrics beyond that. Do not invent any.

## Product Principles

1. Never lose data: back up, refuse stale writes, explain what a delete removes.
2. Show cost: every item shows what it costs in disk and in context tokens, so the owner can decide.
3. Official guidance over opinion: best-practice checks cite the Claude Code docs.
4. Less is the goal: the app helps remove things more than add them.
