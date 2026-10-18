import ConfigCore
import Foundation

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
