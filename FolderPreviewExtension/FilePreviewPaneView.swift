import AppKit
import AVFoundation
import AVKit
import ImageIO
import ObjectiveC
import QuickLookUI
import UniformTypeIdentifiers

final class FilePreviewPaneView: NSView {
    private let fileIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl()
    private let encodingPopup = NSPopUpButton()
    private let topSeparator = NSBox()
    private let contentContainer = NSView()
    private let imageInspector = ImageInspectorView()
    private var separatorToSubtitle: NSLayoutConstraint?
    private var separatorToTitle: NSLayoutConstraint?

    private var qlPreviewView: QLPreviewView?
    private let playerView = PreviewPlayerView()
    private var playerStatusObservation: NSKeyValueObservation?
    private var playerFileURL: URL?
    private var playerFileIsSecurityScoped = false
    private var mediaToken: UUID?
    private let sourceScrollView = NSScrollView()
    private let sourceCanvas = SourceCanvasView()
    private let renderedScrollView = NSScrollView()
    private let renderedTextView = PreviewTextView()
    private let imageScrollView = NSScrollView()
    private let imagePreviewView = NSImageView()
    private let svgImageView = NSImageView()
    private let placeholderView = PreviewPlaceholderView()

    private var currentItem: FileItem?
    private var currentSourceText: String?
    private var currentRichFormat: RichTextPreviewFormat?
    private var displayMode: FilePreviewDisplayMode = .source
    private var extractedTempURL: URL?
    private var archiveEntryData: Data?
    private var archiveLoadToken: UUID?
    private var highlightToken = UUID()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func show(item: FileItem?) {
        stopMediaPlayer()
        cleanupExtractedTempFile()
        archiveEntryData = nil
        archiveLoadToken = nil
        currentItem = item
        currentSourceText = nil
        currentRichFormat = nil
        modeControl.isHidden = true
        encodingPopup.isHidden = true
        setDocumentChrome(hidden: false)

        guard let item else {
            fileIconView.image = nil
            showPlaceholder(message: "Click a file in the list to inspect it here.")
            return
        }

        fileIconView.image = FileIconCache.shared.icon(for: item)
        titleLabel.stringValue = item.name
        subtitleLabel.stringValue = item.isDirectory ? "Directory" : (item.isBrowsableArchive ? "Archive" : item.kind)
        setSubtitleVisible(true)

        if item.isDirectory {
            placeholderView.configure(
                icon: NSImage(named: NSImage.folderName),
                title: item.name,
                message: "Use the disclosure arrow in the list to open this directory."
            )
            showPlaceholderMode()
            return
        }

        if item.isBrowsableArchive && !item.isArchiveEntry {
            placeholderView.configure(
                icon: NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil),
                title: item.name,
                message: "Use the disclosure arrow in the list to browse this archive."
            )
            showPlaceholderMode()
            return
        }

        if item.isArchiveEntry {
            showArchiveEntryPreview(for: item)
            return
        }

        if InlineFilePreviewLoader.isTextPreviewable(item.url) {
            if (item.size ?? 0) > 96_000 {
                showTextFileAsynchronously(item)
                return
            }
            if let text = InlineFilePreviewLoader.loadText(from: item.url) {
                showRichOrPlainText(text, for: item)
                return
            }
        }

        if OfficeDocumentPreview.isPreviewable(fileName: item.name) {
            showOfficeFile(item)
            return
        }

        if Self.isImageFile(named: item.name) {
            showFileImagePreview(for: item)
            return
        }

        if Self.isPlayableMedia(named: item.name) {
            showMediaPlayer(url: item.url)
            return
        }

        if Self.canOfferSystemPreview(for: item.url), showQuickLookPreview(for: item.url) {
            return
        }

