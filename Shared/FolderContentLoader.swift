import Foundation

enum FolderContentLoader {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .contentAccessDateKey,
        .addedToDirectoryDateKey
    ]

    /// Loads only the immediate children of a folder. Used for interactive tree expansion.
    static func loadImmediateChildren(of folderURL: URL) -> [FileItem] {
        sorted(loadSingleDirectory(folderURL, pathPrefix: ""))
    }

    static func loadContents(of folderURL: URL) -> [FileItem] {
        sorted(loadSingleDirectory(folderURL, pathPrefix: ""))
    }

    static func sorted(_ items: [FileItem]) -> [FileItem] {
        guard let column = PreviewColumn(rawValue: PreviewSettings.sortColumnID),
              let sortColumn = PreviewSortColumn(previewColumn: column) else {
            return defaultSorted(items)
        }

        let ascending = PreviewSettings.sortAscending
        return items.sorted { lhs, rhs in
            let result = sortColumn.compare(lhs, rhs)
            if result == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func directoryOptions() -> FileManager.DirectoryEnumerationOptions {
        PreviewSettings.showHiddenFiles ? [] : [.skipsHiddenFiles]
    }

    private static func loadSingleDirectory(_ folderURL: URL, pathPrefix: String) -> [FileItem] {
        let keys = Set(resourceKeys)
        let urls = directoryContents(of: folderURL)
        return urls.compactMap { url -> FileItem? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let relative = pathPrefix.isEmpty ? url.lastPathComponent : "\(pathPrefix)/\(url.lastPathComponent)"
            return FileItem.from(url: url, resourceValues: values, relativePath: relative)
        }
    }

    private static func directoryContents(of folderURL: URL) -> [URL] {
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: directoryOptions()
        ) {
            return urls
        }

        var items: [URL] = []
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: folderURL,
            options: [.withoutChanges],
            error: &coordinatorError
        ) { readURL in
            items = (try? FileManager.default.contentsOfDirectory(
                at: readURL,
                includingPropertiesForKeys: resourceKeys,
                options: directoryOptions()
            )) ?? []
        }
        return items
    }

    private static func defaultSorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if PreviewSettings.keepFoldersOnTop, lhs.isContainer != rhs.isContainer {
                return lhs.isContainer && !rhs.isContainer
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
