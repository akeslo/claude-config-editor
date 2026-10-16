import Foundation

/// Every concept the app shows, with a one-line tooltip and a longer "how it fits into Claude Code" explanation.
public enum Term: String, CaseIterable, Sendable {
    case claudeJSON, settings, managedSettings, precedence, project, transcripts, purge, cleanupPeriod
    case mcpServer, mcpScope, skill, skillListing, subagent, command, outputStyle, plugin, marketplace
    case hook, permissions, allowedTools, claudeMD, claudeLocalMD, rules, autoMemory, contextWindow
    case scratch, jobs, pluginData, fileHistory, claudeBackups, appBackups, caches, unknownFolder
    case keybindings, statusLine, theme, env, strayFiles

    public var title: String {
        switch self {
        case .claudeJSON: "~/.claude.json"
        case .settings: "Settings files"
        case .managedSettings: "Managed settings"
        case .precedence: "Setting precedence"
        case .project: "Project entry"
        case .transcripts: "Transcripts"
        case .purge: "Purge"
        case .cleanupPeriod: "Automatic cleanup"
        case .mcpServer: "MCP server"
        case .mcpScope: "MCP scope"
        case .skill: "Skill"
        case .skillListing: "Skill listing budget"
        case .subagent: "Subagent"
        case .command: "Command"
        case .outputStyle: "Output style"
        case .plugin: "Plugin"
        case .marketplace: "Marketplace"
        case .hook: "Hook"
        case .permissions: "Permission rules"
        case .allowedTools: "Per-project allowed tools"
        case .claudeMD: "CLAUDE.md"
        case .claudeLocalMD: "CLAUDE.local.md"
        case .rules: "Rules"
        case .autoMemory: "Auto memory"
        case .contextWindow: "Startup context"
        case .scratch: "Scratch folders"
        case .jobs: "Background jobs"
        case .pluginData: "Plugin data"
        case .fileHistory: "File history"
        case .claudeBackups: "Claude's backups"
        case .appBackups: "This app's backups"
        case .caches: "Caches"
        case .unknownFolder: "Other folder"
        case .keybindings: "Keybindings"
        case .statusLine: "Status line"
        case .theme: "Theme"
        case .env: "Environment variables"
        case .strayFiles: "Leftover files"
        }
    }

    /// One or two sentences, used as the hover tooltip.
    public var tooltip: String {
        switch self {
        case .claudeJSON: "Claude Code's own state file: sign-in, per-project trust and history, user MCP servers. Claude rewrites it often."
        case .settings: "JSON files that configure Claude Code. User settings apply everywhere; project settings apply inside one repo."
        case .managedSettings: "Settings set by an administrator. They win over everything and this app never edits them."
        case .precedence: "When the same setting is in several files, the most specific wins: managed, then project local, project, user."
        case .project: "One entry per folder you have run Claude in. Holds trust, allowed tools, local MCP servers and stats."
        case .transcripts: "Full logs of each session, used by --resume. Plain text, and may contain anything a tool read, including secrets."
        case .purge: "`claude purge` deletes a project's transcripts, memory, history lines and its ~/.claude.json entry."
        case .cleanupPeriod: "cleanupPeriodDays: Claude deletes transcripts and checkpoints older than this many days (default 30)."
        case .mcpServer: "An external tool server Claude connects to. Its tool names cost context in every session where it is active."
        case .mcpScope: "Where an MCP server is defined: local (one project, private), project (.mcp.json, shared), or user (everywhere)."
        case .skill: "A folder with SKILL.md. Its description is always in context; the body loads only when the skill is used."
        case .skillListing: "All skill descriptions share a budget of about 1% of the context window. Past it, the least-used lose their description."
        case .subagent: "A helper with its own context window, defined in agents/*.md. Its description is in context so Claude knows when to use it."
        case .command: "Legacy slash command in commands/*.md. A skill with the same name wins."
        case .outputStyle: "Changes how Claude writes its replies, defined in output-styles/*.md."
        case .plugin: "A bundle of skills, agents, hooks and MCP servers installed from a marketplace. Can be enabled or disabled."
        case .marketplace: "A catalog of plugins (usually a GitHub repo). Official marketplaces update automatically."
        case .hook: "A command Claude runs on an event (session start, before a tool, on stop). Some hook output is added to context."
        case .permissions: "allow / ask / deny rules that decide which tools Claude can use without asking."
        case .allowedTools: "Tools you approved for one project, stored in ~/.claude.json. These pile up over time."
        case .claudeMD: "Instructions loaded into every session. Keep each file under 200 lines; all found files are combined."
        case .claudeLocalMD: "Personal project instructions that should not be committed. Loaded after CLAUDE.md."
        case .rules: "Markdown files in .claude/rules/. With paths: frontmatter they load only when matching files are touched."
        case .autoMemory: "Notes Claude keeps per project. The first 200 lines of MEMORY.md load at every session start."
        case .contextWindow: "What is already in the context window before you type: instructions, memory, skill and agent descriptions, tool names."
        case .scratch: "Per-session temp folders and background task output in /private/tmp. Claude does not clean them."
        case .jobs: "Data from background jobs and scheduled tasks."
        case .pluginData: "Installed plugin code, marketplace copies and plugin caches."
        case .fileHistory: "Checkpoints of edited files, used to rewind. Cleaned automatically."
        case .claudeBackups: "Claude's own copies of ~/.claude.json (it keeps the last 5)."
        case .appBackups: "Copies this app saves before every change it makes."
        case .caches: "Rebuildable caches. Safe to clear."
        case .unknownFolder: "A folder this app does not recognize. Look before deleting."
        case .keybindings: "Custom keyboard shortcuts in ~/.claude/keybindings.json."
        case .statusLine: "Command that draws the status line under the prompt."
        case .theme: "Terminal colors for Claude Code."
        case .env: "Environment variables Claude Code sets for every session and tool."
        case .strayFiles: "Old .bak copies and similar files left in ~/.claude. Claude does not read them."
        }
    }

