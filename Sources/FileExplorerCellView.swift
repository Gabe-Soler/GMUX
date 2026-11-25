import AppKit
import CmuxAppKitSupportUI
import UniformTypeIdentifiers

final class FileExplorerCellView: NSTableCellView {
    private let iconView = CmuxResolvedIconImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    /// GMUX: marks files (and folders containing files) an agent edited recently.
    private let agentDot = NSView()
    private var trackingArea: NSTrackingArea?
    var onHover: ((Bool) -> Void)?
    private var nameLabelTrailingToLoadingConstraint: NSLayoutConstraint!
    private var nameLabelTrailingToContainerConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var iconToTextConstraint: NSLayoutConstraint!
    private var loadingWidthConstraint: NSLayoutConstraint!

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        loadingIndicator.setAccessibilityIdentifier("FileExplorerLoadingIndicator")

        agentDot.translatesAutoresizingMaskIntoConstraints = false
        agentDot.wantsLayer = true
        agentDot.layer?.cornerRadius = 3.5
        agentDot.layer?.borderWidth = 1
        agentDot.isHidden = true

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(loadingIndicator)
        addSubview(agentDot)
        // A badge on the icon's corner, like a Finder tag: always visible,
        // whatever the column width, and it never takes space from the name.
        NSLayoutConstraint.activate([
            agentDot.widthAnchor.constraint(equalToConstant: 7),
            agentDot.heightAnchor.constraint(equalToConstant: 7),
            agentDot.centerXAnchor.constraint(equalTo: iconView.trailingAnchor, constant: -1),
            agentDot.centerYAnchor.constraint(equalTo: iconView.bottomAnchor, constant: -1),
        ])

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 16)
        iconToTextConstraint = nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4)
        loadingWidthConstraint = loadingIndicator.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            iconToTextConstraint,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingWidthConstraint,
            loadingIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])

        nameLabelTrailingToLoadingConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: loadingIndicator.leadingAnchor,
            constant: -2
        )
        nameLabelTrailingToContainerConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -2
        )
        NSLayoutConstraint.activate([
            nameLabelTrailingToLoadingConstraint,
            nameLabelTrailingToContainerConstraint
        ])
        nameLabelTrailingToLoadingConstraint.isActive = false
    }

    func configure(with node: FileExplorerNode, gitStatus: GitFileStatus? = nil) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        let style = FileExplorerStyle.current
        nameLabel.stringValue = node.name
        nameLabel.font = style.nameFont
        iconWidthConstraint.constant = style.iconSize
        iconHeightConstraint.constant = style.iconSize
        iconToTextConstraint.constant = style.iconToTextSpacing

        if style == .finder {
            // Native Finder icon pixels miss 3:1 in light mode; use their masks with the dynamic palette tint.
            if node.isDirectory {
                iconView.apply(CmuxResolvedIconRequest(
                    source: .image(NSWorkspace.shared.icon(for: .folder)),
                    size: NSSize(width: style.iconSize, height: style.iconSize),
                    tintColor: style.folderIconTint
                ))
            } else {
                let pathExtension = (node.name as NSString).pathExtension
                iconView.apply(CmuxResolvedIconRequest(
                    source: .image(NSWorkspace.shared.icon(for: UTType(filenameExtension: pathExtension) ?? .data)),
                    size: NSSize(width: style.iconSize, height: style.iconSize),
                    tintColor: style.fileIconTint
                ))
            }
        } else {
            if node.isDirectory {
                iconView.apply(CmuxResolvedIconRequest(
                    source: .systemSymbol(name: "folder.fill", accessibilityDescription: nil),
                    size: NSSize(width: style.iconSize, height: style.iconSize),
                    tintColor: style.folderIconTint,
                    symbolWeight: style.iconWeight
                ))
            } else {
                iconView.apply(CmuxResolvedIconRequest(
                    source: .systemSymbol(name: "doc", accessibilityDescription: nil),
                    size: NSSize(width: style.iconSize, height: style.iconSize),
                    tintColor: style.fileIconTint,
                    symbolWeight: style.iconWeight
                ))
            }
        }

        if node.isLoading {
            loadingWidthConstraint.constant = 12
            loadingIndicator.isHidden = false
            loadingIndicator.startAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = true
            nameLabelTrailingToContainerConstraint.isActive = false
        } else {
            loadingWidthConstraint.constant = 0
            loadingIndicator.isHidden = true
            loadingIndicator.stopAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = false
            nameLabelTrailingToContainerConstraint.isActive = true
        }

        // Ignored files and folders are dimmed, icon included, as in VS Code.
        iconView.alphaValue = gitStatus == .ignored ? 0.5 : 1

        if let error = node.error {
            nameLabel.textColor = .systemRed
            nameLabel.toolTip = error
        } else if let gitStatus {
            nameLabel.textColor = style.gitColor(for: gitStatus)
            nameLabel.toolTip = node.path
        } else {
            nameLabel.textColor = .labelColor
            nameLabel.toolTip = node.path
        }
    }

    /// Shows the agent-activity dot: full strength for a couple of minutes, then faded.
    func setAgentTouch(_ touch: AgentFileActivity.Touch?, isDirectory: Bool, now: Date) {
        guard let touch else {
            agentDot.isHidden = true
            return
        }
        agentDot.isHidden = false
        let fresh = now.timeIntervalSince(touch.lastAt) < AgentFileActivity.freshInterval
        agentDot.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(fresh ? 1 : 0.5).cgColor
        // A ring in the row background keeps the badge legible over the icon.
        agentDot.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        let relative = RelativeDateTimeFormatter().localizedString(for: touch.lastAt, relativeTo: now)
        if isDirectory {
            agentDot.toolTip = String(
                localized: "fileExplorer.agentTouch.folderTooltip",
                defaultValue: "Contains files an agent edited"
            )
        } else {
            agentDot.toolTip = String(
                format: String(localized: "fileExplorer.agentTouch.fileTooltip", defaultValue: "Edited by %1$@ %2$@"),
                touch.agent, relative
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}
