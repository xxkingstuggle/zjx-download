import Foundation

public enum FileUtilities {
    public static func sanitizedFileName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { throw DownloadEngineError.invalidFileName }
        guard !name.contains("/"), !name.contains(":"), !name.contains("\\"), !name.contains("\0") else {
            throw DownloadEngineError.pathTraversal
        }
        return name
    }

    public static func containedURL(folder: URL, fileName: String) throws -> URL {
        let safeName = try sanitizedFileName(fileName)
        let canonicalFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalFolder.appendingPathComponent(safeName, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == canonicalFolder else { throw DownloadEngineError.pathTraversal }
        return candidate
    }

    public static func resolveConflict(at proposed: URL, policy: FileConflictPolicy, fileManager: FileManager = .default) throws -> URL {
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        switch policy {
        case .overwrite:
            return proposed
        case .skip:
            throw DownloadEngineError.conflictSkipped
        case .rename:
            let directory = proposed.deletingLastPathComponent()
            let ext = proposed.pathExtension
            let base = proposed.deletingPathExtension().lastPathComponent
            for index in 1...10_000 {
                let candidateName = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
                let candidate = directory.appendingPathComponent(candidateName)
                if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
            throw CocoaError(.fileWriteFileExists)
        }
    }

    public static func atomicReplace(source: URL, destination: URL, overwrite: Bool, fileManager: FileManager = .default) throws {
        if overwrite, fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    public static func availableCapacity(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
