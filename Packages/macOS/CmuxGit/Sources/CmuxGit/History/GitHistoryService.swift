public import Foundation

/// Reads commit history, branches and per-commit changes for the history graph,
/// and switches branches.
///
/// Every call runs git synchronously with bounded output and a time limit,
/// so call it off the main actor.
public struct GitHistoryService: Sendable {
    /// Commits fetched per page of the graph.
    public static let pageSize = 200
    /// Ceiling for one file's contents read at a commit.
    public static let maximumFileByteCount = 8 * 1024 * 1024

    public enum SwitchError: Error, Equatable, Sendable {
        /// git refused; `message` is its own explanation.
        case gitFailed(message: String)
    }

    private let runner: any WorkspaceChangesGitRunning
    private let switchCommand: @Sendable (_ arguments: [String], _ directory: URL) -> (status: Int32, message: String)

    public init() {
        self.init(runner: SystemWorkspaceChangesGitRunner(), switchCommand: Self.runCapturingErrors)
    }

    init(
        runner: any WorkspaceChangesGitRunning,
        switchCommand: @escaping @Sendable (_ arguments: [String], _ directory: URL) -> (status: Int32, message: String)
    ) {
        self.runner = runner
        self.switchCommand = switchCommand
    }

    /// The top-level directory of the repository containing `directory`, or `nil`.
    public func repositoryRoot(containing directory: URL) -> URL? {
        guard let result = try? runner.run(
            arguments: ["rev-parse", "--show-toplevel"],
            in: directory,
            maximumOutputByteCount: 16 * 1024,
            wallTimeLimit: 10
        ), result.exitCode == 0 else { return nil }
        let path = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The directories whose changes mean history or the checked-out branch moved:
    /// the worktree's git dir (HEAD, index) and the shared common dir (refs).
    public func gitDirectories(repositoryRoot root: URL) -> [URL] {
        guard let result = try? runner.run(
            arguments: ["rev-parse", "--absolute-git-dir", "--git-common-dir"],
            in: root,
            maximumOutputByteCount: 16 * 1024,
            wallTimeLimit: 10
        ), result.exitCode == 0 else { return [] }
        var directories: [URL] = []
        for line in String(decoding: result.output, as: UTF8.self).split(separator: "\n") {
            let path = String(line).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path, isDirectory: true)
                : root.appendingPathComponent(path, isDirectory: true)
            let standardized = url.standardizedFileURL
            if !directories.contains(standardized) { directories.append(standardized) }
        }
        return directories
    }

    /// One page of history: HEAD, its upstream and `origin/HEAD` when they exist,
    /// newest first in topological order.
    public func log(repositoryRoot root: URL, skip: Int = 0, limit: Int = pageSize) -> [GitCommit] {
        var revisions = ["HEAD"]
        if let upstream = resolvedRef("@{upstream}", in: root) { revisions.append(upstream) }
        if let originHead = resolvedRef("refs/remotes/origin/HEAD", in: root) { revisions.append(originHead) }
        let arguments = [
            "-c", "log.showSignature=false",
            "log", "--topo-order", "--decorate=full",
            "--format=\(GitLogParser.logFormat)",
            "--skip=\(max(0, skip))", "-n", "\(max(1, limit))",
        ] + revisions + ["--"]
        guard let result = try? runner.run(
            arguments: arguments,
            in: root,
            maximumOutputByteCount: 16 * 1024 * 1024,
            wallTimeLimit: 20
        ), result.exitCode == 0 else { return [] }
        return GitLogParser.commits(from: result.output)
    }

    /// The files `commit` changed against its first parent (or the empty tree for a root commit).
    public func changedFiles(repositoryRoot root: URL, commit: GitCommit) -> [GitCommitFileChange] {
        var arguments = ["diff-tree", "-r", "-M", "-z", "--name-status", "--no-commit-id"]
        if let parent = commit.parents.first {
            arguments += [parent, commit.sha]
        } else {
            arguments += ["--root", commit.sha]
        }
        guard let result = try? runner.run(
            arguments: arguments,
            in: root,
            maximumOutputByteCount: 4 * 1024 * 1024,
            wallTimeLimit: 20
        ), result.exitCode == 0 else { return [] }
        return GitLogParser.fileChanges(from: result.output)
    }

