import AppKit
import UniformTypeIdentifiers

enum FileIconCache {
    static let shared = Cache()

    final class Cache {
        private let cache = NSCache<NSString, NSImage>()

        init() {
            cache.countLimit = 200
        }

        /// Icons are shared by file type. Looking up a custom icon for every path
        /// asks Launch Services once per row and stalls scrolling.
        func icon(for item: FileItem) -> NSImage {
            if item.isDirectory {
                return icon(forKey: "dir") {
                    NSWorkspace.shared.icon(for: .folder)
                }
            }

            let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
            if ext.isEmpty {
                return icon(forKey: "file") {
                    NSWorkspace.shared.icon(for: .data)
                }
            }

            return icon(forKey: "ext:\(ext)") {
                if let type = UTType(filenameExtension: ext) {
                    return NSWorkspace.shared.icon(for: type)
                }
                return NSWorkspace.shared.icon(for: .data)
            }
        }

        func icon(for path: String) -> NSImage {
            let name = (path as NSString).lastPathComponent
            if name.isEmpty {
                return icon(forKey: "file") { NSWorkspace.shared.icon(for: .data) }
            }
            return icon(for: FileItem(
                url: URL(fileURLWithPath: path),
                name: name,
                isDirectory: false,
                size: nil,
                modificationDate: nil,
                creationDate: nil,
                kind: "",
                relativePath: name
            ))
        }

        private func icon(forKey key: String, make: () -> NSImage) -> NSImage {
            let cacheKey = key as NSString
            if let cached = cache.object(forKey: cacheKey) {
                return cached
            }
            let image = make()
            cache.setObject(image, forKey: cacheKey)
            return image
        }
    }
}
