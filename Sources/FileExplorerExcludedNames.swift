/// Names the file tree never lists, matching VS Code's default `files.exclude`.
/// They are still reachable from the terminal and from search.
enum FileExplorerExcludedNames {
    static let names: Set<String> = [".git", ".DS_Store", ".hg", ".svn", "CVS", "Thumbs.db"]

    static func contains(_ name: String) -> Bool {
        names.contains(name)
    }
}
