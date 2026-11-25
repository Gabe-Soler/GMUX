public import Foundation

/// A ref decorating a commit in the history graph.
public struct GitRefLabel: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The checked-out branch (`HEAD -> name`), or `HEAD` itself when detached.
        case head
        case localBranch
        case remoteBranch
        case tag
    }

    public let kind: Kind
    /// Short display name: `main`, `origin/main`, `v1.0`, or `HEAD`.
    public let name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// One commit as listed by the history graph.
public struct GitCommit: Sendable, Hashable, Identifiable {
    public var id: String { sha }

    public let sha: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let date: Date
    public let subject: String
    public let refs: [GitRefLabel]

    public init(
        sha: String,
        parents: [String],
        authorName: String,
        authorEmail: String,
        date: Date,
        subject: String,
        refs: [GitRefLabel]
    ) {
        self.sha = sha
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.subject = subject
        self.refs = refs
    }

    public var shortSHA: String { String(sha.prefix(7)) }
}

/// One file a commit changed, relative to its first parent.
public struct GitCommitFileChange: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        case added
        case modified
        case deleted
        case renamed
        case copied
        case typeChanged
        case other

        /// The single-letter code git prints (`A`, `M`, `D`, ...).
        public var letter: String {
            switch self {
            case .added: "A"
            case .modified: "M"
            case .deleted: "D"
            case .renamed: "R"
            case .copied: "C"
            case .typeChanged: "T"
            case .other: "?"
            }
        }
    }

    public var id: String { path }

    public let status: Status
    /// Repository-relative path after the change.
    public let path: String
    /// Repository-relative path before a rename or copy.
    public let oldPath: String?

    public init(status: Status, path: String, oldPath: String? = nil) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
    }
}

/// The checked-out branch and how it relates to its upstream.
public struct GitBranchStatus: Sendable, Hashable {
    /// The branch name, or `nil` when HEAD is detached or the repo has no commits.
    public let branch: String?
    /// The HEAD commit, or `nil` for a repository without commits.
    public let headSHA: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    /// Tracked files differ from HEAD (untracked files are not counted).
    public let hasTrackedChanges: Bool

    public init(
        branch: String?,
        headSHA: String?,
        upstream: String?,
        ahead: Int,
        behind: Int,
        hasTrackedChanges: Bool
    ) {
        self.branch = branch
        self.headSHA = headSHA
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.hasTrackedChanges = hasTrackedChanges
    }

    public var isDetached: Bool { branch == nil && headSHA != nil }
}

/// A branch the user can switch to.
public struct GitBranchRef: Sendable, Hashable, Identifiable {
    public var id: String { fullName }

    /// `refs/heads/main` or `refs/remotes/origin/main`.
    public let fullName: String
    /// `main` or `origin/main`.
    public let name: String
    public let isRemote: Bool
    public let lastCommitDate: Date?

    public init(fullName: String, name: String, isRemote: Bool, lastCommitDate: Date?) {
        self.fullName = fullName
        self.name = name
        self.isRemote = isRemote
        self.lastCommitDate = lastCommitDate
    }

    /// For a remote branch, the local branch name it would track (`origin/foo` → `foo`).
    public var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}