        placeholderView.configure(
            icon: FileIconCache.shared.icon(for: item),
            title: item.name,
            message: "Double-click to launch in its default application."
        )
        showPlaceholderMode()
    }

    private func showTextFileAsynchronously(_ item: FileItem) {
        let token = UUID()
        archiveLoadToken = token
        placeholderView.configure(
            icon: FileIconCache.shared.icon(for: item),
            title: item.name,
            message: "Loading preview…"
        )
        showPlaceholderMode()

        let url = item.url
        let itemID = item.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = InlineFilePreviewLoader.loadText(from: url)
            DispatchQueue.main.async {
                guard let self, self.archiveLoadToken == token, self.currentItem?.id == itemID else { return }
                if let text {
                    self.showRichOrPlainText(text, for: item)
                } else {
                    self.placeholderView.configure(
                        icon: FileIconCache.shared.icon(for: item),
                        title: item.name,
                        message: "Double-click to launch in its default application."
                    )
                    self.showPlaceholderMode()
                }
            }
        }
    }

    private func showArchiveEntryPreview(for item: FileItem) {
        let token = UUID()
        archiveLoadToken = token

        placeholderView.configure(
            icon: FileIconCache.shared.icon(for: item),
            title: item.name,
            message: "Loading preview…"
        )
        showPlaceholderMode()

        let archiveURL = item.url
        let relativePath = item.relativePath
        let itemID = item.id

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            guard let data = ArchiveContentLoader.extractEntryData(from: archiveURL, path: relativePath),
                  !data.isEmpty else {
                DispatchQueue.main.async {
                    guard self.archiveLoadToken == token, self.currentItem?.id == itemID else { return }
                    self.showArchivePreviewFailure(for: item)
                }
                return
            }

            if OfficeDocumentPreview.isPreviewable(fileName: item.name),
               let preview = OfficeDocumentPreview.preview(of: data, fileName: item.name) {
                DispatchQueue.main.async {
                    guard self.archiveLoadToken == token, self.currentItem?.id == itemID else { return }
                    self.archiveEntryData = data
                    self.showOfficePreview(preview)
                }
                return
            }

            if Self.isImageFile(named: item.name) {
                let loaded = Self.loadPreviewImage(from: data)
                DispatchQueue.main.async {
                    guard self.archiveLoadToken == token, self.currentItem?.id == itemID else { return }
                    if let loaded {
                        self.archiveEntryData = data
                        self.showImageInspector(loaded.image, metadata: loaded.metadata, item: item)
                    } else {
                        self.showArchivePreviewFailure(for: item)
                    }
                }
                return
            }

            if Self.isPlayableMedia(named: item.name),
               let tempURL = ArchiveContentLoader.writeEntryDataToTempFile(data, filename: item.name) {
                DispatchQueue.main.async {
                    guard self.archiveLoadToken == token, self.currentItem?.id == itemID else {
                        try? FileManager.default.removeItem(at: tempURL)
                        return
                    }
                    self.extractedTempURL = tempURL
                    self.showMediaPlayer(url: tempURL)
                }
                return
            }

            DispatchQueue.main.async {
                guard self.archiveLoadToken == token, self.currentItem?.id == itemID else { return }
                self.presentArchiveEntryData(data, for: item)
            }
        }
    }

    private func presentArchiveEntryData(_ data: Data, for item: FileItem) {
        archiveEntryData = data

        if InlineFilePreviewLoader.isTextPreviewable(fileName: item.name),
           let text = InlineFilePreviewLoader.decodeText(from: data) {
            showRichOrPlainText(text, for: item)
            return
        }

        if Self.isPlayableMedia(named: item.name),
           let tempURL = ArchiveContentLoader.writeEntryDataToTempFile(data, filename: item.name) {
            extractedTempURL = tempURL
            showMediaPlayer(url: tempURL)
            return
        }

        if let tempURL = ArchiveContentLoader.writeEntryDataToTempFile(data, filename: item.name),
           Self.canOfferSystemPreview(for: tempURL) {
            extractedTempURL = tempURL
            if showQuickLookPreview(for: tempURL) {
                return
            }
            cleanupExtractedTempFile()
        }

        showArchivePreviewFailure(for: item)
    }

    private func showArchivePreviewFailure(for item: FileItem) {
        placeholderView.configure(
            icon: FileIconCache.shared.icon(for: item),
            title: item.name,
            message: "This file could not be previewed from the archive. Use Open or double-click the file in the list."
        )
        showPlaceholderMode()
    }

    private static func isImageFile(named name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) && type.identifier != "public.svg-image"
    }

    private static let playableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "avi", "mpg", "mpeg", "mpe", "3gp", "3g2",
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac"
    ]

    private static func isPlayableMedia(named name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if playableExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .image) { return false }
        return type.conforms(to: .movie)
            || type.conforms(to: .video)
            || type.conforms(to: .audio)
            || type.conforms(to: .audiovisualContent)
    }

    func isHandlingMediaInteraction(for responder: NSResponder?) -> Bool {
        guard !playerView.isHidden, let view = responder as? NSView else { return false }
        return view === playerView || view.isDescendant(of: playerView)
    }

    private func showMediaPlayer(url: URL) {
        hideAllContentViews()
        setDocumentChrome(hidden: false)

        let scoped = url.startAccessingSecurityScopedResource()
        playerFileURL = url
        playerFileIsSecurityScoped = scoped

        let token = UUID()
        mediaToken = token
        let player = AVPlayer(url: url)
        player.preventsDisplaySleepDuringVideoPlayback = true
        playerView.player = player
        playerView.isHidden = false
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(playerView)

        playerStatusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.mediaToken == token, item.status == .failed else { return }
                self.stopMediaPlayer()
                if !self.showQuickLookPreview(for: url) {
                    self.placeholderView.configure(
                        icon: NSImage(systemSymbolName: "film", accessibilityDescription: nil),
                        title: url.lastPathComponent,
                        message: "This media file could not be played."
                    )
                    self.showPlaceholderMode()
                }
            }
        }
        player.play()
    }

    private func stopMediaPlayer() {
        mediaToken = nil
        playerStatusObservation = nil
        playerView.player?.pause()
        playerView.player = nil
        if playerFileIsSecurityScoped, let playerFileURL {
            playerFileURL.stopAccessingSecurityScopedResource()
        }
        playerFileIsSecurityScoped = false
        playerFileURL = nil
    }

    private func showOfficeFile(_ item: FileItem) {
        let token = UUID()
        archiveLoadToken = token
        placeholderView.configure(
            icon: FileIconCache.shared.icon(for: item),
            title: item.name,
            message: "Loading preview…"
        )
        showPlaceholderMode()

        let url = item.url
        let fileName = item.name
        let itemID = item.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let package = OfficeDocumentPreview.loadPackage(at: url)
            let preview = package.flatMap { OfficeDocumentPreview.preview(of: $0, fileName: fileName) }
            DispatchQueue.main.async {
                guard let self, self.archiveLoadToken == token, self.currentItem?.id == itemID else { return }
                if let preview {
                    self.showOfficePreview(preview)
                } else if !Self.canOfferSystemPreview(for: url) || !self.showQuickLookPreview(for: url) {
                    self.placeholderView.configure(
                        icon: FileIconCache.shared.icon(for: item),
                        title: item.name,
                        message: "This document could not be previewed. Double-click to open it in its default application."
                    )
                    self.showPlaceholderMode()
                }
            }
        }
    }

    private func showOfficePreview(_ preview: OfficePreviewDocument) {
        hideAllContentViews()
        setDocumentChrome(hidden: false)
        subtitleLabel.stringValue = preview.summary
        setSubtitleVisible(true)
        modeControl.isHidden = true
        encodingPopup.isHidden = true
        renderedScrollView.isHidden = false
        renderedTextView.textStorage?.setAttributedString(preview.attributedText)
        renderedTextView.layoutManager?.ensureLayout(for: renderedTextView.textContainer!)
        renderedTextView.scrollToBeginningOfDocument(nil)
    }

    private func showFileImagePreview(for item: FileItem) {
        let token = UUID()
        archiveLoadToken = token
        let url = item.url
        let waitingOnCloud = Self.ubiquitousStatus(of: url) == .notDownloaded
        placeholderView.configure(
            icon: waitingOnCloud
                ? NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil)
                : FileIconCache.shared.icon(for: item),
            title: item.name,
            message: waitingOnCloud ? "Downloading from iCloud…" : "Loading preview…"
        )
        showPlaceholderMode()

        let itemID = item.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = Self.loadPreviewImageResolvingCloud(at: url)
            DispatchQueue.main.async {
                guard let self, self.archiveLoadToken == token, self.currentItem?.id == itemID else { return }
                switch loaded {
                case .ready(let image):
                    self.showImageInspector(image.image, metadata: image.metadata, item: item)
                case .unavailableInCloud:
                    self.placeholderView.configure(
                        icon: NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil),
                        title: item.name,
                        message: "This image is in iCloud and isn’t on this Mac yet. Check the network connection, then select it again."
                    )
                    self.showPlaceholderMode()
                case .failed:
                    self.placeholderView.configure(
                        icon: FileIconCache.shared.icon(for: item),
                        title: item.name,
                        message: "This image could not be previewed."
                    )
                    self.showPlaceholderMode()
                }
            }
        }
    }

    private struct LoadedPreviewImage {
        let image: NSImage
        let metadata: ImageFileMetadata
    }

    private enum ImagePreviewLoad {
        case ready(LoadedPreviewImage)
        case unavailableInCloud
        case failed
    }

    /// iCloud files that are not on disk yet have no pixels for ImageIO to read.
    /// Quick Look then draws the generic document icon, which looks like a broken preview.
    private static func loadPreviewImageResolvingCloud(at url: URL) -> ImagePreviewLoad {
        let remote = ubiquitousStatus(of: url) == .notDownloaded
        guard remote else {
            return loadPreviewImage(at: url).map(ImagePreviewLoad.ready) ?? .failed
        }

        let coordinator = NSFileCoordinator()
        let cancel = DispatchWorkItem { coordinator.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45, execute: cancel)
        defer { cancel.cancel() }

        var coordError: NSError?
        var loaded: LoadedPreviewImage?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            loaded = loadPreviewImage(at: readURL)
            if loaded == nil, let data = try? Data(contentsOf: readURL, options: [.mappedIfSafe]) {
                loaded = loadPreviewImage(from: data)
            }
        }
        if let loaded { return .ready(loaded) }
        if coordError != nil || ubiquitousStatus(of: url) == .notDownloaded {
            return .unavailableInCloud
        }
        return .failed
    }

    private static func ubiquitousStatus(of url: URL) -> URLUbiquitousItemDownloadingStatus? {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]), values.isUbiquitousItem == true else { return nil }
        return values.ubiquitousItemDownloadingStatus
    }

    private static func loadPreviewImage(from data: Data) -> LoadedPreviewImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            guard let image = NSImage(data: data), hasDrawableSize(image) else { return nil }
            return LoadedPreviewImage(image: image, metadata: ImageFileMetadata())
        }
        return loadPreviewImage(source: source) ?? nsImageFallback(NSImage(data: data))
    }

    private static func loadPreviewImage(at url: URL) -> LoadedPreviewImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nsImageFallback(NSImage(contentsOf: url))
        }
        if let loaded = loadPreviewImage(source: source) { return loaded }
        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            return loadPreviewImage(from: data)
        }
        return nsImageFallback(NSImage(contentsOf: url))
    }

    private static func nsImageFallback(_ image: NSImage?) -> LoadedPreviewImage? {
        guard let image, hasDrawableSize(image) else { return nil }
        return LoadedPreviewImage(image: image, metadata: ImageFileMetadata())
    }

    private static func hasDrawableSize(_ image: NSImage) -> Bool {
        image.size.width > 1 && image.size.height > 1
    }

    private static func loadPreviewImage(source: CGImageSource) -> LoadedPreviewImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let metadata = ImageFileMetadata(
            pixelWidth: integerProperty(props, kCGImagePropertyPixelWidth),
            pixelHeight: integerProperty(props, kCGImagePropertyPixelHeight),
            profileName: props?[kCGImagePropertyProfileName] as? String
        )
        guard let image = thumbnailImage(from: source, maxPixelSize: 4096)
            ?? fullSizeImage(from: source, maxPixelSize: 4096) else { return nil }
        return LoadedPreviewImage(image: image, metadata: metadata)
    }

    private static func integerProperty(_ props: [CFString: Any]?, _ key: CFString) -> Int? {
        switch props?[key] {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        default: return nil
        }
    }

    private static func thumbnailImage(from source: CGImageSource, maxPixelSize: CGFloat) -> NSImage? {
        let options: NSDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: NSNumber(value: Int(maxPixelSize)),
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return displayImage(cgImage)
    }

    /// PNGs have no embedded thumbnail. If thumbnail creation rejects the file
    /// (16-bit, an unusual color profile, or a mismatched extension), decode it directly.
    private static func fullSizeImage(from source: CGImageSource, maxPixelSize: CGFloat) -> NSImage? {
        let options: NSDictionary = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return displayImage(downsample(cgImage, maxPixelSize: maxPixelSize))
    }

    private static func displayImage(_ cgImage: CGImage) -> NSImage {
        let fitted = downsample(cgImage, maxPixelSize: 4096)
        let width = fitted.width
        let height = fitted.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return NSImage(cgImage: fitted, size: NSSize(width: fitted.width, height: fitted.height))
        }
        context.interpolationQuality = .high
        context.draw(fitted, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let drawn = context.makeImage() else {
            return NSImage(cgImage: fitted, size: NSSize(width: fitted.width, height: fitted.height))
        }
        return NSImage(cgImage: drawn, size: NSSize(width: width, height: height))
    }

    private static func downsample(_ cgImage: CGImage, maxPixelSize: CGFloat) -> CGImage {
        let largest = max(cgImage.width, cgImage.height)
        guard largest > Int(maxPixelSize), largest > 0 else { return cgImage }
        let scale = maxPixelSize / CGFloat(largest)
        let width = max(1, Int((CGFloat(cgImage.width) * scale).rounded(.down)))
        let height = max(1, Int((CGFloat(cgImage.height) * scale).rounded(.down)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return cgImage }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? cgImage
    }

    private func cleanupExtractedTempFile() {
        guard let extractedTempURL else { return }
        try? FileManager.default.removeItem(at: extractedTempURL)
        self.extractedTempURL = nil
    }

    private func showRichOrPlainText(_ text: String, for item: FileItem) {
        currentSourceText = text
        currentRichFormat = RichTextPreviewFormat.format(forFileName: item.name)

        if let format = currentRichFormat, formattedPreviewIsFeasible(format, text: text, item: item) {
            modeControl.isHidden = false
            modeControl.setLabel(format.sourceLabel, forSegment: 0)
            modeControl.setLabel(format.renderedLabel, forSegment: 1)
            displayMode = .source
            modeControl.selectedSegment = displayMode.rawValue
        } else {
            currentRichFormat = nil
            displayMode = .source
            modeControl.isHidden = true
        }

        applyDisplayMode()
    }

    /// Decides whether Formatted is worth offering without rendering the document.
    private func formattedPreviewIsFeasible(_ format: RichTextPreviewFormat, text: String, item: FileItem) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch format {
        case .markdown:
            return true
        case .html:
            return trimmed.contains("<")
        case .svg:
            let lowered = trimmed.lowercased()
            if lowered.contains("<svg") { return true }
            let url = previewContentURL(for: item)
            return NSImage(contentsOf: url) != nil
        }
    }

    private func applyDisplayMode() {
        guard let text = currentSourceText, let item = currentItem else { return }

        if let format = currentRichFormat {
            switch displayMode {
            case .source:
                showSourceText(text)
            case .rendered:
                showRenderedPreview(for: item, format: format, source: text)
            }
            return
        }

        showSourceText(text)
    }

    private func showRenderedPreview(for item: FileItem, format: RichTextPreviewFormat, source: String) {
        let baseURL = previewBaseURL(for: item)

        switch format {
        case .markdown:
            if let attributed = RichTextPreviewRenderer.renderedMarkdown(source, baseURL: baseURL) {
                showRenderedAttributedText(attributed)
            } else {
                showSourceText(source)
            }

        case .html:
            showHTMLPreview(for: item, source: source, baseURL: baseURL)

        case .svg:
            showSVGPreview(for: previewContentURL(for: item), source: source)
        }
    }

    private func previewContentURL(for item: FileItem) -> URL {
        if item.isArchiveEntry {
            return URL(fileURLWithPath: item.name)
        }
        return item.url
    }

    private func previewBaseURL(for item: FileItem) -> URL {
        if item.isArchiveEntry,
           let data = archiveEntryData,
           let tempURL = ArchiveContentLoader.writeEntryDataToTempFile(data, filename: item.name) {
            extractedTempURL = tempURL
            return tempURL.deletingLastPathComponent()
        }
        return item.url.deletingLastPathComponent()
    }

    private func showHTMLPreview(for item: FileItem, source: String, baseURL: URL) {
        if let attributed = RichTextPreviewRenderer.renderedHTML(source, baseURL: baseURL),
           RichTextPreviewRenderer.hasVisibleText(attributed) {
            showRenderedAttributedText(attributed)
            return
        }

        placeholderView.configure(
            icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil),
            title: item.name,
            message: "This page needs a web browser to display. Switch to Source to read the markup, or double-click to open it externally."
        )
        hideAllContentViews()
        placeholderView.isHidden = false
    }

    func refreshAppearance() {
        PreviewTheme.refreshSurfaceBackground(on: self)
        sourceScrollView.backgroundColor = PreviewTheme.sourceEditorBackground
        sourceCanvas.backgroundColor = PreviewTheme.sourceEditorBackground
        if !sourceScrollView.isHidden, let text = currentSourceText {
            applySourceHighlighting(text)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func setup() {
        _ = PreviewFirstMouse.enable
        wantsLayer = true
        layer?.masksToBounds = true
        PreviewTheme.applySurfaceBackground(to: self)

        fileIconView.translatesAutoresizingMaskIntoConstraints = false
        fileIconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textColor = .labelColor
        titleLabel.backgroundColor = .clear

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.backgroundColor = .clear
        subtitleLabel.lineBreakMode = .byTruncatingTail

        modeControl.segmentCount = 2
        modeControl.segmentStyle = .automatic
        modeControl.trackingMode = .selectOne
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.isHidden = true
        modeControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        encodingPopup.translatesAutoresizingMaskIntoConstraints = false
        encodingPopup.controlSize = .small
        encodingPopup.font = .systemFont(ofSize: 11)
        encodingPopup.addItem(withTitle: "UTF-8")
        encodingPopup.isHidden = true
        encodingPopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        configureSourceCanvasScroll(sourceScrollView, canvas: sourceCanvas)
        configureRenderedTextScroll(renderedScrollView, textView: renderedTextView)

        imageScrollView.translatesAutoresizingMaskIntoConstraints = false
        imageScrollView.hasVerticalScroller = true
        imageScrollView.hasHorizontalScroller = true
        imageScrollView.autohidesScrollers = true
        imageScrollView.borderType = .noBorder
        imageScrollView.drawsBackground = false
        imagePreviewView.imageScaling = .scaleProportionallyDown
        imagePreviewView.imageAlignment = .alignCenter
        imageScrollView.documentView = imagePreviewView

        svgImageView.translatesAutoresizingMaskIntoConstraints = false
        svgImageView.imageScaling = .scaleProportionallyDown
        svgImageView.imageAlignment = .alignCenter
        svgImageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        svgImageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        svgImageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        svgImageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        imageInspector.translatesAutoresizingMaskIntoConstraints = false
        imageInspector.isHidden = true

        let headerControls = NSStackView()
        headerControls.orientation = .horizontal
        headerControls.alignment = .centerY
        headerControls.spacing = 8
        headerControls.detachesHiddenViews = true
        headerControls.translatesAutoresizingMaskIntoConstraints = false
        headerControls.addArrangedSubview(modeControl)
        headerControls.addArrangedSubview(encodingPopup)

        addSubview(fileIconView)
        addSubview(titleLabel)
        addSubview(headerControls)
        addSubview(subtitleLabel)
        addSubview(topSeparator)
        addSubview(contentContainer)
        addSubview(imageInspector)
        contentContainer.addSubview(sourceScrollView)
        contentContainer.addSubview(renderedScrollView)
        contentContainer.addSubview(imageScrollView)
        contentContainer.addSubview(svgImageView)
        contentContainer.addSubview(placeholderView)

        separatorToSubtitle = topSeparator.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8)
        separatorToTitle = topSeparator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10)
        separatorToSubtitle?.isActive = true

        NSLayoutConstraint.activate([
            fileIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            fileIconView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            fileIconView.widthAnchor.constraint(equalToConstant: 16),
            fileIconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: fileIconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerControls.leadingAnchor, constant: -8),

            headerControls.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            headerControls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            sourceScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            sourceScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            sourceScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            sourceScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            renderedScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            renderedScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            renderedScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            renderedScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            imageScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            imageScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            imageScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            imageScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            svgImageView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 12),
            svgImageView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 12),
            svgImageView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -12),
            svgImageView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -12),

            placeholderView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            imageInspector.topAnchor.constraint(equalTo: topAnchor),
            imageInspector.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageInspector.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageInspector.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if let preview = QLPreviewView(frame: .zero, style: .normal) {
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.autostarts = true
            qlPreviewView = preview
            contentContainer.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                preview.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                preview.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
            preview.isHidden = true
        }

        playerView.isHidden = true
        contentContainer.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])

        showPlaceholder(message: "Click a file in the list to inspect it here.")
    }

    private func configureSourceCanvasScroll(_ scrollView: NSScrollView, canvas: SourceCanvasView) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = PreviewTheme.sourceEditorBackground
        scrollView.contentView.drawsBackground = false
        canvas.autoresizingMask = [.width]
        canvas.backgroundColor = PreviewTheme.sourceEditorBackground
        scrollView.documentView = canvas
    }

    private func configureRenderedTextScroll(_ scrollView: NSScrollView, textView: NSTextView) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        scrollView.documentView = textView
    }

    @objc private func modeChanged() {
        guard modeControl.selectedSegment >= 0,
              let mode = FilePreviewDisplayMode(rawValue: modeControl.selectedSegment) else { return }
        displayMode = mode
        applyDisplayMode()
    }

    /// Quick Look only for types that have a real system preview. Everything else
    /// stays on the placeholder instead of an empty preview surface.
    private static func canOfferSystemPreview(for url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || type.conforms(to: .text) {
                return false
            }
            if type.conforms(to: .image)
                || type.conforms(to: .pdf)
                || type.conforms(to: .movie)
                || type.conforms(to: .audio)
                || type.conforms(to: .audiovisualContent) {
                return true
            }
        }
        let known: Set<String> = [
            "doc", "docx", "docm", "dotx", "dotm",
            "xls", "xlsx", "xlsm", "xltx", "xltm",
            "ppt", "pptx", "pptm", "potx", "potm", "ppsx", "ppsm",
            "odt", "ott", "ods", "ots", "odp", "otp",
            "rtf", "rtfd", "pages", "numbers", "key", "keynote",
            "psd", "ai", "eps"
        ]
        return known.contains(ext)
    }

    @discardableResult
    private func showQuickLookPreview(for url: URL) -> Bool {
        guard let qlPreviewView, Self.canOfferSystemPreview(for: url) else { return false }
        hideAllContentViews()
        qlPreviewView.isHidden = false
        qlPreviewView.previewItem = url as NSURL
        qlPreviewView.refreshPreviewItem()
        return true
    }

    private func showRenderedAttributedText(_ attributed: NSAttributedString) {
        hideAllContentViews()
        // Formatted markdown/HTML also fails to composite as NSTextView text in Quick Look.
        // Reuse the bitmap source canvas so the rendered text is visible.
        sourceScrollView.isHidden = false
        layoutSubtreeIfNeeded()
        let width = max(sourceScrollView.contentSize.width, sourceScrollView.bounds.width, 1)
        sourceCanvas.display(attributed, width: width)
        contentContainer.addSubview(sourceScrollView, positioned: .above, relativeTo: nil)
        sourceScrollView.contentView.scroll(to: .zero)
        sourceScrollView.reflectScrolledClipView(sourceScrollView.contentView)
    }

    private func showImageInspector(_ image: NSImage, metadata: ImageFileMetadata, item: FileItem) {
        hideAllContentViews()
        setDocumentChrome(hidden: true)
        imageInspector.isHidden = false
        imageInspector.configure(item: item, image: image, metadata: metadata)
    }

    private func setDocumentChrome(hidden: Bool) {
        fileIconView.isHidden = hidden
        titleLabel.isHidden = hidden
        subtitleLabel.isHidden = hidden
        topSeparator.isHidden = hidden
        contentContainer.isHidden = hidden
        if hidden {
            modeControl.isHidden = true
            encodingPopup.isHidden = true
        }
    }

    private func setSubtitleVisible(_ visible: Bool) {
        subtitleLabel.isHidden = !visible
        separatorToSubtitle?.isActive = visible
        separatorToTitle?.isActive = !visible
    }

    private func applySourceHighlighting(_ text: String) {
        let appearance = effectiveAppearance
        let fileName = currentItem?.name ?? ""
        let foreground = SourceSyntaxHighlighter.foregroundColor(for: appearance)
        sourceScrollView.backgroundColor = PreviewTheme.sourceEditorBackground
        sourceCanvas.backgroundColor = PreviewTheme.sourceEditorBackground

        let token = UUID()
        highlightToken = token

        if text.count > 60_000 {
            let plain = NSAttributedString(string: text, attributes: [
                .font: PreviewTheme.sourceEditorFont,
                .foregroundColor: foreground
            ])
            installSourceText(plain)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let highlighted = SourceSyntaxHighlighter.highlight(text, fileName: fileName, appearance: appearance)
                DispatchQueue.main.async {
                    guard let self, self.highlightToken == token else { return }
                    self.installSourceText(highlighted)
                }
            }
            return
        }

        installSourceText(SourceSyntaxHighlighter.highlight(text, fileName: fileName, appearance: appearance))
    }

    private func installSourceText(_ text: NSAttributedString) {
        let width = max(sourceScrollView.contentSize.width, sourceScrollView.bounds.width, 1)
        sourceCanvas.display(text, width: width)
        // #region agent log
        let color = text.length > 0 ? text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        let rgb = color?.usingColorSpace(.sRGB)
        AgentDebugLog.write(
            location: "FilePreviewPaneView.installSourceText",
            message: "source canvas installed",
            hypothesisId: "H16",
            data: [
                "chars": text.length,
                "frameW": sourceCanvas.frame.width,
                "frameH": sourceCanvas.frame.height,
                "clipW": sourceScrollView.contentSize.width,
                "boundsW": sourceScrollView.bounds.width,
                "hidden": sourceScrollView.isHidden,
                "red": rgb?.redComponent ?? -1,
                "green": rgb?.greenComponent ?? -1,
                "blue": rgb?.blueComponent ?? -1
            ]
        )
        // #endregion
    }

    private var isLayingOutText = false

    override func layout() {
        super.layout()
        guard !isLayingOutText else { return }
        isLayingOutText = true
        if !sourceScrollView.isHidden, let text = sourceCanvas.attributedText {
            let width = max(sourceScrollView.contentSize.width, sourceScrollView.bounds.width, 1)
            sourceCanvas.display(text, width: width)
        }
        if !renderedScrollView.isHidden {
            layoutRenderedTextView()
        }
        isLayingOutText = false
    }

    private func layoutRenderedTextView() {
        let clipWidth = renderedScrollView.contentSize.width
        let width = max(clipWidth, renderedScrollView.bounds.width)
        guard width > 1, let container = renderedTextView.textContainer, let manager = renderedTextView.layoutManager else { return }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let height = max(ceil(used.height) + renderedTextView.textContainerInset.height * 2 + 16, renderedScrollView.contentSize.height)
        let next = NSRect(x: 0, y: 0, width: width, height: height)
        if abs(renderedTextView.frame.width - next.width) > 0.5 || abs(renderedTextView.frame.height - next.height) > 0.5 {
            renderedTextView.frame = next
        }
        renderedTextView.needsDisplay = true
    }

    private func showSVGPreview(for url: URL, source: String) {
        hideAllContentViews()
        svgImageView.isHidden = false

        if let image = NSImage(contentsOf: url) {
            svgImageView.image = image
            return
        }

        if let data = source.data(using: .utf8), let image = NSImage(data: data) {
            svgImageView.image = image
            return
        }

        placeholderView.configure(
            icon: NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
            title: url.lastPathComponent,
            message: "Unable to display this SVG."
        )
        svgImageView.isHidden = true
        placeholderView.isHidden = false
    }

    private func showSourceText(_ text: String) {
        hideAllContentViews()
        setDocumentChrome(hidden: false)
        setSubtitleVisible(false)
        encodingPopup.isHidden = false
        sourceScrollView.isHidden = false
        layoutSubtreeIfNeeded()
        applySourceHighlighting(text)
        contentContainer.addSubview(sourceScrollView, positioned: .above, relativeTo: nil)
        sourceScrollView.contentView.scroll(to: .zero)
        sourceScrollView.reflectScrolledClipView(sourceScrollView.contentView)
    }

    private func hideAllContentViews() {
        stopMediaPlayer()
        playerView.isHidden = true
        sourceScrollView.isHidden = true
        renderedScrollView.isHidden = true
        imageScrollView.isHidden = true
        svgImageView.isHidden = true
        qlPreviewView?.isHidden = true
        placeholderView.isHidden = true
        imageInspector.isHidden = true
        encodingPopup.isHidden = true
    }

    private func showPlaceholder(message: String) {
        setDocumentChrome(hidden: false)
        setSubtitleVisible(false)
        titleLabel.stringValue = "Inspect"
        subtitleLabel.stringValue = ""
        modeControl.isHidden = true
        fileIconView.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        placeholderView.configure(
            icon: NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil),
            title: "Nothing selected",
            message: message
        )
        hideAllContentViews()
        placeholderView.isHidden = false
    }

    private func showPlaceholderMode() {
        setDocumentChrome(hidden: false)
        modeControl.isHidden = true
        encodingPopup.isHidden = true
        hideAllContentViews()
        placeholderView.isHidden = false
    }
}

