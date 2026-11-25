enum GitFileStatus: Equatable {
    case modified, added, deleted, renamed, untracked
    /// Matched by .gitignore; drawn dimmed, like VS Code.
    case ignored
}
