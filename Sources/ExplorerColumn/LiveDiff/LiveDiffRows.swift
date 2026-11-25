import Foundation

/// One line of a live diff: a line kept from the baseline, added by the agent,
/// or removed by it. `id` stays stable across updates for lines that did not
/// change, so only real changes animate.
struct LiveDiffRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unchanged
        case added
        case removed
    }

    let id: Int
    let text: String
    let kind: Kind
    /// Line number in the baseline (unchanged and removed rows).
    let oldNumber: Int?
    /// Line number in the current file (unchanged and added rows).
    let newNumber: Int?
}

/// Pure line-diff helpers for the follow-agent live diff.
enum LiveDiffRows {
    /// Beyond this many lines a side, diffing is skipped to keep updates cheap.
    static let maximumLines = 20_000

    struct Update: Equatable, Sendable {
        var rows: [LiveDiffRow]
        /// Rows that are new since the previous update, in document order.
        var freshIds: [Int]
        var nextId: Int
    }

    static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// The merged baseline → current listing, removals before additions in each hunk.
    static func merged(baseline: [String], current: [String]) -> [(text: String, kind: LiveDiffRow.Kind, old: Int?, new: Int?)] {
        let difference = current.difference(from: baseline)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [(text: String, kind: LiveDiffRow.Kind, old: Int?, new: Int?)] = []
        result.reserveCapacity(baseline.count + inserted.count)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < baseline.count || newIndex < current.count {
            if oldIndex < baseline.count, removed.contains(oldIndex) {
                result.append((baseline[oldIndex], .removed, oldIndex + 1, nil))
                oldIndex += 1
            } else if newIndex < current.count, inserted.contains(newIndex) {
                result.append((current[newIndex], .added, nil, newIndex + 1))
                newIndex += 1
            } else if oldIndex < baseline.count, newIndex < current.count {
                result.append((current[newIndex], .unchanged, oldIndex + 1, newIndex + 1))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return result
    }

    /// Builds the next set of rows, reusing the ids of rows that are unchanged
    /// since `previous` so the view animates only what the latest edit changed.
    static func update(previous: [LiveDiffRow], nextId: Int, baseline: [String], current: [String]) -> Update {
        let merged = merged(baseline: baseline, current: current)
        let oldKeys = previous.map { key($0.kind, $0.text) }
        let newKeys = merged.map { key($0.kind, $0.text) }
        var insertedOffsets = Set<Int>()
        var removedOffsets = Set<Int>()
        for change in newKeys.difference(from: oldKeys) {
            switch change {
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            }
        }
        var rows: [LiveDiffRow] = []
        rows.reserveCapacity(merged.count)
        var freshIds: [Int] = []
        var id = nextId
        var oldIndex = 0
        for (newIndex, entry) in merged.enumerated() {
            let rowId: Int
            if insertedOffsets.contains(newIndex) {
                rowId = id
                id += 1
                freshIds.append(rowId)
            } else {
                while removedOffsets.contains(oldIndex) { oldIndex += 1 }
                rowId = previous[oldIndex].id
                oldIndex += 1
            }
            rows.append(LiveDiffRow(id: rowId, text: entry.text, kind: entry.kind, oldNumber: entry.old, newNumber: entry.new))
        }
        return Update(rows: rows, freshIds: freshIds, nextId: id)
    }

    private static func key(_ kind: LiveDiffRow.Kind, _ text: String) -> String {
        switch kind {
        case .unchanged: " " + text
        case .added: "+" + text
        case .removed: "-" + text
        }
    }
}
