import Foundation

/// A line drawn in one half of a graph row, between two lane positions.
///
/// In the top half a segment runs from `from` at the row's top edge to `to`
/// at its vertical middle; in the bottom half, from `from` at the middle to
/// `to` at the bottom edge.
public struct CommitGraphSegment: Sendable, Hashable {
    public let from: Int
    public let to: Int
    public let colorIndex: Int

    public init(from: Int, to: Int, colorIndex: Int) {
        self.from = from
        self.to = to
        self.colorIndex = colorIndex
    }
}

/// One drawn row of the commit graph.
public struct CommitGraphRow: Sendable, Hashable, Identifiable {
    public var id: String { commit.sha }

    public let commit: GitCommit
    /// The lane the commit's dot sits in.
    public let lane: Int
    public let colorIndex: Int
    public let top: [CommitGraphSegment]
    public let bottom: [CommitGraphSegment]
    /// Lanes this row needs horizontally.
    public let laneCount: Int

    public init(
        commit: GitCommit,
        lane: Int,
        colorIndex: Int,
        top: [CommitGraphSegment],
        bottom: [CommitGraphSegment],
        laneCount: Int
    ) {
        self.commit = commit
        self.lane = lane
        self.colorIndex = colorIndex
        self.top = top
        self.bottom = bottom
        self.laneCount = laneCount
    }
}

/// Assigns commits to lanes, VS Code Source Control Graph style.
///
/// Feed commits in topological order (children before parents). The layout
/// keeps its open lanes between calls, so later pages continue the lines of
/// earlier ones.
public struct CommitGraphLayout: Sendable {
    public static let colorCount = 8

    private struct Lane: Sendable {
        /// The commit this lane is waiting for.
        var sha: String
        var colorIndex: Int
    }

    private var lanes: [Lane] = []
    private var nextColorIndex = 0

    public init() {}

    public mutating func append(_ commits: [GitCommit]) -> [CommitGraphRow] {
        commits.map { place($0) }
    }

    private mutating func takeColor() -> Int {
        defer { nextColorIndex = (nextColorIndex + 1) % Self.colorCount }
        return nextColorIndex
    }

    private mutating func place(_ commit: GitCommit) -> CommitGraphRow {
        // Lanes that were waiting for this commit converge on its dot.
        var matching = lanes.indices.filter { lanes[$0].sha == commit.sha }
        let opensNewLane = matching.isEmpty
        if opensNewLane {
            // A branch tip nothing above points at: open a new lane.
            lanes.append(Lane(sha: commit.sha, colorIndex: takeColor()))
            matching = [lanes.count - 1]
        }
        let lane = matching[0]
        let colorIndex = lanes[lane].colorIndex
        let incoming = Set(matching)

        var top: [CommitGraphSegment] = []
        for (index, open) in lanes.enumerated() where !(opensNewLane && index == lane) {
            let target = incoming.contains(index) ? lane : index
            top.append(CommitGraphSegment(from: index, to: target, colorIndex: open.colorIndex))
        }

        // Rebuild the open lanes below this commit, remembering where each came from.
        // `origin` is the lane position in this row each continuing line starts from.
        var below: [(lane: Lane, origin: Int)] = []
        for (index, open) in lanes.enumerated() {
            if index == lane {
                if let firstParent = commit.parents.first {
                    below.append((Lane(sha: firstParent, colorIndex: colorIndex), lane))
                }
            } else if !incoming.contains(index) {
                below.append((open, index))
            }
        }
        for parent in commit.parents.dropFirst() {
            // A parent that already has a lane is drawn into it (deduplicated
            // below); otherwise the merged branch gets a lane of its own.
            let existing = below.first { $0.lane.sha == parent }?.lane.colorIndex
            below.append((Lane(sha: parent, colorIndex: existing ?? takeColor()), lane))
        }
        // Two lines waiting for the same parent share one lane from here on.
        var seen: [String: Int] = [:]
        var merged: [(lane: Lane, origins: [Int])] = []
        for entry in below {
            if let existing = seen[entry.lane.sha] {
                merged[existing].origins.append(entry.origin)
            } else {
                seen[entry.lane.sha] = merged.count
                merged.append((entry.lane, [entry.origin]))
            }
        }

        var bottom: [CommitGraphSegment] = []
        for (newIndex, entry) in merged.enumerated() {
            for origin in entry.origins {
                // Lines keep the colour of the lane they run into.
                bottom.append(CommitGraphSegment(from: origin, to: newIndex, colorIndex: entry.lane.colorIndex))
            }
        }

        let laneCount = max(lanes.count, merged.count)
        lanes = merged.map(\.lane)
        return CommitGraphRow(
            commit: commit,
            lane: lane,
            colorIndex: colorIndex,
            top: top,
            bottom: bottom,
            laneCount: laneCount
        )
    }
}
