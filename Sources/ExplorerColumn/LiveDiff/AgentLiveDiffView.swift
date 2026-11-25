import AppKit
import SwiftUI

/// The follow-agent live diff: the file's lines against its last commit, with
/// removed lines in red and added lines in green, animating in as edits land.
struct AgentLiveDiffView: View {
    @ObservedObject var model: AgentLiveDiffModel
    let foregroundColor: NSColor
    let backgroundColor: NSColor

    private static let addedTint = Color(nsColor: .systemGreen)
    private static let removedTint = Color(nsColor: .systemRed)

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider()
            if let notice = model.notice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rowsList
            }
        }
        .background(Color(nsColor: backgroundColor))
    }

    private var summaryBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.fill")
                .foregroundStyle(Color.accentColor)
            Text(String(
                format: String(localized: "liveDiff.summary.agent", defaultValue: "Live changes by %@"),
                model.agent
            ))
            .foregroundStyle(Color(nsColor: foregroundColor))
            Spacer(minLength: 8)
            Text(verbatim: "+\(model.addedCount)")
                .foregroundStyle(Self.addedTint)
            Text(verbatim: "−\(model.removedCount)")
                .foregroundStyle(Self.removedTint)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var rowsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        if !model.hiddenIds.contains(row.id) {
                            rowView(row)
                                .id(row.id)
                                // Fade only: sliding rows would draw over the gutter mid-flight.
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.scrollGeneration) {
                guard let target = model.scrollTarget else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private func rowView(_ row: LiveDiffRow) -> some View {
        let highlighted = model.highlightedIds.contains(row.id)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            lineNumber(row.oldNumber)
            lineNumber(row.newNumber)
            Text(verbatim: sign(row.kind))
                .frame(width: 16)
                .foregroundStyle(tint(row.kind) ?? .secondary)
            Text(verbatim: row.text.isEmpty ? " " : row.text)
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(row.kind == .removed ? 0.75 : 1))
                .strikethrough(row.kind == .removed, color: Self.removedTint.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(
            (tint(row.kind) ?? Color.clear).opacity(highlighted ? 0.38 : 0.16)
        )
        .overlay(alignment: .leading) {
            if let tint = tint(row.kind) {
                Rectangle().fill(tint).frame(width: 3)
            }
        }
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(verbatim: number.map(String.init) ?? "")
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 6)
            .font(.system(size: 10, design: .monospaced))
    }

    private func sign(_ kind: LiveDiffRow.Kind) -> String {
        switch kind {
        case .unchanged: " "
        case .added: "+"
        case .removed: "−"
        }
    }

    private func tint(_ kind: LiveDiffRow.Kind) -> Color? {
        switch kind {
        case .unchanged: nil
        case .added: Self.addedTint
        case .removed: Self.removedTint
        }
    }
}
