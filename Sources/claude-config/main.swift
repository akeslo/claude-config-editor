import ConfigCore
import Foundation

// `claude-config --backups`: read-only list of backup files next to Claude config (what the Backups screen shows).
if CommandLine.arguments.dropFirst().first == "--backups" {
    let projects = ((readJSON(Paths.claudeJSON)?["projects"] as? JSON) ?? [:]).keys.sorted()
    let r = BackupFiles.roots(projects: projects)
    for b in BackupFiles.scan(deep: r.deep, shallow: r.shallow) { print("\(shortPath(b.url))\t→ \(shortPath(b.original))\t\(b.size)") }
    exit(0)
}

do {
    let a = try SkillSearch.parse(Array(CommandLine.arguments.dropFirst()))
    async let community = SkillSearch.community()
    let hits = SkillSearch.rank(a.query, installed: SkillSearch.installedSkills(), available: SkillSearch.localAvailable(),
                                community: await community, limit: a.limit)
    print(SkillSearch.format(hits, json: a.json))
} catch {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(2)
}
