import Foundation
import IrisCore

struct SkillReport: Encodable {
    struct Place: Encodable {
        var path: String
        /// `written`, or `linked` when the place is a link somebody made (to a checkout,
        /// say) and was left alone.
        var status: String
    }
    var skill = "iris-recording"
    var installed: [Place]
}

/// `iris skill`: puts the guide where a coding agent looks for skills, so an installation
/// without the repository (Homebrew, a downloaded binary) can teach its agents too.
func skillCommand(_ raw: [String]) throws {
    var args = Args(raw, flags: ["claude", "codex"])
    let home = FileManager.default.homeDirectoryForCurrentUser
    var roots: [URL] = []
    if args.flag("claude") { roots.append(home.appendingPathComponent(".claude/skills")) }
    if args.flag("codex") {
        let codex = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        roots.append(codex.appendingPathComponent("skills"))
    }
    if let dir = args.string("dir") {
        roots.append(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
    }
    try args.finish()
    guard args.positionals.isEmpty else { throw IrisError("unexpected \"\(args.positionals[0])\"") }
    guard !roots.isEmpty else {
        print(Guide.skill, terminator: "")
        return
    }

    var places: [SkillReport.Place] = []
    for root in roots {
        let dir = root.appendingPathComponent("iris-recording")
        let file = dir.appendingPathComponent("SKILL.md")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: dir.path)) != nil {
            places.append(.init(path: file.path, status: "linked"))
            continue
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(Guide.skill.utf8).write(to: file, options: .atomic)
        places.append(.init(path: file.path, status: "written"))
    }
    printJSON(SkillReport(installed: places))
}
