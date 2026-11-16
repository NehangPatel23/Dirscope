import Foundation

enum ArchiveContentLoader {
    private struct ListingEntry {
        let path: String
        let size: Int64?
        let modificationDate: Date?
        let isDirectory: Bool

        var normalizedPath: String { normalizeEntryPath(path) }
    }

    private struct ListingCacheEntry {
        let fileSize: Int64?
        let modificationDate: TimeInterval?
        let entries: [ListingEntry]
    }

    private static var listingCache: [String: ListingCacheEntry] = [:]
    private static let listingCacheLock = NSLock()

    static func isArchive(_ url: URL) -> Bool {
        archiveFormat(for: url) != .unsupported
    }

    static func loadContents(of archiveURL: URL) -> [FileItem] {
        let entries = listArchiveEntries(in: archiveURL)
        guard !entries.isEmpty else { return [] }

        let metadata = metadataLookup(for: entries)
        let paths = entries.map(\.path)

        let rollup = rollupFolders(entries)
        if let rootPrefix = singleRootFolderPrefix(in: paths) {
            return FolderContentLoader.sorted(
                buildChildItems(
                    from: paths,
                    archiveURL: archiveURL,
                    relativePath: rootPrefix,
                    metadata: metadata,
                    rollup: rollup
                )
            )
        }

        return FolderContentLoader.sorted(
            buildTopLevelItems(
                from: paths,
                archiveURL: archiveURL,
                metadata: metadata,
                rollup: rollup
            )
        )
    }

    static func loadChildren(in archiveURL: URL, relativePath: String) -> [FileItem] {
        let entries = listArchiveEntries(in: archiveURL)
        let metadata = metadataLookup(for: entries)
        let rollup = rollupFolders(entries)
        return FolderContentLoader.sorted(
            buildChildItems(
                from: entries.map(\.path),
                archiveURL: archiveURL,
                relativePath: relativePath,
                metadata: metadata,
                rollup: rollup
            )
        )
    }

    static func extractEntryData(from archiveURL: URL, path: String) -> Data? {
        switch archiveFormat(for: archiveURL) {
        case .zip:
            return ZipEntryExtractor.extract(from: archiveURL, path: path)
        case .tar:
            return TarEntryExtractor.extract(from: archiveURL, path: path)
        case .gzipSingle:
            return GzipExtractor.extract(from: archiveURL)
        case .sevenZip, .rar:
            guard let tool = ExternalArchiveTool.sevenZipExecutable else { return nil }
            return SevenZipEntryExtractor.extract(from: archiveURL, path: path, tool: tool)
        case .unsupported:
            return nil
        }
    }

    static func extractEntryToTempFile(from archiveURL: URL, path: String, filename: String) -> URL? {
        guard let data = extractEntryData(from: archiveURL, path: path), !data.isEmpty else { return nil }
        return writeEntryDataToTempFile(data, filename: filename)
    }

    static func writeEntryDataToTempFile(_ data: Data, filename: String) -> URL? {
        writeExtractedData(
            data,
            filename: filename,
            uniqueName: true,
            preferUserAccessibleLocation: false
        )
    }

    /// Extracts an archive entry to a location other apps can read when opened via Launch Services.
    static func extractEntryForExternalOpen(from archiveURL: URL, path: String, filename: String) -> URL? {
        guard let data = extractEntryData(from: archiveURL, path: path), !data.isEmpty else { return nil }
        return writeExtractedData(
            data,
            filename: filename,
            uniqueName: false,
            preferUserAccessibleLocation: true,
            adjacentTo: archiveURL
        )
    }

    private static func writeExtractedData(
        _ data: Data,
        filename: String,
        uniqueName: Bool,
        preferUserAccessibleLocation: Bool,
        adjacentTo archiveURL: URL? = nil
    ) -> URL? {
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let fileName = uniqueName ? "\(UUID().uuidString)_\(safeName)" : safeName

        let tempDir: URL
        if preferUserAccessibleLocation,
           let archiveURL,
           let externalDir = externalOpenDirectory(adjacentTo: archiveURL) {
            tempDir = externalDir
        } else {
            let folderName = preferUserAccessibleLocation ? "DirscopeOpen" : "DirscopePreview"
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(folderName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }

        let tempURL = tempDir.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try data.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            return nil
        }
    }

