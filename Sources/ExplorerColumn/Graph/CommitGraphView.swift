import AppKit
import CmuxGit
import SwiftUI

/// Lane colours, matched by `CommitGraphRow.colorIndex`.
enum CommitGraphPalette {
    static let colors: [Color] = [
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemPurple),
        Color(nsColor: .systemPink),
        Color(nsColor: .systemOrange),
        Color(nsColor: .systemGreen),
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemYellow),
        Color(nsColor: .systemRed),
    ]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// The Explorer's collapsible Graph section: VS Code's Source Control Graph.
struct CommitGraphSectionView: View {
    @ObservedObject var model: CommitGraphModel
    let isExpanded: Bool
    let onToggle: () -> Void
    let onOpenFile: (GitCommit, GitCommitFileChange) -> Void

    static let headerHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(String(localized: "explorerColumn.graph.title", defaultValue: "Graph").uppercased())
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded && model.availability == .ready {
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "explorerColumn.graph.refresh", defaultValue: "Refresh"))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: Self.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch model.availability {
        case .noFolder:
            Color.clear
        case .remote:
            emptyState(String(localized: "explorerColumn.graph.remote", defaultValue: "Graph isn't available for remote folders."))
        case .notARepository:
            emptyState(String(localized: "explorerColumn.graph.notRepository", defaultValue: "This folder isn't in a git repository."))
        case .ready:
            if model.rows.isEmpty && !model.isLoading {
                emptyState(String(localized: "explorerColumn.graph.noCommits", defaultValue: "No commits yet."))
            } else {
                rowsList
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(12)
            .frame(maxWidth: .infinity)
    }

    private var rowsList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    CommitGraphRowView(
                        row: row,
                        laneColumnCount: model.laneCount,
                        isExpanded: model.expandedSHA == row.id
                    )
                    .onTapGesture { model.toggleExpanded(row.commit) }
                    .onAppear { model.loadMoreIfNeeded(after: row) }
                    if model.expandedSHA == row.id {
                        ForEach(model.expandedFiles) { change in
                            CommitFileRowView(change: change)
                                .onTapGesture { onOpenFile(row.commit, change) }
                        }
                    }
                }
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                }
            }
        }
    }
}

/// One commit: its lanes, dot, ref labels, subject, author and age.
struct CommitGraphRowView: View {
    let row: CommitGraphRow
    /// Lanes the graph column is sized for (the widest row's).
    let laneColumnCount: Int
    let isExpanded: Bool

    static let height: CGFloat = 22
    static let laneWidth: CGFloat = 11
    static let maximumDrawnLanes = 10

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        HStack(spacing: 4) {
            CommitGraphLanes(row: row)
                .frame(width: Self.graphWidth(laneCount: laneColumnCount), height: Self.height)
            refLabels
            Text(row.commit.subject)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(verbatim: "\(row.commit.authorName) · \(Self.relativeFormatter.localizedString(for: row.commit.date, relativeTo: Date()))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .background(isExpanded ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    static func graphWidth(laneCount: Int) -> CGFloat {
        CGFloat(min(max(laneCount, 1), maximumDrawnLanes)) * laneWidth + 6
    }

    private var tooltip: String {
        let date = row.commit.date.formatted(date: .abbreviated, time: .shortened)
        return "\(row.commit.shortSHA) · \(row.commit.authorName) <\(row.commit.authorEmail)>\n\(date)\n\n\(row.commit.subject)"
    }

    @ViewBuilder
    private var refLabels: some View {
        let labels = row.commit.refs
        if !labels.isEmpty {
            HStack(spacing: 3) {
                ForEach(Array(labels.prefix(2).enumerated()), id: \.offset) { _, label in
                    CommitRefPill(label: label, color: CommitGraphPalette.color(row.colorIndex))
                }
                if labels.count > 2 {
                    Text(verbatim: "+\(labels.count - 2)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
        }
    }
}

/// A branch, tag or HEAD label next to a commit.
struct CommitRefPill: View {
    let label: GitRefLabel
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            if let icon {
                Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            }
            Text(verbatim: label.name)
                .font(.system(size: 10, weight: label.kind == .head ? .semibold : .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .frame(height: 15)
        .foregroundStyle(label.kind == .head ? Color.white : color)
        .background(
            Capsule().fill(label.kind == .head ? color : color.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(color.opacity(label.kind == .head ? 0 : 0.6), lineWidth: 1)
        )
    }

    private var icon: String? {
        switch label.kind {
        case .head: "arrow.triangle.branch"
        case .localBranch: nil
        case .remoteBranch: "cloud"
        case .tag: "tag"
        }
    }
}

/// Draws one row's lane lines and commit dot.
struct CommitGraphLanes: View {
    let row: CommitGraphRow

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let x = { (lane: Int) -> CGFloat in 7 + CGFloat(lane) * CommitGraphRowView.laneWidth }
            let maxLane = CommitGraphRowView.maximumDrawnLanes - 1
            func stroke(_ segment: CommitGraphSegment, fromY: CGFloat, toY: CGFloat) {
                guard segment.from <= maxLane, segment.to <= maxLane else { return }
                var path = Path()
                let start = CGPoint(x: x(segment.from), y: fromY)
                let end = CGPoint(x: x(segment.to), y: toY)
                path.move(to: start)
                if segment.from == segment.to {
                    path.addLine(to: end)
                } else {
                    let bend = (toY - fromY) * 0.6
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: fromY + bend),
                        control2: CGPoint(x: end.x, y: toY - bend)
                    )
                }
                context.stroke(path, with: .color(CommitGraphPalette.color(segment.colorIndex)), lineWidth: 1.6)
            }
            for segment in row.top { stroke(segment, fromY: 0, toY: mid) }
            for segment in row.bottom { stroke(segment, fromY: mid, toY: size.height) }

            guard row.lane <= maxLane else { return }
            let center = CGPoint(x: x(row.lane), y: mid)
            let color = CommitGraphPalette.color(row.colorIndex)
            let isHead = row.commit.refs.contains { $0.kind == .head }
            if isHead {
                let ring = Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
                context.fill(ring, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(ring, with: .color(color), lineWidth: 2)
            } else {
                let dot = Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
                context.fill(dot, with: .color(color))
            }
        }
    }
}

/// One file a commit changed, shown under the expanded commit.
struct CommitFileRowView: View {
    let change: GitCommitFileChange

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: change.status.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 12)
            Text(verbatim: (change.path as NSString).lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
            Text(verbatim: directoryLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
        .padding(.trailing, 6)
        .frame(height: 20)
        .contentShape(Rectangle())
        .help(change.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
    }

    private var directoryLabel: String {
        let directory = (change.path as NSString).deletingLastPathComponent
        return directory.isEmpty ? "" : directory
    }

    private var statusColor: Color {
        switch change.status {
        case .added: Color(nsColor: .systemGreen)
        case .deleted: Color(nsColor: .systemRed)
        case .renamed, .copied: Color(nsColor: .systemBlue)
        default: Color(nsColor: .systemOrange)
        }
    }
}
