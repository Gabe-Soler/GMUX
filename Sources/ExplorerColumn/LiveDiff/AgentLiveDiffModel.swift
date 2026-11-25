import CmuxFoundation
import CmuxGit
import Foundation
import SwiftUI

/// Live diff of one file an agent is editing, against its last committed
/// version (`git show HEAD:<file>`; empty for a new or untracked file).
///
/// Disk reads, git and diffing run off the main actor. Each change on disk
/// produces a new row set; rows new since the last update are revealed one line
/// at a time so additions and removals can be watched as they land.
@MainActor
final class AgentLiveDiffModel: ObservableObject {
    /// What the diff compares.
    enum Source: Sendable, Equatable {
        /// The file on disk against its last commit, updating as an agent edits it.
        case workingTree(agent: String)
        /// One file's change in a commit, against the commit's first parent. Static.
        case commit(repositoryRoot: URL, sha: String, parentSHA: String?, path: String, oldPath: String?)
    }

    let filePath: String
    let source: Source

    /// The agent editing the file, for a working-tree diff.
    var agent: String {
        if case .workingTree(let agent) = source { return agent }
        return ""
    }

    /// The commit shown, for a commit diff.
    var commitSHA: String? {
        if case .commit(_, let sha, _, _, _) = source { return sha }
        return nil
    }

    @Published private(set) var rows: [LiveDiffRow] = []
    /// Rows not yet revealed by the line-by-line animation.
    @Published private(set) var hiddenIds: Set<Int> = []
    /// Rows changed by the latest edit, drawn brighter for a moment.
    @Published private(set) var highlightedIds: Set<Int> = []
    /// Scroll request: the first row the latest edit changed.
    @Published private(set) var scrollTarget: Int?
    @Published private(set) var scrollGeneration = 0
    @Published private(set) var addedCount = 0
    @Published private(set) var removedCount = 0
    @Published private(set) var notice: String?

    /// Per-line reveal delay, shortened for big edits so a burst takes ≲1.2s.
    static let revealStep: Duration = .milliseconds(28)
    static let maximumRevealSteps = 40
    static let highlightDuration: Duration = .milliseconds(1_400)

    private var baseline: [String]?
    private var nextId = 0
    private var updateTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var needsAnotherUpdate = false

    convenience init(filePath: String, agent: String) {
        self.init(filePath: filePath, source: .workingTree(agent: agent))
    }

    init(filePath: String, source: Source) {
        self.filePath = filePath
        self.source = source
        if case .workingTree = source { startWatching() }
        refresh()
    }

    deinit {
        watchTask?.cancel()
        updateTask?.cancel()
        revealTask?.cancel()
    }

    func stop() {
        watchTask?.cancel()
        updateTask?.cancel()
        revealTask?.cancel()
    }

    /// Re-reads the file and diffs it; coalesces while an update is running.
    func refresh() {
        guard updateTask == nil else {
            needsAnotherUpdate = true
            return
        }
        let path = filePath
        let source = source
        let knownBaseline = baseline
        let previous = rows
        let firstId = nextId
        updateTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (baseline: [String], update: LiveDiffRows.Update?, notice: String?) in
                let base = knownBaseline ?? Self.baselineLines(of: path, source: source)
                guard let current = Self.currentLines(of: path, source: source) else {
                    return (base, nil, String(localized: "liveDiff.notice.unreadable", defaultValue: "This file can't be shown as text."))
                }
                guard base.count <= LiveDiffRows.maximumLines, current.count <= LiveDiffRows.maximumLines else {
                    return (base, nil, String(localized: "liveDiff.notice.tooLarge", defaultValue: "This file is too large for a live diff."))
                }
                return (base, LiveDiffRows.update(previous: previous, nextId: firstId, baseline: base, current: current), nil)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.updateTask = nil
            self.baseline = result.baseline
            self.notice = result.notice
            if let update = result.update { self.apply(update) }
            if self.needsAnotherUpdate {
                self.needsAnotherUpdate = false
                self.refresh()
            }
        }
    }

    private func apply(_ update: LiveDiffRows.Update) {
        let isFirstLoad = rows.isEmpty && nextId == 0
        nextId = update.nextId
        addedCount = update.rows.lazy.filter { $0.kind == .added }.count
        removedCount = update.rows.lazy.filter { $0.kind == .removed }.count
        // The first load shows the existing diff at once; later edits animate.
        let fresh = isFirstLoad ? [] : update.freshIds
        revealTask?.cancel()
        hiddenIds = Set(fresh)
        withAnimation(.easeOut(duration: 0.18)) {
            rows = update.rows
        }
        guard let first = fresh.first ?? (isFirstLoad ? update.rows.first(where: { $0.kind != .unchanged })?.id : nil) else {
            return
        }
        scrollTarget = first
        scrollGeneration &+= 1
        guard !fresh.isEmpty else { return }
        highlightedIds.formUnion(fresh)
        let chunk = max(1, Int((Double(fresh.count) / Double(Self.maximumRevealSteps)).rounded(.up)))
        revealTask = Task { [weak self] in
            var index = 0
            while index < fresh.count {
                let batch = fresh[index..<min(index + chunk, fresh.count)]
                index += chunk
                guard let self, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    self.hiddenIds.subtract(batch)
                }
                try? await Task.sleep(for: Self.revealStep)
            }
            try? await Task.sleep(for: Self.highlightDuration)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                self.highlightedIds.subtract(fresh)
            }
        }
    }

    private func startWatching() {
        let url = URL(fileURLWithPath: filePath)
        let directory = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        watchTask = Task { [weak self] in
            // Watch the folder, not the file: editors and agents often save by
            // replacing the file, which a file-level watch would lose.
            let canonical = await Task.detached { () -> String in
                guard let resolved = realpath(directory, nil) else { return directory }
                defer { free(resolved) }
                return String(cString: resolved)
            }.value
            guard let watcher = await RecursivePathWatcher(
                paths: [canonical],
                throttleInterval: .milliseconds(120),
                eventFilter: { change in
                    change.requiresFullRescan || change.paths.contains { ($0 as NSString).lastPathComponent == name }
                }
            ) else { return }
            for await _ in watcher.pathEvents {
                guard let self, !Task.isCancelled else { break }
                self.refresh()
            }
            await watcher.stop()
        }
    }

    // MARK: - Off-main readers

    nonisolated private static func baselineLines(of path: String, source: Source) -> [String] {
        switch source {
        case .workingTree:
            return committedLines(of: path)
        case .commit(let root, _, let parentSHA, let commitPath, let oldPath):
            guard let parentSHA else { return [] }
            let text = GitHistoryService().fileContents(
                repositoryRoot: root, revision: parentSHA, path: oldPath ?? commitPath
            )
            return text.map(LiveDiffRows.lines(of:)) ?? []
        }
    }

    nonisolated private static func currentLines(of path: String, source: Source) -> [String]? {
        if case .commit(let root, let sha, _, let commitPath, _) = source {
            let text = GitHistoryService().fileContents(repositoryRoot: root, revision: sha, path: commitPath)
            return text.map(LiveDiffRows.lines(of:)) ?? []
        }
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.prefix(8_000).contains(0) { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return LiveDiffRows.lines(of: text)
    }

    /// The file as of the last commit, or nothing for a new/untracked file.
    nonisolated private static func committedLines(of path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["show", "HEAD:./" + url.lastPathComponent]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.prefix(8_000).contains(0) else { return [] }
            return LiveDiffRows.lines(of: String(decoding: data, as: UTF8.self))
        } catch {
            return []
        }
    }
}
