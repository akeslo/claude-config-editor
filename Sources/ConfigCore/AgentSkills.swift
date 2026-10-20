import Foundation

/// Coding agents whose skill folders the app reads. Skills are SKILL.md folders, so the same one works in each.
public enum SkillAgent: String, CaseIterable, Sendable, Codable {
    case claude = "Claude", agents = "Shared (.agents)", codex = "Codex", opencode = "opencode", gemini = "Gemini"

    /// The personal skills folder under `home` (Gemini only has per-extension folders).
    public func skillsDir(home: URL = Paths.home) -> URL? {
        switch self {
        case .claude: home.appending(path: ".claude/skills")
        case .agents: home.appending(path: ".agents/skills")
        case .codex: home.appending(path: ".codex/skills")
        case .opencode: home.appending(path: ".config/opencode/skills")
        case .gemini: nil
        }
    }
    /// Where Install to… can copy a skill.
    /// Every non-Claude skill folder under `home`, tagged with its agent.
    public static func otherSkillDirs(home: URL = Paths.home) -> [(SkillAgent, URL)] {
        var out: [(SkillAgent, URL)] = []
        for a in [SkillAgent.agents, .codex, .opencode] { if let d = a.skillsDir(home: home) { out += children(d).map { (a, $0) } } }
        for ext in children(home.appending(path: ".gemini/extensions")) { out += children(ext.appending(path: "skills")).map { (.gemini, $0) } }
        return out.filter { exists($0.1.appending(path: "SKILL.md")) }
    }
}

extension Scanner {
    /// Folds other agents' skills into `out`: a folder with the same name or real path as a personal skill already
    /// listed adds its agent and location to that one; anything else becomes a `.external` skill. Plugin and project skills are left alone.
    static func mergeAgentSkills(_ out: [Component], dirs: [(SkillAgent, URL)]) -> [Component] {
        var out = out
        func key(_ dir: URL) -> String { dir.resolvingSymlinksInPath().standardizedFileURL.path }
        for (agent, dir) in dirs {
            let real = key(dir)
            if let i = out.firstIndex(where: { c in
                c.kind == .skill && (c.scope == .user || c.scope == .external)
                    && (c.file.deletingLastPathComponent().lastPathComponent == dir.lastPathComponent || key(c.file.deletingLastPathComponent()) == real)
            }) {
                if !out[i].agents.contains(agent) { out[i].agents.append(agent) }
                out[i].locations.append(dir.appending(path: "SKILL.md"))
            } else {
                var c = component(.skill, dir.appending(path: "SKILL.md"), dir.lastPathComponent, .external, nil, "")
                c.agents = [agent]
                out.append(c)
            }
        }
        return out
    }
}

/// Ready-to-paste text that tells any agent (Claude Code, Codex, Gemini) to load the chosen skills for a task.
public func skillPrompt(_ skills: [Component]) -> String {
    let lines = skills.map { s in
        let first = s.description.split(separator: "\n").first.map(String.init) ?? ""
        return "- \(s.shortName): \(first.isEmpty ? "(no description)" : first)\n  SKILL.md: \(s.file.path)"
    }
    return (["Task: {task}", "",
             "Use these skills for the task above. For each one, read its SKILL.md at the path given (even if your agent does not have the skill installed) and follow its instructions:", ""]
            + lines).joined(separator: "\n")
}
