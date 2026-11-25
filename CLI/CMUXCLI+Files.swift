import Foundation

/// `cmux files …`: drive the GMUX Explorer column (the VS Code-style file tree).
extension CMUXCLI {
    func runFilesCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "state"
        var rest = Array(commandArgs.dropFirst())
        var params: [String: Any] = [:]
        // Route to the caller's window; the app ignores requests for a
        // workspace the person is not looking at instead of switching to it.
        if let workspace = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"], !workspace.isEmpty {
            params["workspace_id"] = workspace
        }

        let method: String
        switch subcommand {
        case "show", "hide", "toggle", "state":
            method = "files.\(subcommand)"
        case "follow":
            if let value = rest.first?.lowercased() {
                guard value == "on" || value == "off" else {
                    throw CLIError(message: "files follow: expected 'on' or 'off'")
                }
                params["enabled"] = value == "on"
                rest.removeFirst()
            }
            method = "files.follow"
        case "tree":
            let (depth, afterDepth) = parseOption(rest, name: "--depth")
            let (maxEntries, afterMax) = parseOption(afterDepth, name: "--max")
            rest = afterMax
            if let depth {
                guard let value = Int(depth), value > 0 else {
                    throw CLIError(message: "files tree: --depth must be a positive number")
                }
                params["depth"] = value
            }
            if let maxEntries {
                guard let value = Int(maxEntries), value > 0 else {
                    throw CLIError(message: "files tree: --max must be a positive number")
                }
                params["max_entries"] = value
            }
            method = "files.tree"
        case "reveal", "open":
            let pin = hasFlag(rest, name: "--pin")
            let select = hasFlag(rest, name: "--select")
            let noReveal = hasFlag(rest, name: "--no-reveal")
            rest.removeAll { $0 == "--pin" || $0 == "--select" || $0 == "--no-reveal" }
            guard let rawPath = rest.first, !rawPath.hasPrefix("-") else {
                throw CLIError(message: "files \(subcommand) requires a path. Usage: cmux files \(subcommand) <path>")
            }
            rest.removeFirst()
            params["path"] = resolvePath(rawPath)
            if subcommand == "open" {
                params["pin"] = pin
                params["select"] = select
                if noReveal { params["reveal"] = false }
            }
            method = "files.\(subcommand)"
        case "help", "--help", "-h":
            print(Self.filesUsage())
            return
        default:
            throw CLIError(message: "Unknown files subcommand: \(subcommand)\n\n\(Self.filesUsage())")
        }
        if let unexpected = rest.first {
            throw CLIError(message: "files \(subcommand): unexpected argument '\(unexpected)'")
        }

        let payload = try client.sendV2(method: method, params: params)
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        if payload["applied"] as? Bool == false {
            print("SKIPPED (\(payload["reason"] as? String ?? "not applied"))")
            return
        }
        switch method {
        case "files.tree":
            print(Self.renderFilesTree(payload))
        case "files.state":
            print(jsonString(payload))
        case "files.show", "files.hide", "files.toggle":
            print((payload["visible"] as? Bool ?? false) ? "OK visible" : "OK hidden")
        case "files.follow":
            print((payload["follow"] as? Bool ?? false) ? "OK follow on" : "OK follow off")
        default:
            print("OK \(payload["path"] as? String ?? "")")
        }
    }

    /// Indented tree with git markers: M modified, A added, D deleted,
    /// R renamed, ? untracked, ! ignored.
    static func renderFilesTree(_ payload: [String: Any]) -> String {
        var lines = [payload["root"] as? String ?? ""]
        for entry in payload["entries"] as? [[String: Any]] ?? [] {
            let depth = entry["depth"] as? Int ?? 0
            let isDirectory = entry["type"] as? String == "directory"
            let marker: String
            switch entry["git"] as? String {
            case "modified": marker = "M"
            case "added": marker = "A"
            case "deleted": marker = "D"
            case "renamed": marker = "R"
            case "untracked": marker = "?"
            case "ignored": marker = "!"
            default: marker = " "
            }
            let name = (entry["name"] as? String ?? "") + (isDirectory ? "/" : "")
            lines.append("\(marker) " + String(repeating: "  ", count: depth) + name)
        }
        if payload["truncated"] as? Bool == true {
            lines.append("… (truncated; pass --max to see more)")
        }
        return lines.joined(separator: "\n")
    }

    static func filesUsage() -> String {
        String(
            localized: "cli.files.help",
            defaultValue: """
        Usage: cmux files <state|tree|reveal|open|follow|show|hide|toggle> [args]

        Drive the Explorer column: the file tree beside the workspace tabs.
        Paths may be absolute or relative to the current directory. Commands
        only act on the workspace the person is viewing and never move focus.

          cmux files tree [--depth N] [--max N]   Print the tree as shown (expanded folders only)
          cmux files reveal <path>                 Expand to, select and scroll to a file
          cmux files open <path> [--pin] [--select] Open in the preview tab (or pinned) and reveal
          cmux files state                         Root, selection, expanded folders, preview tab
          cmux files show | hide | toggle          Show or hide the Explorer column
          cmux files follow [on|off]               Open each file an agent edits beside its terminal

        Tree markers: M modified, A added, D deleted, R renamed, ? untracked, ! ignored.
        """
        )
    }
}