    /// A file's contents at `revision` (`sha` or `sha^`), or `nil` when it does not
    /// exist there, is binary, or is larger than ``maximumFileByteCount``.
    public func fileContents(repositoryRoot root: URL, revision: String, path: String) -> String? {
        guard let result = try? runner.run(
            arguments: ["show", "\(revision):\(path)"],
            in: root,
            maximumOutputByteCount: Self.maximumFileByteCount + 1,
            wallTimeLimit: 20
        ), result.exitCode == 0, !result.standardOutputWasTruncated else { return nil }
        guard !result.output.prefix(8_000).contains(0) else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }

    /// The checked-out branch, its upstream, ahead/behind counts and whether
    /// tracked files are modified.
    public func branchStatus(repositoryRoot root: URL) -> GitBranchStatus? {
        guard let result = try? runner.run(
            arguments: ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no", "--ignore-submodules=all"],
            in: root,
            maximumOutputByteCount: 4 * 1024 * 1024,
            wallTimeLimit: 15
        ), result.exitCode == 0 else { return nil }
        return GitLogParser.branchStatus(from: result.output)
    }

    /// Local branches, then remote branches, each most recently committed first.
    public func branches(repositoryRoot root: URL) -> [GitBranchRef] {
        guard let result = try? runner.run(
            arguments: [
                "for-each-ref", "--sort=-committerdate",
                "--format=%(refname)%00%(committerdate:unix)",
                "refs/heads", "refs/remotes",
            ],
            in: root,
            maximumOutputByteCount: 4 * 1024 * 1024,
            wallTimeLimit: 15
        ), result.exitCode == 0 else { return [] }
        let all = GitLogParser.branches(from: result.output)
        return all.filter { !$0.isRemote } + all.filter(\.isRemote)
    }

    /// Checks out `branch`. A remote branch switches to its local branch,
    /// creating one that tracks the remote when none exists. git refuses on its
    /// own when the switch would overwrite local changes.
    public func switchBranch(repositoryRoot root: URL, to branch: GitBranchRef) throws(SwitchError) {
        // git forbids ref names starting with "-", so a name is never read as an option;
        // refuse one anyway rather than trust the caller.
        guard !branch.name.hasPrefix("-"), !branch.localName.hasPrefix("-") else {
            throw .gitFailed(message: "Invalid branch name")
        }
        let arguments: [String]
        if branch.isRemote {
            let localExists = resolvedRef("refs/heads/\(branch.localName)", in: root) != nil
            arguments = localExists
                ? ["switch", branch.localName]
                : ["switch", "--track", branch.name]
        } else {
            arguments = ["switch", branch.name]
        }
        let outcome = switchCommand(arguments, root)
        guard outcome.status == 0 else {
            let message = outcome.message.trimmingCharacters(in: .whitespacesAndNewlines)
            throw .gitFailed(message: message.isEmpty ? "git switch failed" : message)
        }
    }

    private func resolvedRef(_ ref: String, in root: URL) -> String? {
        guard let result = try? runner.run(
            arguments: ["rev-parse", "--verify", "--quiet", "--symbolic-full-name", ref],
            in: root,
            maximumOutputByteCount: 16 * 1024,
            wallTimeLimit: 10
        ), result.exitCode == 0 else { return nil }
        let value = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Runs a mutating git command and keeps its error text, which the bounded
    /// runner discards.
    private static func runCapturingErrors(_ arguments: [String], _ directory: URL) -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = SystemGitExecutableResolver(environment: ProcessInfo.processInfo.environment)
            .executableURLs().first ?? URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY"] {
            environment.removeValue(forKey: key)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data.prefix(16 * 1024), as: UTF8.self))
    }
}