private final class PreviewPlaceholderView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.backgroundColor = .clear
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingMiddle

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.backgroundColor = .clear
        messageLabel.alignment = .center

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -28),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(icon: NSImage?, title: String, message: String) {
        iconView.image = icon
        titleLabel.stringValue = title
        messageLabel.stringValue = message
    }
}

struct ImageFileMetadata {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var profileName: String?
}

private final class ImageInspectorView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let imageWell = NSView()
    private let imageView = NSImageView()
    private let dimensionsLabel = NSTextField(labelWithString: "")
    private let profileLabel = NSTextField(labelWithString: "")
    private var displayedImage: NSImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(item: FileItem, image: NSImage, metadata: ImageFileMetadata) {
        iconView.image = FileIconCache.shared.icon(for: item)
        nameLabel.stringValue = item.name

        let width = metadata.pixelWidth ?? Int(image.size.width)
        let height = metadata.pixelHeight ?? Int(image.size.height)
        let dimension = width > 0 && height > 0 ? "\(width)×\(height)" : nil
        let dimensionSpaced = width > 0 && height > 0 ? "\(width) × \(height)" : "—"
        let ext = URL(fileURLWithPath: item.name).pathExtension.uppercased()
        let typeLabel = ext.isEmpty ? item.kind : ext
        let sizeLabel = item.formattedSize == "--" ? nil : item.formattedSize
        detailLabel.stringValue = [dimension, sizeLabel, typeLabel].compactMap { $0 }.joined(separator: "  ·  ")

        dimensionsLabel.stringValue = "Dimensions:  \(dimensionSpaced)"
        let profile = metadata.profileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        profileLabel.stringValue = "Color profile:  \((profile?.isEmpty == false) ? profile! : "—")"

        displayedImage = image
        imageView.image = image
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let image = displayedImage, image.size.width > 0, image.size.height > 0 else { return }
        let available = imageWell.bounds.insetBy(dx: 4, dy: 4)
        guard available.width > 1, available.height > 1 else { return }
        let scale = min(available.width / image.size.width, available.height / image.size.height, 1)
        let size = NSSize(width: max(1, floor(image.size.width * scale)), height: max(1, floor(image.size.height * scale)))
        imageView.frame = NSRect(
            x: imageWell.bounds.midX - size.width / 2,
            y: imageWell.bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.backgroundColor = .clear

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.backgroundColor = .clear

        imageWell.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageWell.addSubview(imageView)

        dimensionsLabel.translatesAutoresizingMaskIntoConstraints = false
        dimensionsLabel.font = .systemFont(ofSize: 12)
        dimensionsLabel.textColor = .secondaryLabelColor
        dimensionsLabel.backgroundColor = .clear

        profileLabel.translatesAutoresizingMaskIntoConstraints = false
        profileLabel.font = .systemFont(ofSize: 12)
        profileLabel.textColor = .secondaryLabelColor
        profileLabel.backgroundColor = .clear

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(imageWell)
        addSubview(dimensionsLabel)
        addSubview(profileLabel)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            nameLabel.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -1),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            imageWell.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            imageWell.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            imageWell.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            imageWell.bottomAnchor.constraint(equalTo: dimensionsLabel.topAnchor, constant: -14),

            dimensionsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dimensionsLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            dimensionsLabel.bottomAnchor.constraint(equalTo: profileLabel.topAnchor, constant: -3),

            profileLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            profileLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            profileLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
    }
}

