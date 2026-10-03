import Foundation

/// macOS mapping of the six default categories from the fixed upstream
/// `DefaultCategories.kt`: same ids, names, relative folders and extensions;
/// each upstream image URI maps to a native SF Symbol.
public enum DefaultCategories {
    public static func make(downloadRoot: String) -> [DownloadCategory] {
        let values: [(String, String, [String])] = [
            ("Compressed", "archivebox", ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso", "dmg", "tgz"]),
            ("Programs", "app.dashed", ["apk", "exe", "msi", "bat", "sh", "jar", "app", "deb", "rpm", "bin"]),
            ("Videos", "film", ["mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "m4v", "3gp", "mpeg", "ts"]),
            ("Music", "music.note", ["mp3", "wav", "aac", "flac", "ogg", "aiff", "wma", "m4a"]),
            ("Pictures", "photo", ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "svg", "webp", "heic", "ico", "raw", "psd"]),
            ("Documents", "doc.text", ["doc", "docx", "pdf", "txt", "rtf", "odt", "xls", "xlsx", "ppt", "pptx", "csv", "epub", "pages"])
        ]
        return values.enumerated().map { index, value in
            DownloadCategory(
                id: Int64(index),
                name: value.0,
                order: index,
                acceptedFileTypes: value.2,
                categoryPath: URL(fileURLWithPath: downloadRoot, isDirectory: true).appendingPathComponent(value.0, isDirectory: true).path,
                icon: value.1
            )
        }
    }
}