    /// Longer explanation for the side panel.
    public var detail: String {
        switch self {
        case .claudeJSON: "Claude Code writes this file for itself. It holds your sign-in, UI state, usage stats, user-scope MCP servers, and one entry per project folder. It grows as you open more folders. Claude keeps 5 backups of it in ~/.claude/backups/. Prefer `claude purge` and `claude mcp` over editing it, and never edit it while it is being written."
        case .settings: "Claude Code reads settings from several files and merges them. User settings (~/.claude/settings.json) apply everywhere. Project settings (.claude/settings.json) are committed and shared with your team. Project local settings (.claude/settings.local.json) are personal and gitignored. Edits reload in a running session, but some keys only apply at session start."
        case .managedSettings: "Settings from managed-settings.json, MDM or the admin console. They override every other source and cannot be changed by users. Shown here with a lock."
        case .precedence: "Order from highest to lowest: managed, --settings flag, project local, project, user. Arrays like permission rules are combined; plain values are taken from the highest source that sets them."
        case .project: "Every folder you start Claude in gets an entry: whether you trusted it, the tools you allowed, project-local MCP servers, and last-session stats. Deleting the entry also removes the trust decision and allowed tools, so Claude asks again next time. Transcripts and memory for the project live separately in ~/.claude/projects/."
        case .transcripts: "Each session is saved as a .jsonl file in ~/.claude/projects/<project>/. --resume and --continue read them. They are not encrypted, and contain tool output such as file contents. Claude deletes ones older than cleanupPeriodDays."
        case .purge: "`claude purge <path>` removes everything Claude stores for one project: transcripts, auto memory, matching history.jsonl lines, and the ~/.claude.json entry (trust, allowed tools, local MCP servers). This app always shows the --dry-run output first."
        case .cleanupPeriod: "Claude sweeps transcripts, subagent transcripts, tool results and file history older than cleanupPeriodDays (default 30, minimum 1). It does not touch ~/.claude.json, settings, plugins or memory, and does not clean /private/tmp scratch folders."
        case .mcpServer: "MCP servers give Claude extra tools. With tool search (on by default) only tool names are in context until a tool is needed, but many servers still add up. Secrets belong in ${VAR} references, not literal values."
        case .mcpScope: "Local scope is stored in ~/.claude.json under one project. Project scope is .mcp.json in the repo and needs a one-time approval. User scope applies in every project. If the same name exists in several scopes, the most specific wins and its whole entry replaces the others."
        case .skill: "Skills live in ~/.claude/skills (personal), .claude/skills (project) or inside plugins. Only the name and description are always in context; the SKILL.md body loads when the skill is invoked. Keep SKILL.md under 500 lines and move reference material to linked files. Set disable-model-invocation: true for skills you only run by hand, so they leave the always-on listing."
        case .skillListing: "The skill listing is capped at about 1% of the context window. When there are more descriptions than fit, Claude drops descriptions of the least-used skills first. Description plus when_to_use is cut at 1,536 characters. skillOverrides can set a skill to name-only."
        case .subagent: "Subagents run in their own context window, so heavy reading does not fill your main session. Their name and description are listed so Claude can pick them."
        case .command: "Older form of slash commands. Skills replace them; if both share a name, the skill is used."
        case .outputStyle: "Output styles change the system prompt's guidance on tone and format."
        case .plugin: "Plugins package skills, subagents, hooks, MCP servers and output styles. Disabled plugins cost no context but keep their files on disk. `claude plugin details` reports a plugin's always-on token cost."
        case .marketplace: "Marketplaces are added with `claude plugin marketplace add`. Plugins from official Anthropic marketplaces auto-update; others update with `claude plugin update`."
        case .hook: "Hooks are configured under the hooks key of a settings file, in a plugin's hooks/hooks.json, or in skill and agent frontmatter. Output from SessionStart and UserPromptSubmit hooks is added to the context (capped at 10,000 characters per field), so chatty hooks cost tokens every session. A matcher must be a single string."
        case .permissions: "Rules like Bash(npm test:*) or mcp__server. deny beats ask beats allow. Very broad allows such as Bash(*) remove most protection. defaultMode bypassPermissions is ignored in project files."
        case .allowedTools: "When you approve a tool 'for this project', Claude stores it in the project's entry in ~/.claude.json. Long lists usually mean approvals that should be a single user-level rule, or old approvals nobody needs."
        case .claudeMD: "CLAUDE.md files from the filesystem root down to the working folder are all loaded and combined, plus ~/.claude/CLAUDE.md. Keep each under 200 lines and specific. @imports organize a file but still load everything. Move path-specific guidance into .claude/rules/ with paths: frontmatter."
        case .claudeLocalMD: "Personal notes for one project. Add it to .gitignore so it is not committed."
        case .rules: "Rule files are loaded like CLAUDE.md, unless they have paths: frontmatter, in which case they load only when Claude works with matching files. That makes them the main tool for trimming CLAUDE.md."
        case .autoMemory: "Auto memory lives in ~/.claude/projects/<project>/memory/. MEMORY.md is the index: the first 200 lines (or 25 KB) load at session start; the files it links load when needed. Broken links and very long indexes waste context."
        case .contextWindow: "Before your first message, the context holds the system prompt, CLAUDE.md files, MEMORY.md, the skill and subagent listing, MCP tool names, and SessionStart hook output. Numbers here are estimates (about 4 characters per token); run /context inside Claude for exact figures."
        case .scratch: "Claude Code creates a scratch folder and task-output files per session under /private/tmp/claude-<uid>/. Claude's cleanup does not touch them. Folders of finished sessions are safe to delete."
        case .jobs: "State and output of background and scheduled jobs."
        case .pluginData: "~/.claude/plugins holds installed plugin versions (cache), marketplace clones and per-plugin data. Old versions and uninstalled plugins can leave files behind; remove plugins with `claude plugin uninstall` rather than deleting folders."
        case .fileHistory: "Checkpoints that let you rewind edits. Claude keeps the 100 most recent and sweeps old ones."
        case .claudeBackups: "Claude copies ~/.claude.json here before rewriting it, keeping the 5 newest plus any copy it could not read."
        case .appBackups: "Every file this app changes is copied here first, with a timestamp. Restore from the Storage section."
        case .caches: "paste-cache, image-cache, shell snapshots and similar. Claude rebuilds them as needed."
        case .unknownFolder: "Not part of Claude Code's documented layout. It may belong to a plugin or a tool you installed. Check before clearing."
        case .keybindings: "~/.claude/keybindings.json maps keys to actions. Global only."
        case .statusLine: "The statusLine setting runs a command after each message to draw a status bar. Slow commands slow the UI."
        case .theme: "The theme setting picks Claude Code's color scheme."
        case .env: "The env setting exports variables to every session and tool. Avoid literal secrets here; they end up in settings files and process environments."
        case .strayFiles: "Hand-made copies like settings.json.bak are never read by Claude. They often contain old secrets. Safe to move to the Trash once you no longer need them."
        }
    }

    public var docURL: URL {
        let page: String = switch self {
        case .claudeJSON, .project, .transcripts, .purge, .cleanupPeriod, .scratch, .jobs, .pluginData, .fileHistory, .claudeBackups, .appBackups, .caches, .unknownFolder, .strayFiles, .keybindings, .theme:
            "claude-directory"
        case .settings, .managedSettings, .precedence, .env, .statusLine: "settings"
        case .mcpServer, .mcpScope: "mcp"
        case .skill, .skillListing, .command: "skills"
        case .subagent: "sub-agents"
        case .outputStyle: "output-styles"
        case .plugin, .marketplace: "plugins"
        case .hook: "hooks"
        case .permissions, .allowedTools: "iam"
        case .claudeMD, .claudeLocalMD, .rules, .autoMemory: "memory"
        case .contextWindow: "context-window"
        }
        return URL(string: "https://code.claude.com/docs/en/\(page)")!
    }
}
