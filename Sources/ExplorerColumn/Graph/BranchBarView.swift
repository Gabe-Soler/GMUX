import AppKit
import CmuxGit
import SwiftUI

/// The current branch at the top of the Explorer, VS Code status-bar style.
/// Clicking it opens the branch picker.
struct BranchBarView: View {
    @ObservedObject var model: CommitGraphModel
    /// Whether tracked or untracked files differ from HEAD, from the Explorer's git status.
    let hasLocalChanges: Bool

    @State private var isPickerShown = false

    static let height: CGFloat = 24

    var body: some View {
        if model.availability == .ready, let status = model.branchStatus {
            Button {
                isPickerShown = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                    Text(verbatim: title(for: status))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if hasLocalChanges || status.hasTrackedChanges {
                        Circle()
                            .fill(Color(nsColor: .systemOrange))
                            .frame(width: 6, height: 6)
                            .help(String(localized: "explorerColumn.branch.uncommitted", defaultValue: "Uncommitted changes"))
                    }
                    Spacer(minLength: 0)
                    if status.upstream != nil {
                        syncCounts(status)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: Self.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "explorerColumn.branch.tooltip", defaultValue: "Current branch. Click to switch branches."))
            .popover(isPresented: $isPickerShown, arrowEdge: .bottom) {
                BranchPickerView(model: model, currentBranch: status.branch) {
                    isPickerShown = false
                }
            }
        }
    }

    private func title(for status: GitBranchStatus) -> String {
        if let branch = status.branch { return branch }
        if let sha = status.headSHA {
            return String(
                format: String(localized: "explorerColumn.branch.detached", defaultValue: "Detached at %@"),
                String(sha.prefix(7))
            )
        }
        return String(localized: "explorerColumn.branch.noCommits", defaultValue: "No commits")
    }

    private func syncCounts(_ status: GitBranchStatus) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "↑\(status.ahead)")
                .foregroundStyle(status.ahead > 0 ? Color.primary : Color.secondary)
            Text(verbatim: "↓\(status.behind)")
                .foregroundStyle(status.behind > 0 ? Color.primary : Color.secondary)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .help(String(
            format: String(localized: "explorerColumn.branch.syncTooltip", defaultValue: "Commits to push ↑ and pull ↓ against %@"),
            status.upstream ?? ""
        ))
    }
}

/// Searchable list of local and remote branches; picking one checks it out.
struct BranchPickerView: View {
    @ObservedObject var model: CommitGraphModel
    let currentBranch: String?
    let onDone: () -> Void

    @State private var query = ""
    @State private var branches: [GitBranchRef] = []
    @State private var switchingTo: GitBranchRef?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                String(localized: "explorerColumn.branch.picker.search", defaultValue: "Switch to branch…"),
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { if let first = filtered.first { pick(first) } }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section(
                        String(localized: "explorerColumn.branch.picker.local", defaultValue: "Branches"),
                        filtered.filter { !$0.isRemote }
                    )
                    section(
                        String(localized: "explorerColumn.branch.picker.remote", defaultValue: "Remote branches"),
                        filtered.filter(\.isRemote)
                    )
                }
            }
            .frame(height: 260)
        }
        .padding(10)
        .frame(width: 300)
        .task { branches = await model.branches() }
    }

    private var filtered: [GitBranchRef] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [GitBranchRef]) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(items) { branch in
                Button {
                    pick(branch)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(verbatim: branch.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if switchingTo == branch {
                            ProgressView().controlSize(.mini)
                        } else if !branch.isRemote && branch.name == currentBranch {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(switchingTo != nil)
            }
        }
    }

    private func pick(_ branch: GitBranchRef) {
        guard switchingTo == nil else { return }
        if !branch.isRemote && branch.name == currentBranch {
            onDone()
            return
        }
        switchingTo = branch
        errorMessage = nil
        Task {
            let failure = await model.switchBranch(to: branch)
            switchingTo = nil
            if let failure {
                errorMessage = failure
            } else {
                onDone()
            }
        }
    }
}