    private static func externalOpenDirectory(adjacentTo archiveURL: URL) -> URL? {
        if let replacementDir = try? FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: archiveURL,
            create: true
        ) {
            return replacementDir
        }

        let parent = archiveURL.deletingLastPathComponent()
        let openDir = parent.appendingPathComponent(".dirscope-open", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: openDir, withIntermediateDirectories: true)
            if FileManager.default.isWritableFile(atPath: openDir.path) {
                return openDir
            }
        } catch {
            return nil
        }

        return nil
    }

    private enum ArchiveFormat {
        case zip
        case tar
        case gzipSingle
        case sevenZip
        case rar
        case unsupported
    }

    private static func archiveFormat(for url: URL) -> ArchiveFormat {
        let path = url.path.lowercased()
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "zip":
            return .zip
        case "tar":
            return .tar
        case "tgz":
            return .tar
        case "gz" where path.hasSuffix(".tar.gz"):
            return .tar
        case "gz":
            return .gzipSingle
        case "bz2" where path.hasSuffix(".tar.bz2"):
            return .tar
        case "xz" where path.hasSuffix(".tar.xz"):
            return .tar
        case "7z":
            return .sevenZip
        case "rar":
            return .rar
        default:
            return .unsupported
        }
    }

    private static func listArchiveEntries(in archiveURL: URL) -> [ListingEntry] {
        let cacheKey = archiveURL.standardizedFileURL.path
        let resourceValues = try? archiveURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = resourceValues?.fileSize.map { Int64($0) }
        let modificationDate = resourceValues?.contentModificationDate?.timeIntervalSince1970

        listingCacheLock.lock()
        if let cached = listingCache[cacheKey],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate {
            let entries = cached.entries
            listingCacheLock.unlock()
            return entries
        }
        listingCacheLock.unlock()

        let entries: [ListingEntry]
        switch archiveFormat(for: archiveURL) {
        case .zip:
            entries = listZipEntries(in: archiveURL)
        case .tar:
            entries = listTarEntries(in: archiveURL)
        case .gzipSingle:
            entries = [listingEntryWithoutMetadata(gzipSingleEntryName(for: archiveURL))]
        case .sevenZip, .rar:
            guard let tool = ExternalArchiveTool.sevenZipExecutable else { return [] }
            entries = SevenZipEntryLister.listEntries(in: archiveURL, tool: tool).map(listingEntryWithoutMetadata)
        case .unsupported:
            return []
        }

        listingCacheLock.lock()
        listingCache[cacheKey] = ListingCacheEntry(
            fileSize: fileSize,
            modificationDate: modificationDate,
            entries: entries
        )
        listingCacheLock.unlock()

        return entries
    }

    private static func listZipEntries(in archiveURL: URL) -> [ListingEntry] {
        if let data = ArchiveSandboxAccess.readData(from: archiveURL) {
            let infos = ZipArchiveReader.listEntryInfos(in: data)
            if !infos.isEmpty {
                return infos.map { info in
                    ListingEntry(
                        path: info.path,
                        size: info.isDirectory ? nil : info.uncompressedSize,
                        modificationDate: info.modificationDate,
                        isDirectory: info.isDirectory
                    )
                }
            }
        }

        return ZipEntryLister.listEntries(in: archiveURL).map(listingEntryWithoutMetadata)
    }

    private static func listTarEntries(in archiveURL: URL) -> [ListingEntry] {
        if let data = TarArchiveReader.payload(from: archiveURL) {
            let infos = TarArchiveReader.listEntryInfos(in: data)
            if !infos.isEmpty {
                return infos.map { info in
                    ListingEntry(
                        path: info.path,
                        size: info.isDirectory ? nil : info.uncompressedSize,
                        modificationDate: info.modificationDate,
                        isDirectory: info.isDirectory
                    )
                }
            }
        }

        return TarEntryLister.listEntries(in: archiveURL).map(listingEntryWithoutMetadata)
    }

    private static func listingEntryWithoutMetadata(_ path: String) -> ListingEntry {
        ListingEntry(
            path: path,
            size: nil,
            modificationDate: nil,
            isDirectory: path.hasSuffix("/")
        )
    }

    private static func metadataLookup(for entries: [ListingEntry]) -> [String: ListingEntry] {
        Dictionary(entries.map { ($0.normalizedPath, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private struct FolderRollup {
        var totalSize: Int64 = 0
        var latestDate: Date?
    }

    /// One pass over the archive. Each file's size and date are added to every parent folder.
    private static func rollupFolders(_ entries: [ListingEntry]) -> [String: FolderRollup] {
        var rollup: [String: FolderRollup] = [:]
        rollup.reserveCapacity(entries.count)
        for entry in entries where !entry.isDirectory {
            let parts = entry.normalizedPath.split(separator: "/")
            guard parts.count > 1 else { continue }
            var prefix = ""
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + String(part)
                var bucket = rollup[prefix] ?? FolderRollup()
                if let size = entry.size {
                    bucket.totalSize += size
                }
                if let date = entry.modificationDate, bucket.latestDate.map({ date > $0 }) ?? true {
                    bucket.latestDate = date
                }
                rollup[prefix] = bucket
            }
        }
        return rollup
    }

    private static func resolvedMetadata(
        for relativePath: String,
        isDirectory: Bool,
        metadata: [String: ListingEntry],
        rollup: [String: FolderRollup]
    ) -> (size: Int64?, modificationDate: Date?) {
        if isDirectory {
            return folderMetadata(for: relativePath, metadata: metadata, rollup: rollup)
        }

        guard let entry = metadata[normalizeEntryPath(relativePath)] else {
            return (nil, nil)
        }
        return (entry.size, entry.modificationDate)
    }

    private static func folderMetadata(
        for relativePath: String,
        metadata: [String: ListingEntry],
        rollup: [String: FolderRollup]
    ) -> (size: Int64?, modificationDate: Date?) {
        let key = normalizeEntryPath(relativePath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let aggregate = rollup[key]
        let explicitDate = metadata[key]?.modificationDate ?? metadata["\(key)/"]?.modificationDate
        let latestDate = [explicitDate, aggregate?.latestDate].compactMap { $0 }.max()
        let totalSize = aggregate?.totalSize ?? 0
        return (totalSize > 0 ? totalSize : nil, latestDate)
    }

    private static func gzipSingleEntryName(for archiveURL: URL) -> String {
        let name = archiveURL.lastPathComponent
        if name.lowercased().hasSuffix(".gz"), name.count > 3 {
            return String(name.dropLast(3))
        }
        return name
    }

    private static func buildTopLevelItems(
        from entries: [String],
        archiveURL: URL,
        metadata: [String: ListingEntry],
        rollup: [String: FolderRollup]
    ) -> [FileItem] {
        var topLevelNames = Set<String>()
        var items: [FileItem] = []

        for entry in entries {
            let normalized = normalizeEntryPath(entry)
            let parts = normalized.split(separator: "/").map(String.init)
            guard let first = parts.first else { continue }

            if parts.count == 1 {
                let isDir = normalized.hasSuffix("/")
                let name = first
                guard !topLevelNames.contains(name) else { continue }
                topLevelNames.insert(name)
                let relativePath = isDir ? "\(name)/" : name
                let entryMeta = resolvedMetadata(
                    for: relativePath,
                    isDirectory: isDir,
                    metadata: metadata,
                    rollup: rollup
                )
                items.append(makeArchiveItem(
                    archiveURL: archiveURL,
                    name: name,
                    relativePath: relativePath,
                    isDirectory: isDir,
                    size: entryMeta.size,
                    modificationDate: entryMeta.modificationDate
                ))
            } else if !topLevelNames.contains(first) {
                topLevelNames.insert(first)
                let relativePath = "\(first)/"
                let entryMeta = folderMetadata(for: relativePath, metadata: metadata, rollup: rollup)
                items.append(makeArchiveItem(
                    archiveURL: archiveURL,
                    name: first,
                    relativePath: relativePath,
                    isDirectory: true,
                    size: entryMeta.size,
                    modificationDate: entryMeta.modificationDate
                ))
            }
        }

        return items
    }

    private static func buildChildItems(
        from entries: [String],
        archiveURL: URL,
        relativePath: String,
        metadata: [String: ListingEntry],
        rollup: [String: FolderRollup]
    ) -> [FileItem] {
        let prefix = relativePath.hasSuffix("/") ? relativePath : relativePath + "/"
        var childNames = Set<String>()
        var items: [FileItem] = []

        for entry in entries {
            let normalized = normalizeEntryPath(entry)
            guard normalized.hasPrefix(prefix) else { continue }

            let remainder = String(normalized.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }

            let parts = remainder.split(separator: "/").map(String.init)
            guard let first = parts.first else { continue }

            if parts.count == 1 {
                let isDir = remainder.hasSuffix("/")
                let name = first
                guard !childNames.contains(name) else { continue }
                childNames.insert(name)
                let path = prefix + (isDir ? "\(name)/" : name)
                let entryMeta = resolvedMetadata(
                    for: path,
                    isDirectory: isDir,
                    metadata: metadata,
                    rollup: rollup
                )
                items.append(makeArchiveItem(
                    archiveURL: archiveURL,
                    name: name,
                    relativePath: path,
                    isDirectory: isDir,
                    size: entryMeta.size,
                    modificationDate: entryMeta.modificationDate
                ))
            } else if !childNames.contains(first) {
                childNames.insert(first)
                let relativePath = prefix + first + "/"
                let entryMeta = folderMetadata(for: relativePath, metadata: metadata, rollup: rollup)
                items.append(makeArchiveItem(
                    archiveURL: archiveURL,
                    name: first,
                    relativePath: relativePath,
                    isDirectory: true,
                    size: entryMeta.size,
                    modificationDate: entryMeta.modificationDate
                ))
            }
        }

        return items
    }

    private static func normalizeEntryPath(_ entry: String) -> String {
        var path = entry
        if path.hasPrefix("./") {
            path = String(path.dropFirst(2))
        }
        return path
    }

    private static func singleRootFolderPrefix(in entries: [String]) -> String? {
        let normalized = entries.map(normalizeEntryPath)
        guard let first = normalized.first else { return nil }

        let parts = first.split(separator: "/").map(String.init)
        guard let root = parts.first, !root.isEmpty else { return nil }

        let prefix = "\(root)/"
        let wrapped = normalized.allSatisfy { entry in
            entry == root || entry == prefix || entry.hasPrefix(prefix)
        }
        return wrapped ? prefix : nil
    }

    private static func makeArchiveItem(
        archiveURL: URL,
        name: String,
        relativePath: String,
        isDirectory: Bool,
        size: Int64?,
        modificationDate: Date?
    ) -> FileItem {
        FileItem(
            url: archiveURL,
            name: name,
            isDirectory: isDirectory,
            size: size,
            modificationDate: modificationDate,
            creationDate: nil,
            kind: FileKindLabel.label(isDirectory: isDirectory, fileName: name),
            relativePath: relativePath,
            isArchiveEntry: true
        )
    }
}

private enum ExternalArchiveTool {
    static var sevenZipExecutable: URL? {
        if let bundled = bundledSevenZipExecutable() {
            return bundled
        }

        let candidates = [
            "/opt/homebrew/bin/7zz",
            "/opt/homebrew/bin/7z",
            "/usr/local/bin/7zz",
            "/usr/local/bin/7z"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func bundledSevenZipExecutable() -> URL? {
        let fileManager = FileManager.default

        if let resourceURL = Bundle.main.url(forResource: "7zz", withExtension: nil),
           fileManager.isExecutableFile(atPath: resourceURL.path) {
            return resourceURL
        }

        let hostAppResources = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Contents/Resources/7zz")
        if fileManager.isExecutableFile(atPath: hostAppResources.path) {
            return hostAppResources
        }

        return nil
    }
}

private enum ProcessRunner {
    static func run(executable: URL, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return stdout.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return nil
        }
    }

    static func runLines(executable: URL, arguments: [String]) -> [String] {
        guard let data = run(executable: executable, arguments: arguments) else { return [] }
        let output = String(data: data, encoding: .utf8) ?? ""
        return output
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }
}

enum ZipEntryLister {
    static func listEntries(in zipURL: URL) -> [String] {
        if let data = ArchiveSandboxAccess.readData(from: zipURL) {
            let paths = ZipArchiveReader.listEntryPaths(in: data)
            if !paths.isEmpty { return paths }
        }

        guard let localURL = ArchiveSandboxAccess.localReadableCopy(of: zipURL) else { return [] }

        let unzipEntries = ProcessRunner.runLines(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", localURL.path]
        )
        if !unzipEntries.isEmpty { return unzipEntries }

        return ProcessRunner.runLines(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tf", localURL.path]
        )
    }
}

private enum ZipEntryExtractor {
    static func extract(from zipURL: URL, path: String) -> Data? {
        if let data = ArchiveSandboxAccess.readData(from: zipURL),
           let extracted = ZipArchiveReader.extractEntry(path: path, from: data) {
            return extracted
        }

        guard let localURL = ArchiveSandboxAccess.localReadableCopy(of: zipURL) else { return nil }

        return ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", localURL.path, path]
        )
    }
}

private enum TarEntryLister {
    static func listEntries(in archiveURL: URL) -> [String] {
        if let data = TarArchiveReader.payload(from: archiveURL) {
            let paths = TarArchiveReader.listEntryPaths(in: data)
            if !paths.isEmpty { return paths }
        }

        guard let localURL = ArchiveSandboxAccess.localReadableCopy(of: archiveURL) else { return [] }
        return ProcessRunner.runLines(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tf", localURL.path]
        )
    }
}

private enum TarEntryExtractor {
    static func extract(from archiveURL: URL, path: String) -> Data? {
        if let data = TarArchiveReader.payload(from: archiveURL),
           let extracted = TarArchiveReader.extractEntry(path: path, from: data) {
            return extracted
        }

        guard let localURL = ArchiveSandboxAccess.localReadableCopy(of: archiveURL) else { return nil }
        return ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xOf", localURL.path, path]
        )
    }
}

private enum GzipExtractor {
    static func extract(from archiveURL: URL) -> Data? {
        if let raw = ArchiveSandboxAccess.readData(from: archiveURL),
           let decompressed = TarArchiveReader.gunzip(raw) {
            return decompressed
        }

        guard let localURL = ArchiveSandboxAccess.localReadableCopy(of: archiveURL) else { return nil }
        return ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/gzip"),
            arguments: ["-dc", localURL.path]
        )
    }
}

private enum SevenZipEntryLister {
    static func listEntries(in archiveURL: URL, tool: URL) -> [String] {
        guard let localURL = ArchiveSandboxAccess.localReadableCopy(of: archiveURL) else { return [] }
        let lines = ProcessRunner.runLines(
            executable: tool,
            arguments: ["l", "-slt", localURL.path]
        )

        var entries: [String] = []
        for line in lines {
            guard line.hasPrefix("Path = ") else { continue }
            let path = String(line.dropFirst("Path = ".count))
            if path != archiveURL.lastPathComponent {
                entries.append(path)
            }
        }
        return entries
    }
}

private enum SevenZipEntryExtractor {
    static func extract(from archiveURL: URL, path: String, tool: URL) -> Data? {
        guard let localURL = ArchiveSandboxAccess.localReadableCopy(of: archiveURL) else { return nil }
        return ProcessRunner.run(
            executable: tool,
            arguments: ["e", "-so", localURL.path, path]
        )
    }
}