/// Quick Look does not make this window key, so the first click on a slider would otherwise be discarded.
private enum PreviewFirstMouse {
    static let enable: Void = {
        let block: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
        let implementation = imp_implementationWithBlock(block)
        let types = "c@:@"
        for control in [NSView.self, NSControl.self, NSSlider.self, NSButton.self, NSPopUpButton.self, NSSegmentedControl.self] {
            if class_addMethod(control, #selector(NSView.acceptsFirstMouse(for:)), implementation, types) {
                continue
            }
            var count: UInt32 = 0
            guard let methods = class_copyMethodList(control, &count) else { continue }
            defer { free(methods) }
            for index in 0..<Int(count) where method_getName(methods[index]) == #selector(NSView.acceptsFirstMouse(for:)) {
                method_setImplementation(methods[index], implementation)
            }
        }
    }()
}

/// Quick Look’s remote host composites NSImageView contents, but not NSTextView / drawRect text.
/// Source is therefore rasterized into a bitmap and shown as an image.
private final class SourceCanvasView: NSImageView {
    private(set) var attributedText: NSAttributedString?
    private var fillColor: NSColor = PreviewTheme.sourceEditorBackground
    private let gutterWidth: CGFloat = 44
    private let textInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleNone
        imageAlignment = .alignTopLeft
        animates = false
    }

    required init?(coder: NSCoder) { fatalError() }

    var backgroundColor: NSColor {
        get { fillColor }
        set { fillColor = newValue }
    }

    func display(_ text: NSAttributedString, width: CGFloat) {
        attributedText = text
        let pixelWidth = max(width, 1)
        let usable = max(pixelWidth - gutterWidth - textInset.left - textInset.right, 40)
        let measure = text.boundingRect(
            with: CGSize(width: usable, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = max(ceil(measure.height) + textInset.top + textInset.bottom, 1)
        let size = NSSize(width: pixelWidth, height: height)
        let fill = fillColor
        let gutter = gutterWidth
        let inset = textInset

        let image = NSImage(size: size, flipped: true) { _ in
            fill.setFill()
            NSRect(origin: .zero, size: size).fill()

            PreviewTheme.sourceGutterBackground.setFill()
            NSRect(x: 0, y: 0, width: gutter, height: size.height).fill()
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            let hairline = NSBezierPath()
            hairline.move(to: NSPoint(x: gutter - 0.5, y: 0))
            hairline.line(to: NSPoint(x: gutter - 0.5, y: size.height))
            hairline.lineWidth = 1
            hairline.stroke()

            let textRect = NSRect(
                x: gutter + inset.left,
                y: inset.top,
                width: usable,
                height: max(size.height - inset.top - inset.bottom, 1)
            )
            text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

            let numberAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor(srgbRed: 0.55, green: 0.57, blue: 0.60, alpha: 1)
            ]
            let lines = (text.string as NSString).components(separatedBy: "\n")
            let lineHeight = PreviewTheme.sourceEditorFont.boundingRectForFont.height + 1
            for (index, _) in lines.enumerated() {
                let label = "\(index + 1)" as NSString
                let labelSize = label.size(withAttributes: numberAttrs)
                let point = NSPoint(
                    x: gutter - labelSize.width - 10,
                    y: inset.top + CGFloat(index) * lineHeight
                )
                label.draw(at: point, withAttributes: numberAttrs)
            }
            return true
        }

        self.image = image
        setFrameSize(size)

        let color = text.length > 0 ? text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        let rgb = color?.usingColorSpace(.sRGB)
        // #region agent log
        AgentDebugLog.write(
            location: "SourceCanvasView.display",
            message: "bitmap installed",
            hypothesisId: "H16",
            data: [
                "chars": text.length,
                "frameW": frame.width,
                "frameH": frame.height,
                "imageW": size.width,
                "imageH": size.height,
                "hasImage": self.image != nil,
                "red": rgb?.redComponent ?? -1,
                "green": rgb?.greenComponent ?? -1,
                "blue": rgb?.blueComponent ?? -1
            ]
        )
        // #endregion
    }
}

