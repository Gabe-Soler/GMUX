import CmuxFoundation
import CmuxGit
import Combine
import Foundation

/// State behind the Explorer's branch bar and Graph section: the checked-out
/// branch of the Explorer's folder and the commit graph of its repository.
///
/// All git work runs off the main actor. Changes under the repository's git
/// directory (commits, branch switches, fetches) refresh it on their own.
@MainActor
final class CommitGraphModel: ObservableObject {
    enum Availability: Equatable {
        /// The Explorer has no folder yet.
        case noFolder
        /// The folder is on another machine (SSH, Cloud); git runs locally only.
        case remote
        case notARepository
        case ready
    }

    @Published private(set) var availability: Availability = .noFolder
    @Published private(set) var repositoryRoot: URL?
    @Published private(set) var branchStatus: GitBranchStatus?
    @Published private(set) var rows: [CommitGraphRow] = [] {
        didSet { laneCount = rows.lazy.map(\.laneCount).max() ?? 1 }
    }
    /// The widest row's lane count, so every row's graph column has one width.
    @Published private(set) var laneCount = 1
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var expandedSHA: String?
    @Published private(set) var expandedFiles: [GitCommitFileChange] = []

    /// Whether the Graph section is open; history is only read while it is.
    var isGraphVisible = false {
        didSet {
            guard isGraphVisible != oldValue, isGraphVisible else { return }
            reloadHistory()
        }
    }

    private let service = GitHistoryService()
    private var layout = CommitGraphLayout()
    private var rootPath: String?
    private var rootTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var filesTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var storeSubscription: AnyCancellable?
    private var historyGeneration = 0

