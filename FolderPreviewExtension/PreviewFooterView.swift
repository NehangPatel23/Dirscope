import AppKit

final class PreviewFooterView: NSView {
    static let preferredHeight: CGFloat = 52
    static let bottomInset: CGFloat = 0

    static var totalHeight: CGFloat { preferredHeight + bottomInset }

    var onViewModeChanged: ((PreviewViewMode) -> Void)?
    var onIconZoomChanged: ((Double) -> Void)?
    var onOpenRequested: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?

    private let pathIcon = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let pathGroup = NSStackView()
    private let trailingStack = NSStackView()
    private let viewModeControl = NSSegmentedControl()
    private let navUpButton = NSButton()
    private let navDownButton = NSButton()
    private let zoomOutIcon = NSImageView()
    private let zoomSlider = NSSlider()
    private let zoomInIcon = NSImageView()
    private let openButton = NSButton(title: "Open with Dirscope…", target: nil, action: nil)
    private let topSeparator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(
        pathComponents: [PathComponent],
        statusText: String,
        viewMode: PreviewViewMode,
        showPathBar: Bool,
        iconZoom: Double
    ) {
        let showPath = showPathBar && !pathComponents.isEmpty
        pathGroup.isHidden = !showPath
        pathLabel.stringValue = Self.pathTitle(from: pathComponents)
        pathLabel.toolTip = statusText

        let modeIndex = PreviewViewMode.allCases.firstIndex(of: viewMode) ?? 0
        if viewModeControl.selectedSegment != modeIndex {
            viewModeControl.selectedSegment = modeIndex
        }

        zoomSlider.doubleValue = iconZoom
    }

    func setOpenEnabled(_ enabled: Bool) {
        openButton.isHidden = !enabled
        openButton.isEnabled = enabled
    }

