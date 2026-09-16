import Foundation

/// Persists security-scoped bookmarks separately from user-facing paths. The
/// caller must keep the returned URL's access scope open while using it.
public actor FolderBookmarkStore {
    private let fileURL: URL
    private var bookmarks: [String: Data]

    public init(directory: URL? = nil) throws {
        let base = directory ?? AppStateStore.defaultDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("folder-bookmarks.json")
        if let data = try? Data(contentsOf: fileURL), let values = try? JSONDecoder().decode([String: Data].self, from: data) { bookmarks = values } else { bookmarks = [:] }
    }

    public func store(url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        bookmarks[url.standardizedFileURL.path] = data
        try persist()
    }

    public func contains(path: String) -> Bool { bookmarks[path] != nil }

    public func resolve(path: String) throws -> URL {
        guard let data = bookmarks[path] else { return URL(fileURLWithPath: path) }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { try store(url: url) }
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        return url
    }

    public func remove(path: String) throws { bookmarks.removeValue(forKey: path); try persist() }

    private func persist() throws { try JSONEncoder().encode(bookmarks).write(to: fileURL, options: .atomic) }
}
