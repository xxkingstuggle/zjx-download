import Foundation

/// Strict parsers shared by the paste UI and browser/API adapters. Invalid
/// non-empty lines are reported instead of being silently discarded.
public enum DownloadInputParser {
    public enum InputError: Error, LocalizedError, Equatable, Sendable {
        case noLinks
        case invalidURL(line: Int)
        case invalidHeader(line: Int)
        case duplicateHeader(String)

        public var errorDescription: String? {
            switch self {
            case .noLinks: "Enter at least one download URL."
            case .invalidURL(let line): "Line \(line) is not an HTTP or HTTPS URL."
            case .invalidHeader(let line): "Header line \(line) must use the format Name: value."
            case .duplicateHeader(let name): "Header \(name) is listed more than once."
            }
        }
    }

    public static func links(_ text: String) throws -> [URL] {
        let lines = text.components(separatedBy: .newlines)
        var result: [URL] = []
        for (index, source) in lines.enumerated() {
            let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                throw InputError.invalidURL(line: index + 1)
            }
            result.append(url)
        }
        guard !result.isEmpty else { throw InputError.noLinks }
        return result
    }

    public static func headers(_ text: String) throws -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        var result: [String: String] = [:]
        var normalizedNames: Set<String> = []
        for (index, source) in lines.enumerated() {
            let line = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let separator = line.firstIndex(of: ":") else { throw InputError.invalidHeader(line: index + 1) }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }), !value.contains("\r"), !value.contains("\n") else {
                throw InputError.invalidHeader(line: index + 1)
            }
            let normalized = name.lowercased()
            guard normalizedNames.insert(normalized).inserted else { throw InputError.duplicateHeader(name) }
            result[name] = value
        }
        return result
    }
}
