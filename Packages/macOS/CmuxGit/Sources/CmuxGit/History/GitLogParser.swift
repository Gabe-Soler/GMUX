import Foundation

/// Parses the plumbing output the history graph asks git for.
enum GitLogParser {
    /// The `--format` passed to `git log`: NUL-separated fields, records
    /// terminated by the ASCII record separator.
    static let logFormat = "%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s%x1e"

    /// Parses `git log --decorate=full --format=<logFormat>` output.
    static func commits(from data: Data) -> [GitCommit] {
        let text = String(decoding: data, as: UTF8.self)
        var commits: [GitCommit] = []
        for rawRecord in text.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
            let record = rawRecord.drop(while: { $0 == "\n" || $0 == "\r" })
            let fields = record.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count >= 7 else { continue }
            let sha = String(fields[0])
            guard !sha.isEmpty else { continue }
            let parents = fields[1].split(separator: " ").map(String.init)
            let timestamp = TimeInterval(fields[4]) ?? 0
            commits.append(GitCommit(
                sha: sha,
                parents: parents,
                authorName: String(fields[2]),
                authorEmail: String(fields[3]),
                date: Date(timeIntervalSince1970: timestamp),
                subject: fields[6...].joined(separator: " "),
                refs: refLabels(fromDecoration: String(fields[5]))
            ))
        }
        return commits
    }

    /// Parses a full-name `%D` decoration such as
    /// `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1`.
    static func refLabels(fromDecoration decoration: String) -> [GitRefLabel] {
        var labels: [GitRefLabel] = []
        for rawPart in decoration.components(separatedBy: ", ") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            if part == "HEAD" {
                labels.append(GitRefLabel(kind: .head, name: "HEAD"))
            } else if part.hasPrefix("HEAD -> ") {
                let ref = String(part.dropFirst("HEAD -> ".count))
                labels.append(GitRefLabel(kind: .head, name: shortName(ref)))
            } else if part.hasPrefix("tag: ") {
                labels.append(GitRefLabel(kind: .tag, name: shortName(String(part.dropFirst("tag: ".count)))))
            } else if part.hasPrefix("refs/heads/") {
                labels.append(GitRefLabel(kind: .localBranch, name: shortName(part)))
            } else if part.hasPrefix("refs/remotes/") {
                // `origin/HEAD` only points at another remote branch; VS Code hides it too.
                guard !part.hasSuffix("/HEAD") else { continue }
                labels.append(GitRefLabel(kind: .remoteBranch, name: shortName(part)))
            }
            // refs/stash, notes and other namespaces are not shown.
        }
        return labels
    }

    static func shortName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// Parses `git diff-tree -r -M -z --name-status --no-commit-id` output.
    static func fileChanges(from data: Data) -> [GitCommitFileChange] {
        let fields = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        var changes: [GitCommitFileChange] = []
        var index = 0
        while index < fields.count {
            let code = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            guard let letter = code.first else { continue }
            let status = status(for: letter)
            if status == .renamed || status == .copied {
                guard index + 1 < fields.count else { break }
                changes.append(GitCommitFileChange(status: status, path: fields[index + 1], oldPath: fields[index]))
                index += 2
            } else {
                guard index < fields.count else { break }
                changes.append(GitCommitFileChange(status: status, path: fields[index]))
                index += 1
            }
        }
        return changes
    }

    private static func status(for letter: Character) -> GitCommitFileChange.Status {
        switch letter {
        case "A": .added
        case "M": .modified
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        default: .other
        }
    }

    /// Parses `git status --porcelain=v2 --branch -z` output.
    static func branchStatus(from data: Data) -> GitBranchStatus {
        var branch: String?
        var headSHA: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var hasTrackedChanges = false
        for entry in String(decoding: data, as: UTF8.self).split(separator: "\0") {
            if entry.hasPrefix("# branch.oid ") {
                let value = String(entry.dropFirst("# branch.oid ".count))
                headSHA = value == "(initial)" ? nil : value
            } else if entry.hasPrefix("# branch.head ") {
                let value = String(entry.dropFirst("# branch.head ".count))
                branch = value == "(detached)" ? nil : value
            } else if entry.hasPrefix("# branch.upstream ") {
                upstream = String(entry.dropFirst("# branch.upstream ".count))
            } else if entry.hasPrefix("# branch.ab ") {
                for token in entry.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if token.hasPrefix("+") { ahead = Int(token.dropFirst()) ?? 0 }
                    if token.hasPrefix("-") { behind = Int(token.dropFirst()) ?? 0 }
                }
            } else if entry.hasPrefix("1 ") || entry.hasPrefix("2 ") || entry.hasPrefix("u ") {
                hasTrackedChanges = true
            }
        }
        return GitBranchStatus(
            branch: branch,
            headSHA: headSHA,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            hasTrackedChanges: hasTrackedChanges
        )
    }

    /// Parses `git for-each-ref --format=%(refname)%00%(committerdate:unix)` lines.
    static func branches(from data: Data) -> [GitBranchRef] {
        var branches: [GitBranchRef] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard let refField = fields.first else { continue }
            let fullName = String(refField)
            let isRemote = fullName.hasPrefix("refs/remotes/")
            guard isRemote || fullName.hasPrefix("refs/heads/") else { continue }
            guard !(isRemote && fullName.hasSuffix("/HEAD")) else { continue }
            let date = fields.count > 1 ? TimeInterval(fields[1]).map { Date(timeIntervalSince1970: $0) } : nil
            branches.append(GitBranchRef(
                fullName: fullName,
                name: shortName(fullName),
                isRemote: isRemote,
                lastCommitDate: date
            ))
        }
        return branches
    }
}
