import ConfigCore
import Foundation

do {
    let a = try SkillSearch.parse(Array(CommandLine.arguments.dropFirst()))
    let hits = SkillSearch.rank(a.query, installed: SkillSearch.installedSkills(), available: SkillSearch.localAvailable(), limit: a.limit)
    print(SkillSearch.format(hits, json: a.json))
} catch {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(2)
}