    func refreshAppearance() {
        PreviewTheme.refreshSurfaceBackground(on: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func setup() {
        PreviewTheme.applySurfaceBackground(to: self)

        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        pathIcon.translatesAutoresizingMaskIntoConstraints = false
        pathIcon.imageScaling = .scaleProportionallyDown
        pathIcon.contentTintColor = .secondaryLabelColor
        pathIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Path")
        pathIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        pathGroup.translatesAutoresizingMaskIntoConstraints = false
        pathGroup.orientation = .horizontal
        pathGroup.alignment = .centerY
        pathGroup.spacing = 6
        pathGroup.detachesHiddenViews = true
        pathGroup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 12
        trailingStack.detachesHiddenViews = true
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        viewModeControl.segmentCount = 2
        viewModeControl.setLabel("List", forSegment: 0)
        viewModeControl.setLabel("Icons", forSegment: 1)
        viewModeControl.segmentStyle = .rounded
        viewModeControl.trackingMode = .selectOne
        viewModeControl.controlSize = .regular
        viewModeControl.translatesAutoresizingMaskIntoConstraints = false
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureNavButton(navUpButton, symbol: "chevron.up", description: "Previous item", action: #selector(navigateUp))
        configureNavButton(navDownButton, symbol: "chevron.down", description: "Next item", action: #selector(navigateDown))

        configureZoomIcon(zoomOutIcon, symbol: "minus.magnifyingglass", description: "Zoom out")
        configureZoomIcon(zoomInIcon, symbol: "plus.magnifyingglass", description: "Zoom in")

        zoomSlider.minValue = 0.6
        zoomSlider.maxValue = 1.6
        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged)
        zoomSlider.isContinuous = true

        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.bezelStyle = .rounded
        openButton.controlSize = .regular
        openButton.font = .systemFont(ofSize: 13)
        openButton.target = self
        openButton.action = #selector(openRequested)
        openButton.isHidden = true
        openButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        pathIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        pathIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        pathGroup.addArrangedSubview(pathIcon)
        pathGroup.addArrangedSubview(pathLabel)
        trailingStack.addArrangedSubview(pathGroup)
        trailingStack.addArrangedSubview(openButton)

        addSubview(topSeparator)
        addSubview(viewModeControl)
        addSubview(navUpButton)
        addSubview(navDownButton)
        addSubview(zoomOutIcon)
        addSubview(zoomSlider)
        addSubview(zoomInIcon)
        addSubview(trailingStack)

        NSLayoutConstraint.activate([
            topSeparator.topAnchor.constraint(equalTo: topAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),

            viewModeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            viewModeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            viewModeControl.widthAnchor.constraint(equalToConstant: 148),

            navUpButton.leadingAnchor.constraint(equalTo: viewModeControl.trailingAnchor, constant: 10),
            navUpButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            navUpButton.widthAnchor.constraint(equalToConstant: 28),
            navUpButton.heightAnchor.constraint(equalToConstant: 24),

            navDownButton.leadingAnchor.constraint(equalTo: navUpButton.trailingAnchor, constant: 4),
            navDownButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            navDownButton.widthAnchor.constraint(equalToConstant: 28),
            navDownButton.heightAnchor.constraint(equalToConstant: 24),

            zoomSlider.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoomSlider.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomSlider.widthAnchor.constraint(equalToConstant: 132),

            zoomOutIcon.centerYAnchor.constraint(equalTo: zoomSlider.centerYAnchor),
            zoomOutIcon.trailingAnchor.constraint(equalTo: zoomSlider.leadingAnchor, constant: -6),
            zoomOutIcon.widthAnchor.constraint(equalToConstant: 16),
            zoomOutIcon.heightAnchor.constraint(equalToConstant: 16),

            zoomInIcon.centerYAnchor.constraint(equalTo: zoomSlider.centerYAnchor),
            zoomInIcon.leadingAnchor.constraint(equalTo: zoomSlider.trailingAnchor, constant: 6),
            zoomInIcon.widthAnchor.constraint(equalToConstant: 16),
            zoomInIcon.heightAnchor.constraint(equalToConstant: 16),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: zoomInIcon.trailingAnchor, constant: 16),

            heightAnchor.constraint(equalToConstant: Self.preferredHeight)
        ])
    }

    private func configureNavButton(_ button: NSButton, symbol: String, description: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .flexiblePush
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.imagePosition = .imageOnly
        button.toolTip = description
        button.target = self
        button.action = action
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureZoomIcon(_ view: NSImageView, symbol: String, description: String) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageScaling = .scaleProportionallyDown
        view.contentTintColor = .secondaryLabelColor
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    }

    private static func pathTitle(from components: [PathComponent]) -> String {
        let names = components.map(\.name).filter { !$0.isEmpty }
        guard !names.isEmpty else { return "" }
        return names.joined(separator: "  ›  ") + "  ›"
    }

    @objc private func viewModeChanged() {
        let mode = PreviewViewMode.allCases[viewModeControl.selectedSegment]
        PreviewSettings.viewMode = mode
        onViewModeChanged?(mode)
    }

    @objc private func zoomChanged() {
        PreviewSettings.iconZoom = zoomSlider.doubleValue
        onIconZoomChanged?(zoomSlider.doubleValue)
    }

    @objc private func openRequested() {
        onOpenRequested?()
    }

    @objc private func navigateUp() {
        onMoveSelection?(-1)
    }

    @objc private func navigateDown() {
        onMoveSelection?(1)
    }
}

struct PathComponent {
    let name: String
    let url: URL?
    let icon: NSImage?

    static func build(for url: URL, isArchive: Bool) -> [PathComponent] {
        var components: [PathComponent] = []
        components.append(PathComponent(
            name: FileManager.default.displayName(atPath: "/"),
            url: URL(fileURLWithPath: "/"),
            icon: NSImage(named: NSImage.computerName)
        ))

        if isArchive {
            for part in url.deletingLastPathComponent().pathComponents where part != "/" {
                components.append(PathComponent(
                    name: part,
                    url: nil,
                    icon: NSImage(named: NSImage.folderName)
                ))
            }
            components.append(PathComponent(
                name: url.lastPathComponent,
                url: url,
                icon: NSImage(named: NSImage.multipleDocumentsName)
            ))
        } else {
            var current = url
            var chain: [PathComponent] = []
            while current.path != "/" {
                chain.insert(PathComponent(
                    name: current.lastPathComponent,
                    url: current,
                    icon: NSImage(named: NSImage.folderName)
                ), at: 0)
                current.deleteLastPathComponent()
            }
            components.append(contentsOf: chain)
        }

        return components
    }
}
