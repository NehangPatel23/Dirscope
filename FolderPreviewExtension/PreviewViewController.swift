import AppKit
import QuickLookUI

enum AgentDebugLog {
    // #region agent log
    static func write(location: String, message: String, hypothesisId: String, data: [String: Any] = [:]) {
        let payload: [String: Any] = [
            "sessionId": "ff7b87",
            "runId": "run1",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var line = body
        line.append(0x0A)
        let url = URL(fileURLWithPath: "/Users/nehangpatel/Desktop/Dirscope - Folder Preview App/.cursor/debug-ff7b87.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:7675/ingest/b7ff33ef-71a8-43e2-9d29-6c51f218e667")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ff7b87", forHTTPHeaderField: "X-Debug-Session-Id")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }
    // #endregion
}

final class PreviewViewController: NSViewController, QLPreviewingController, QLPreviewPanelDelegate {
    private let tableView = FolderContentsTableView()
    private let collectionView = FolderContentsCollectionView()
    private let previewPane = FilePreviewPaneView()
    private let paneSeparator = NSBox()
    private let footerView = PreviewFooterView()
    private let emptyStateView = EmptyStateView()
    private var tableScrollView: NSScrollView!
    private var currentURL: URL?
    private var securityScopedURL: URL?
    private var isArchive = false
    private var rootItems: [FileItem] = []
    private var settingsDarwinObserver: UnsafeMutableRawPointer?
    private var isApplyingSettingsChange = false
    private var archiveDoubleClickMonitor: Any?
    private var keyMonitor: Any?
    private var lastHandledArrow: (time: TimeInterval, keyCode: UInt16)?
    private var listingGeneration = 0

    override var nibName: NSNib.Name? { nil }

    override var preferredContentSize: NSSize {
        get { PreviewLayout.contentSize }
        set { super.preferredContentSize = newValue }
    }

    override func loadView() {
        let rootView = PreviewRootView(frame: NSRect(origin: .zero, size: PreviewLayout.contentSize))
        view = rootView
        preferredContentSize = PreviewLayout.contentSize
        PreviewSettings.registerDefaults()
        setupUI()
        rootView.onEffectiveAppearanceChanged = { [weak self] in
            guard let self else { return }
            PreviewTheme.refreshSurfaceBackground(on: self.view)
            self.previewPane.refreshAppearance()
            self.footerView.refreshAppearance()
        }
        rootView.onKeyDown = { [weak self] event in
            self?.handleNavigationKey(event) ?? false
        }
        rootView.onMoveToWindow = { [weak self] in
            self?.installKeyMonitor()
            self?.focusFileList()
        }
        installKeyMonitor()
        // #region agent log
        AgentDebugLog.write(location: "PreviewViewController.loadView", message: "preview controller loaded", hypothesisId: "H8")
        // #endregion

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sharedSettingsDidChange),
            name: .previewSettingsDidChange,
            object: nil
        )

        settingsDarwinObserver = SharedPreferencesStore.addDarwinObserver { [weak self] in
            self?.sharedSettingsDidChange()
        }
    }

    func preparePreviewOfFile(at url: URL) async throws {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        let previewURL = url.resolvingSymlinksInPath()
        let archive = ArchiveContentLoader.isArchive(url)
        listingGeneration += 1
        let generation = listingGeneration

        let sorted = await Self.loadListing(of: previewURL, archive: archive)
        guard generation == listingGeneration else { return }

        currentURL = previewURL
        isArchive = archive
        PreviewSettings.reloadFromDisk()
        rootItems = sorted
        applySettings(reloadColumns: false)
        tableView.setRootItems(sorted)
        collectionView.items = sorted
        showPreview(nil)
        refreshFooter()
        updateVisibleContent(itemsEmpty: sorted.isEmpty)
        applyPreferredPanelSize()
        syncTableScrollerInsets()
        syncTableDocumentFrame()
        updateArchiveDoubleClickGuard()
        updateArchivePanelControl()
        focusFileList()
    }