/// Quick Look’s own video controls are a nested remote view and do not receive clicks.
/// A normal player view keeps the scrubber, volume, and playback buttons in this process.
private final class PreviewPlayerView: AVPlayerView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        controlsStyle = .inline
        videoGravity = .resizeAspect
        showsFullScreenToggleButton = true
        updatesNowPlayingInfoCenter = false
        allowsVideoFrameAnalysis = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// TextKit 2 plus a layer-backed ancestor draws the background and skips glyphs,
/// which leaves line numbers with an empty source pane. Opt into TextKit 1 and
/// draw the glyphs directly.
private final class PreviewTextView: NSTextView {
    convenience init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = false
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        usesAdaptiveColorMappingForDarkAppearance = false
        layoutManager?.allowsNonContiguousLayout = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { false }

    private var drawLogCount = 0

    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground {
            backgroundColor.set()
            dirtyRect.fill()
        }
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -2, dy: -2)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        if drawLogCount < 4 {
            drawLogCount += 1
            let color = (textStorage?.length ?? 0) > 0
                ? textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                : nil
            let rgb = color?.usingColorSpace(.sRGB)
            // #region agent log
            AgentDebugLog.write(
                location: "PreviewTextView.draw",
                message: "draw called",
                hypothesisId: "H1",
                data: [
                    "glyphs": glyphRange.length,
                    "chars": textStorage?.length ?? 0,
                    "dirtyW": dirtyRect.width,
                    "dirtyH": dirtyRect.height,
                    "frameW": frame.width,
                    "frameH": frame.height,
                    "containerW": textContainer.containerSize.width,
                    "textKit2": textLayoutManager != nil,
                    "red": rgb?.redComponent ?? -1,
                    "green": rgb?.greenComponent ?? -1,
                    "blue": rgb?.blueComponent ?? -1
                ]
            )
            // #endregion
        }
        // #region agent log
        if drawLogCount <= 4 {
            AgentDebugLog.write(
                location: "PreviewTextView.draw",
                message: "super.draw",
                hypothesisId: "H10",
                data: ["chars": textStorage?.length ?? 0, "context": NSGraphicsContext.current != nil]
            )
        }
        // #endregion
        super.draw(dirtyRect)
    }
}

