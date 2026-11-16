import Foundation

struct DisplayRow: Identifiable {
    let item: FileItem
    let depth: Int
    let isExpanded: Bool

    var id: String { item.id }
}

final class FolderTreeModel {
    private(set) var rootItems: [FileItem] = []
    private(set) var displayRows: [DisplayRow] = []

    private var expandedIDs: Set<String> = []
    private var childrenByID: [String: [FileItem]] = [:]

    private let maxExpandDepth = 7

    func setRootItems(_ items: [FileItem]) {
        rootItems = items
        expandedIDs.removeAll()
        childrenByID.removeAll()
        rebuildDisplayRows()
    }

    /// Expands containers that were loaded off the main thread.
    func installPreloadedChildren(_ children: [String: [FileItem]]) {
        guard !children.isEmpty else { return }
        for (id, kids) in children {
            childrenByID[id] = kids
            expandedIDs.insert(id)
        }
        rebuildDisplayRows()
    }

    func isExpanded(_ itemID: String) -> Bool {
        expandedIDs.contains(itemID)
    }

    enum Toggle {
        case updated
        case needsChildren(FileItem)
    }

    /// Collapses immediately. Expanding a folder whose children are not loaded yet
    /// returns `.needsChildren` so the caller can read the disk off the main thread.
    func toggleFolder(itemID: String) -> Toggle? {
        guard let parentRow = displayRows.firstIndex(where: { $0.item.id == itemID }) else { return nil }

        let row = displayRows[parentRow]
        guard row.item.isContainer else { return nil }

        if expandedIDs.contains(itemID) {
            collapse(itemID: itemID)
            rebuildDisplayRows()
            return .updated
        }

        guard row.depth < maxExpandDepth else { return nil }

        if childrenByID[itemID] == nil {
            return .needsChildren(row.item)
        }

        expandedIDs.insert(itemID)
        rebuildDisplayRows()
        return .updated
    }

    func completeExpansion(of itemID: String, children: [FileItem]) {
        childrenByID[itemID] = children
        expandedIDs.insert(itemID)
        rebuildDisplayRows()
    }

    /// Reads descendant listings without touching model state. Safe to call off the main thread.
    static func preloadedChildren(of items: [FileItem], depth: Int = 0) -> [String: [FileItem]] {
        guard PreviewSettings.expandChildFolders, depth < PreviewSettings.folderDepth else { return [:] }
        var result: [String: [FileItem]] = [:]
        for item in items where item.isContainer {
            let loaded = children(of: item)
            result[item.id] = loaded
            let nested = preloadedChildren(of: loaded, depth: depth + 1)
            for (id, value) in nested {
                result[id] = value
            }
        }
        return result
    }

    static func children(of item: FileItem) -> [FileItem] {
        let children: [FileItem]
        if item.isBrowsableArchive && item.isArchiveEntry {
            guard let nestedArchive = ArchiveContentLoader.extractEntryToTempFile(
                from: item.url,
                path: item.relativePath,
                filename: item.name
            ) else {
                return []
            }
            children = ArchiveContentLoader.loadContents(of: nestedArchive)
        } else if item.isArchiveEntry {
            children = ArchiveContentLoader.loadChildren(in: item.url, relativePath: item.relativePath)
        } else if item.isBrowsableArchive {
            children = ArchiveContentLoader.loadContents(of: item.url)
        } else {
            children = FolderContentLoader.loadImmediateChildren(of: item.url)
        }
        return FolderContentLoader.sorted(children)
    }

    func applySort() {
        rootItems = FolderContentLoader.sorted(rootItems)
        for id in Array(childrenByID.keys) {
            childrenByID[id] = FolderContentLoader.sorted(childrenByID[id] ?? [])
        }
        rebuildDisplayRows()
    }

    var allVisibleItems: [FileItem] {
        displayRows.map(\.item)
    }

    private func collapse(itemID: String) {
        expandedIDs.remove(itemID)

        for id in Array(expandedIDs) where id.hasPrefix(itemID + "/") {
            expandedIDs.remove(id)
            childrenByID.removeValue(forKey: id)
        }
    }

    private func rebuildDisplayRows() {
        var rows: [DisplayRow] = []

        func appendItems(_ items: [FileItem], depth: Int) {
            for item in items {
                let expanded = item.isContainer && expandedIDs.contains(item.id)
                rows.append(DisplayRow(item: item, depth: depth, isExpanded: expanded))

                if expanded, let children = childrenByID[item.id] {
                    appendItems(children, depth: depth + 1)
                }
            }
        }

        appendItems(rootItems, depth: 0)
        displayRows = rows
    }
}