    private static func loadListing(of url: URL, archive: Bool) async -> [FileItem] {
        await Task.detached(priority: .userInitiated) {
            if archive {
                return ArchiveContentLoader.loadContents(of: url)
            }
            return FolderContentLoader.loadContents(of: url)
        }.value
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateArchivePanelControl()
        installKeyMonitor()
        focusFileList()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = self
        // #region agent log
        AgentDebugLog.write(location: "PreviewViewController.beginPreviewPanelControl", message: "panel control began", hypothesisId: "H12")
        // #endregion
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.delegate as AnyObject? === self {
            panel.delegate = nil
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // #region agent log
        AgentDebugLog.write(
            location: "PreviewViewController.previewPanel.handleEvent",
            message: "panel event",
            hypothesisId: "H12",
            data: [
                "type": Int(event.type.rawValue),
                "keyCode": Int(event.keyCode),
                "isArchive": isArchive,
                "selected": tableView.selectedRow
            ]
        )
        // #endregion

        if isArchive,
           (event.type == .leftMouseDown || event.type == .leftMouseUp),
           event.clickCount >= 2 {
            handleArchiveDoubleClick(at: event.locationInWindow)
            return true
        }

        if isArchive, event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 {
            openSelectedArchiveEntry()
            return true
        }

        if event.type == .keyDown, handleNavigationKey(event) {
            return true
        }

        return false
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            // #region agent log
            AgentDebugLog.write(
                location: "PreviewViewController.keyMonitor",
                message: "local event",
                hypothesisId: "H17",
                data: [
                    "type": Int(event.type.rawValue),
                    "keyCode": Int(event.keyCode),
                    "windowNil": event.window == nil,
                    "viewWindowNil": self.view.window == nil,
                    "selected": self.tableView.selectedRow
                ]
            )
            // #endregion
            guard event.type == .keyDown else { return event }
            let dropped = event.window != nil && event.window !== self.view.window && self.view.window != nil
            if dropped { return event }
            return self.handleNavigationKey(event) ? nil : event
        }
        // #region agent log
        AgentDebugLog.write(
            location: "PreviewViewController.installKeyMonitor",
            message: "local monitor ready",
            hypothesisId: "H17",
            data: ["acceptsPanelControl": true]
        )
        // #endregion
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Up and down move through the file list. Quick Look otherwise keeps those keys.
    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        let delta: Int
        switch event.keyCode {
        case 126: delta = -1
        case 125: delta = 1
        default: return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            return false
        }
        if let textView = view.window?.firstResponder as? NSTextView, textView.isEditable {
            return false
        }
        if previewPane.isHandlingMediaInteraction(for: view.window?.firstResponder) {
            return false
        }
        if view.window?.firstResponder is NSSlider
            || view.window?.firstResponder is NSSegmentedControl
            || view.window?.firstResponder is NSPopUpButton {
            return false
        }
        if lastHandledArrow?.time == event.timestamp, lastHandledArrow?.keyCode == event.keyCode {
            return true
        }
        lastHandledArrow = (event.timestamp, event.keyCode)

        if tableScrollView.isHidden {
            collectionView.moveSelection(vertically: delta)
            view.window?.makeFirstResponder(collectionView.keyboardView)
        } else {
            tableView.moveSelection(vertically: delta)
            view.window?.makeFirstResponder(tableView)
        }
        return true
    }

    private func focusFileList() {
        guard view.window != nil else { return }
        let target: NSView = tableScrollView.isHidden ? collectionView.keyboardView : tableView
        view.window?.makeFirstResponder(target)
    }

    private func applyPreferredPanelSize() {
        preferredContentSize = PreviewLayout.contentSize
        view.setFrameSize(PreviewLayout.contentSize)
        if let window = view.window {
            window.setContentSize(PreviewLayout.contentSize)
        }
    }

