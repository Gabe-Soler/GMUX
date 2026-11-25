import Foundation

/// Files that coding agents edited recently, per workspace, so the Explorer can
/// mark them (and the folders containing them) while you watch an agent work.
///
/// A pure value: the caller supplies the time, which keeps it testable.
struct AgentFileActivity {
    struct Touch: Equatable {
        var lastAt: Date
        var agent: String
    }

    /// How long a mark stays visible.
    static let lifetime: TimeInterval = 15 * 60
    /// Marks younger than this draw at full strength.
    static let freshInterval: TimeInterval = 2 * 60
    /// Bound on remembered files per workspace; the oldest are dropped first.
    static let maximumFilesPerWorkspace = 512

    private var filesByWorkspace: [UUID: [String: Touch]] = [:]
    private var foldersByWorkspace: [UUID: [String: Date]] = [:]

    mutating func record(paths: [String], agent: String, workspaceId: UUID, at now: Date) {
        guard !paths.isEmpty else { return }
        var files = filesByWorkspace[workspaceId] ?? [:]
        for path in paths {
            files[path] = Touch(lastAt: now, agent: agent)
        }
        files = files.filter { now.timeIntervalSince($0.value.lastAt) < Self.lifetime }
        if files.count > Self.maximumFilesPerWorkspace {
            let keep = files.sorted { $0.value.lastAt > $1.value.lastAt }.prefix(Self.maximumFilesPerWorkspace)
            files = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        filesByWorkspace[workspaceId] = files
        // Rebuild the folder rollup from the surviving files so expiry stays consistent.
        var folders: [String: Date] = [:]
        for (path, touch) in files {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.count > 1 {
                if (folders[folder] ?? .distantPast) < touch.lastAt { folders[folder] = touch.lastAt }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        foldersByWorkspace[workspaceId] = folders
    }

    /// The touch for a file, or the newest touch inside a folder, if still live.
    func touch(for path: String, isDirectory: Bool, workspaceId: UUID, now: Date) -> Touch? {
        if isDirectory {
            guard let at = foldersByWorkspace[workspaceId]?[path],
                  now.timeIntervalSince(at) < Self.lifetime else { return nil }
            return Touch(lastAt: at, agent: "")
        }
        guard let touch = filesByWorkspace[workspaceId]?[path],
              now.timeIntervalSince(touch.lastAt) < Self.lifetime else { return nil }
        return touch
    }

    /// Recently touched files for `cmux files state`, newest first.
    func recentFiles(workspaceId: UUID, now: Date) -> [(path: String, touch: Touch)] {
        (filesByWorkspace[workspaceId] ?? [:])
            .filter { now.timeIntervalSince($0.value.lastAt) < Self.lifetime }
            .sorted { $0.value.lastAt > $1.value.lastAt }
            .map { (path: $0.key, touch: $0.value) }
    }
}

/// Turns an agent hook's tool call into the file paths it edits.
///
/// Only editing tools count: reads, searches and shell commands never mark files.
enum AgentToolFileTouchExtractor {
    static func editedPaths(toolName: String?, toolInputJSON: String?, cwd: String?) -> [String] {
        guard let toolName, let toolInputJSON, !toolInputJSON.isEmpty else { return [] }
        let name = toolName.lowercased()
        let isPatch = name == "apply_patch" || name.hasSuffix("apply_patch")
        let isEdit = ["edit", "multiedit", "write", "notebookedit", "str_replace_based_edit_tool",
                      "create", "str_replace", "write_file", "edit_file"].contains(name)
        guard isPatch || isEdit,
              let data = toolInputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }

        var raw: [String] = []
        if let input = object as? [String: Any] {
            for key in ["file_path", "notebook_path", "path", "filePath"] {
                if let value = input[key] as? String, !value.isEmpty { raw.append(value) }
            }
        }
        if isPatch || raw.isEmpty {
            raw.append(contentsOf: patchPaths(in: object))
        }
        var seen = Set<String>()
        return raw.compactMap { resolve($0, cwd: cwd) }.filter { seen.insert($0).inserted }
    }

    /// `*** Add File:`, `*** Update File:`, `*** Delete File:` and `*** Move to:`
    /// headers from Codex `apply_patch` text anywhere in the input.
    private static func patchPaths(in object: Any) -> [String] {
        var strings: [String] = []
        func collect(_ value: Any) {
            if let string = value as? String {
                strings.append(string)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            } else if let dictionary = value as? [String: Any] {
                dictionary.values.forEach(collect)
            }
        }
        collect(object)
        let prefixes = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
        var paths: [String] = []
        for string in strings where string.contains("*** ") {
            for line in string.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let prefix = prefixes.first(where: { trimmed.hasPrefix($0) }) {
                    paths.append(String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return paths
    }

    private static func resolve(_ path: String, cwd: String?) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardized.path }
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: (cwd as NSString).appendingPathComponent(expanded)).standardized.path
    }
}
