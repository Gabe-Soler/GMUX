import Foundation

/// Maps a batch of filesystem change paths to the loaded folders a file tree
/// must re-list, so a change deep in the tree refreshes one folder instead of
/// rebuilding the whole tree.
struct FileExplorerChangeRouter {
    struct Plan: Equatable {
        /// Loaded folders (the root included) whose children must be re-listed.
        var directories: Set<String> = []
        /// Whether `git status` should run again.
        var refreshGitStatus = false
    }

    /// The explorer root as the tree spells it.
    let rootPath: String
    /// The same root with symlinks resolved; FSEvents reports this spelling.
    let canonicalRootPath: String

    init(rootPath: String, canonicalRootPath: String? = nil) {
        self.rootPath = Self.trimmed(rootPath)
        self.canonicalRootPath = Self.trimmed(canonicalRootPath ?? rootPath)
    }

    /// - Parameters:
    ///   - changedPaths: Absolute paths from one coalesced FSEvents window.
    ///   - requiresFullRescan: The OS dropped events; refresh every loaded folder.
    ///   - loadedDirectories: Folders whose children are currently loaded.
    ///   - isIgnored: Whether a path is git-ignored, so churn there (`node_modules`,
    ///     build output) does not re-run `git status`.
    func plan(
        changedPaths: [String],
        requiresFullRescan: Bool,
        loadedDirectories: Set<String>,
        isIgnored: (String) -> Bool = { _ in false }
    ) -> Plan {
        var plan = Plan()
        if requiresFullRescan {
            plan.directories = loadedDirectories.union([rootPath])
            plan.refreshGitStatus = true
            return plan
        }
        for rawPath in changedPaths {
            guard let path = treePath(for: rawPath) else { continue }
            if let gitRelative = Self.gitMetadataSuffix(of: path, root: rootPath) {
                // Commits, staging and checkouts change status but not the tree.
                if gitRelative == "index" || gitRelative == "HEAD" || gitRelative.hasPrefix("refs") {
                    plan.refreshGitStatus = true
                }
                continue
            }
            let parent = path == rootPath ? rootPath : (path as NSString).deletingLastPathComponent
            if parent == rootPath || loadedDirectories.contains(parent) {
                plan.directories.insert(parent)
            }
            if path != rootPath, loadedDirectories.contains(path) {
                plan.directories.insert(path)
            }
            if !isIgnored(path) {
                plan.refreshGitStatus = true
            }
        }
        return plan
    }

    /// Re-spells an FSEvents path under the tree's root, or nil when it is outside it.
    func treePath(for rawPath: String) -> String? {
        let path = Self.trimmed(rawPath)
        if path == rootPath || path.hasPrefix(rootPath + "/") { return path }
        if canonicalRootPath != rootPath,
           path == canonicalRootPath || path.hasPrefix(canonicalRootPath + "/") {
            return rootPath + String(path.dropFirst(canonicalRootPath.count))
        }
        return nil
    }

    /// The path below `<root>/.git/`, or nil when `path` is not inside it.
    private static func gitMetadataSuffix(of path: String, root: String) -> String? {
        let gitDirectory = root == "/" ? "/.git" : root + "/.git"
        if path == gitDirectory { return "" }
        guard path.hasPrefix(gitDirectory + "/") else { return nil }
        return String(path.dropFirst(gitDirectory.count + 1))
    }

    private static func trimmed(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