    private func setupUI() {
        PreviewTheme.applySurfaceBackground(to: view)

        tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        PreviewTheme.applyRoundedScrollStyle(tableScrollView)
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = false
        tableScrollView.autohidesScrollers = true
        tableScrollView.scrollerStyle = .legacy
        tableScrollView.documentView = tableView
        tableView.frame = NSRect(
            x: 0,
            y: 0,
            width: PreviewLayout.listPaneWidth,
            height: PreviewLayout.defaultHeight - PreviewFooterView.totalHeight
        )

        collectionView.translatesAutoresizingMaskIntoConstraints = false

        paneSeparator.boxType = .separator
        paneSeparator.translatesAutoresizingMaskIntoConstraints = false

        previewPane.translatesAutoresizingMaskIntoConstraints = false
        footerView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        footerView.onViewModeChanged = { [weak self] mode in
            self?.switchViewMode(mode)
        }
        footerView.onIconZoomChanged = { [weak self] value in
            self?.collectionView.applyZoom(value)
            self?.tableView.applyZoom(value)
        }
        footerView.onOpenRequested = { [weak self] in
            self?.openSelectedArchiveEntry()
        }
        footerView.onMoveSelection = { [weak self] delta in
            guard let self else { return }
            if self.tableScrollView.isHidden {
                self.collectionView.moveSelection(vertically: delta)
            } else {
                self.tableView.moveSelection(vertically: delta)
            }
            // #region agent log
            AgentDebugLog.write(
                location: "PreviewViewController.footerNav",
                message: "footer move",
                hypothesisId: "H18",
                data: ["delta": delta, "selected": self.tableView.selectedRow]
            )
            // #endregion
        }

        tableView.onSortColumn = { [weak self] column in
            self?.handleSort(column)
        }
        tableView.onRowCountChanged = { [weak self] _ in
            self?.refreshFooter()
            self?.syncTableScrollerInsets()
            self?.syncTableDocumentFrame()
        }
        tableView.onItemSelected = { [weak self] item in
            self?.showPreview(item)
        }

        collectionView.onItemSelected = { [weak self] item in
            self?.showPreview(item)
        }

        view.addSubview(tableScrollView)
        view.addSubview(collectionView)
        view.addSubview(paneSeparator)
        view.addSubview(previewPane)
        view.addSubview(footerView)
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            tableScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            tableScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: paneSeparator.leadingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: footerView.topAnchor),

            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: paneSeparator.leadingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: footerView.topAnchor),

            paneSeparator.topAnchor.constraint(equalTo: view.topAnchor),
            paneSeparator.bottomAnchor.constraint(equalTo: footerView.topAnchor),
            paneSeparator.widthAnchor.constraint(equalToConstant: 1),

            previewPane.topAnchor.constraint(equalTo: view.topAnchor),
            previewPane.leadingAnchor.constraint(equalTo: paneSeparator.trailingAnchor),
            previewPane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewPane.bottomAnchor.constraint(equalTo: footerView.topAnchor),
            previewPane.widthAnchor.constraint(equalToConstant: PreviewLayout.previewPaneWidth),

            footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -PreviewFooterView.bottomInset),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -10)
        ])

        applySettings(reloadColumns: true)
        switchViewMode(PreviewSettings.viewMode)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidResize),
            name: NSView.frameDidChangeNotification,
            object: tableScrollView.contentView
        )

    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncTableScrollerInsets()
        syncTableDocumentFrame()
    }

    @objc private func scrollViewDidResize() {
        syncTableScrollerInsets()
        syncTableDocumentFrame()
    }

    @objc private func sharedSettingsDidChange() {
        guard !isApplyingSettingsChange else { return }
        isApplyingSettingsChange = true
        defer { isApplyingSettingsChange = false }

        PreviewSettings.reloadFromDisk()
        guard currentURL != nil else { return }
        reloadFromCurrentSettings()
    }

    private func reloadFromCurrentSettings() {
        guard let currentURL else { return }
        listingGeneration += 1
        let generation = listingGeneration
        let archive = isArchive
        let url = currentURL

        Task {
            let sorted = await Self.loadListing(of: url, archive: archive)
            guard generation == self.listingGeneration else { return }
            self.rootItems = sorted
            self.applySettings(reloadColumns: true)
            self.tableView.setRootItems(sorted)
            self.collectionView.items = sorted
            self.tableView.applySort()
            self.tableView.updateSortIndicators()
            self.switchViewMode(PreviewSettings.viewMode)
            self.refreshFooter()
            self.updateVisibleContent(itemsEmpty: sorted.isEmpty)
            self.syncTableScrollerInsets()
            self.syncTableDocumentFrame()
        }
    }

    private func syncTableScrollerInsets() {
        guard tableScrollView != nil, !tableScrollView.isHidden else { return }
        tableView.layoutSubtreeIfNeeded()
        let headerHeight = tableView.headerView?.frame.height ?? 0
        tableScrollView.scrollerInsets = NSEdgeInsets(top: headerHeight, left: 0, bottom: 0, right: 0)
    }

    private static let tableBottomScrollPadding: CGFloat = 16

    private func syncTableDocumentFrame() {
        guard tableScrollView != nil, !tableScrollView.isHidden else { return }
        let clipSize = tableScrollView.contentView.bounds.size
        guard clipSize.width > 1, clipSize.height > 1 else { return }

        tableView.layoutSubtreeIfNeeded()
        tableView.frame.size.width = clipSize.width

        let rows = tableView.numberOfRows
        let bottomPadding = tableView.rowHeight * 0.5 + Self.tableBottomScrollPadding
        let contentHeight: CGFloat
        if rows > 0 {
            let lastRowMaxY = tableView.rect(ofRow: rows - 1).maxY
            contentHeight = lastRowMaxY + bottomPadding
        } else {
            contentHeight = (tableView.headerView?.frame.height ?? 24) + bottomPadding
        }

        tableView.frame.size.height = max(contentHeight, clipSize.height)
        tableView.needsDisplay = true
    }

    private func applySettings(reloadColumns: Bool = false) {
        let textSize = PreviewSettings.textSize
        tableView.textSize = textSize
        tableView.showThumbnails = PreviewSettings.showThumbnails
        if reloadColumns {
            tableView.reloadColumnLayout()
            syncTableDocumentFrame()
        }
        collectionView.textSize = textSize
        collectionView.applyZoom(PreviewSettings.iconZoom)
        tableView.zoom = PreviewSettings.iconZoom
    }

    private func showPreview(_ item: FileItem?) {
        previewPane.show(item: item)
        let canOpen = isArchive && item != nil && item?.isContainer == false
        footerView.setOpenEnabled(canOpen)
    }

    private func refreshFooter() {
        guard let currentURL else { return }
        let visible = tableView.visibleItemsForSummary()
        let summaryItems = visible.isEmpty ? rootItems : visible
        let count = summaryItems.count
        let sizeText = FileItemSummary.formattedTotalSize(of: summaryItems)
        let status = count == 0
            ? "Nothing here"
            : "\(count) item\(count == 1 ? "" : "s") · \(sizeText)"

        footerView.configure(
            pathComponents: PathComponent.build(for: currentURL, isArchive: isArchive),
            statusText: status,
            viewMode: PreviewSettings.viewMode,
            showPathBar: PreviewSettings.showPathBar,
            iconZoom: PreviewSettings.iconZoom
        )
    }

    private func switchViewMode(_ mode: PreviewViewMode) {
        let isList = mode == .list
        tableScrollView.isHidden = !isList
        collectionView.isHidden = isList
        refreshFooter()
        focusFileList()
    }

    private func updateVisibleContent(itemsEmpty: Bool) {
        let showContent = !itemsEmpty
        let isList = PreviewSettings.viewMode == .list
        tableScrollView.isHidden = !showContent || !isList
        collectionView.isHidden = !showContent || isList
        paneSeparator.isHidden = !showContent
        previewPane.isHidden = !showContent
        footerView.isHidden = !showContent
        emptyStateView.isHidden = showContent
    }

    private func handleSort(_ column: PreviewColumn) {
        if PreviewSettings.sortColumnID == column.rawValue {
            PreviewSettings.sortAscending.toggle()
        } else {
            PreviewSettings.sortColumnID = column.rawValue
            PreviewSettings.sortAscending = [.size, .dateModified, .dateCreated, .dateLastOpened, .dateAdded].contains(column)
                ? false
                : true
        }

        tableView.applySort()
        collectionView.items = FolderContentLoader.sorted(rootItems)
        tableView.updateSortIndicators()
        refreshFooter()
    }

    private func updateArchivePanelControl() {
        guard view.window != nil else { return }
        QLPreviewPanel.shared()?.updateController()
    }

    private func updateArchiveDoubleClickGuard() {
        removeArchiveDoubleClickGuard()
        guard isArchive else { return }

        archiveDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, self.isArchive, event.clickCount >= 2 else { return event }

            let pointInView = self.view.convert(event.locationInWindow, from: nil)
            guard self.view.bounds.contains(pointInView) else { return event }

            self.handleArchiveDoubleClick(at: event.locationInWindow)
            return nil
        }
    }

    private func removeArchiveDoubleClickGuard() {
        if let archiveDoubleClickMonitor {
            NSEvent.removeMonitor(archiveDoubleClickMonitor)
            self.archiveDoubleClickMonitor = nil
        }
    }

    private func handleArchiveDoubleClick(at windowPoint: NSPoint) {
        if !tableScrollView.isHidden {
            let pointInScroll = tableScrollView.convert(windowPoint, from: nil)
            if tableScrollView.bounds.contains(pointInScroll) {
                let pointInTable = tableView.convert(windowPoint, from: nil)
                let row = tableView.row(at: pointInTable)
                if row >= 0 {
                    tableView.openItem(atRow: row)
                    return
                }
            }
        }

        if !collectionView.isHidden {
            let pointInCollection = collectionView.convert(windowPoint, from: nil)
            if collectionView.bounds.contains(pointInCollection) {
                collectionView.openItem(at: windowPoint)
                return
            }
        }

        openSelectedArchiveEntry()
    }

    private func openSelectedArchiveEntry() {
        if !tableScrollView.isHidden {
            let row = tableView.selectedRow
            guard row >= 0 else { return }
            tableView.openItem(atRow: row)
            return
        }

        if !collectionView.isHidden {
            collectionView.openSelectedItem()
        }
    }

    deinit {
        removeKeyMonitor()
        removeArchiveDoubleClickGuard()
        if let settingsDarwinObserver {
            SharedPreferencesStore.removeDarwinObserver(settingsDarwinObserver)
        }
        NotificationCenter.default.removeObserver(self)
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}

private final class PreviewRootView: NSView {
    var onEffectiveAppearanceChanged: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onMoveToWindow: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChanged?()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDown?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class EmptyStateView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "No items here")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        iconView.contentTintColor = .tertiaryLabelColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
