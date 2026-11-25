import Foundation

/// Resolves the git status a file explorer row should draw.
///
/// `git status --ignored=matching` names an ignored folder (`node_modules/`)
/// once and never lists what is inside it, so a row inherits `.ignored` from
/// its nearest ignored ancestor below the explorer root.
enum FileExplorerGitStatusLookup {
    static func status(
        for path: String,
        in statusByPath: [String: GitFileStatus],
        rootPath: String
    ) -> GitFileStatus? {
        if let direct = statusByPath[path] { return direct }
        guard !statusByPath.isEmpty, !rootPath.isEmpty, path.hasPrefix(rootPath) else { return nil }
        var current = (path as NSString).deletingLastPathComponent
        while current.count > rootPath.count, current.hasPrefix(rootPath) {
            if statusByPath[current] == .ignored { return .ignored }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}