    /// Follows `store`'s root folder.
    func attach(to store: FileExplorerStore) {
        guard storeSubscription == nil else { return }
        storeSubscription = store.$rootPath
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] path in
                guard let self, let store else { return }
                self.setRoot(path: path, isLocal: store.provider is LocalFileExplorerProvider || store.provider == nil)
            }
    }

    func setRoot(path: String, isLocal: Bool) {
        let path = path.isEmpty ? nil : path
        guard path != rootPath else { return }
        rootPath = path
        rootTask?.cancel()
        watchTask?.cancel()
        statusTask?.cancel()
        historyTask?.cancel()
        filesTask?.cancel()
        clearHistory()
        branchStatus = nil
        repositoryRoot = nil
        guard let path else {
            availability = .noFolder
            return
        }
        guard isLocal else {
            availability = .remote
            return
        }
        let service = service
        rootTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> (root: URL, gitDirectories: [URL])? in
                guard let root = service.repositoryRoot(containing: URL(fileURLWithPath: path, isDirectory: true)) else {
                    return nil
                }
                return (root, service.gitDirectories(repositoryRoot: root))
            }.value
            guard let self, !Task.isCancelled, self.rootPath == path else { return }
            guard let found else {
                self.availability = .notARepository
                return
            }
            self.repositoryRoot = found.root
            self.availability = .ready
            self.refreshBranchStatus()
            if self.isGraphVisible { self.reloadHistory() }
            self.watch(found.gitDirectories)
        }
    }

    // MARK: - Refresh

    /// Re-reads the branch and, when the Graph is open, the first page of history.
    func refresh() {
        refreshBranchStatus()
        if isGraphVisible { reloadHistory() }
    }

    private func refreshBranchStatus() {
        guard let root = repositoryRoot else { return }
        let service = service
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                service.branchStatus(repositoryRoot: root)
            }.value
            guard let self, !Task.isCancelled, self.repositoryRoot == root else { return }
            if self.branchStatus != status { self.branchStatus = status }
        }
    }

    private func clearHistory() {
        historyGeneration &+= 1
        layout = CommitGraphLayout()
        rows = []
        hasMore = false
        isLoading = false
        expandedSHA = nil
        expandedFiles = []
    }

    /// Re-reads the first page and swaps it in at once, so the graph never blanks.
    private func reloadHistory() {
        historyTask?.cancel()
        historyGeneration &+= 1
        loadPage(replacing: true)
    }

    /// Loads the next page when the person scrolls near the end of the graph.
    func loadMoreIfNeeded(after row: CommitGraphRow) {
        guard hasMore, !isLoading, rows.suffix(20).contains(where: { $0.id == row.id }) else { return }
        loadPage(replacing: false)
    }

    private func loadPage(replacing: Bool) {
        guard let root = repositoryRoot else { return }
        let service = service
        let skip = replacing ? 0 : rows.count
        let generation = historyGeneration
        var layout = replacing ? CommitGraphLayout() : layout
        isLoading = true
        historyTask = Task { [weak self] in
            let page = await Task.detached(priority: .userInitiated) { () -> (rows: [CommitGraphRow], layout: CommitGraphLayout, full: Bool) in
                let commits = service.log(repositoryRoot: root, skip: skip)
                let rows = layout.append(commits)
                return (rows, layout, commits.count >= GitHistoryService.pageSize)
            }.value
            guard let self, !Task.isCancelled, self.historyGeneration == generation else { return }
            self.layout = page.layout
            if replacing {
                if self.rows != page.rows { self.rows = page.rows }
                // Keep an expanded commit open across refreshes while it is still listed.
                if let expanded = self.expandedSHA, !page.rows.contains(where: { $0.id == expanded }) {
                    self.expandedSHA = nil
                    self.expandedFiles = []
                }
            } else {
                self.rows.append(contentsOf: page.rows)
            }
            self.hasMore = page.full
            self.isLoading = false
        }
    }

    // MARK: - Commit files

    func toggleExpanded(_ commit: GitCommit) {
        filesTask?.cancel()
        if expandedSHA == commit.sha {
            expandedSHA = nil
            expandedFiles = []
            return
        }
        expandedSHA = commit.sha
        expandedFiles = []
        guard let root = repositoryRoot else { return }
        loadFiles(sha: commit.sha, root: root)
    }

    private func loadFiles(sha: String, root: URL) {
        guard let commit = rows.first(where: { $0.commit.sha == sha })?.commit else { return }
        let service = service
        filesTask = Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) {
                service.changedFiles(repositoryRoot: root, commit: commit)
            }.value
            guard let self, !Task.isCancelled, self.expandedSHA == sha else { return }
            self.expandedFiles = files
        }
    }

    // MARK: - Branches

    func branches() async -> [GitBranchRef] {
        guard let root = repositoryRoot else { return [] }
        let service = service
        return await Task.detached(priority: .userInitiated) {
            service.branches(repositoryRoot: root)
        }.value
    }

    /// Switches to `branch`. Returns git's explanation when it refuses.
    func switchBranch(to branch: GitBranchRef) async -> String? {
        guard let root = repositoryRoot else { return nil }
        let service = service
        let failure = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try service.switchBranch(repositoryRoot: root, to: branch)
                return nil
            } catch GitHistoryService.SwitchError.gitFailed(let message) {
                return message
            } catch {
                return error.localizedDescription
            }
        }.value
        refresh()
        return failure
    }

    // MARK: - Watching

    private func watch(_ directories: [URL]) {
        watchTask?.cancel()
        guard !directories.isEmpty else { return }
        watchTask = Task { [weak self] in
            let paths = await Task.detached { directories.map { Self.canonicalPath($0.path) } }.value
            guard let watcher = await RecursivePathWatcher(
                paths: paths,
                throttleInterval: .milliseconds(300),
                eventFilter: { change in
                    change.requiresFullRescan || change.paths.contains { Self.isRelevantGitPath($0) }
                }
            ) else { return }
            for await change in watcher.pathEvents {
                guard let self, !Task.isCancelled else { break }
                // Index writes (staging, a shell prompt's `git status`) only change
                // the dirty state; history reloads only when refs or HEAD move.
                if change.requiresFullRescan || change.paths.contains(where: Self.movesHistory) {
                    self.refresh()
                } else {
                    self.refreshBranchStatus()
                }
            }
            await watcher.stop()
        }
    }

    /// Ref, HEAD and index updates matter; object writes and lock files are noise.
    nonisolated static func isRelevantGitPath(_ path: String) -> Bool {
        if path.contains("/objects/") || path.hasSuffix(".lock") { return false }
        let name = (path as NSString).lastPathComponent
        return path.contains("/refs/")
            || ["HEAD", "ORIG_HEAD", "FETCH_HEAD", "packed-refs", "index", "reftable"].contains(name)
            || path.contains("/reftable/")
    }

    nonisolated static func movesHistory(_ path: String) -> Bool {
        isRelevantGitPath(path) && (path as NSString).lastPathComponent != "index"
    }

    nonisolated private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
