import SwiftUI
import AppKit
import ABDownloadManagerCore

struct ChecksumToolView: View {
    @State private var fileURLs: [URL]
    @State private var selectedFileURL: URL?
    @State private var algorithm: ChecksumAlgorithm = .sha256
    @State private var results: [URL: String] = [:]
    @State private var progress = 0
    @State private var calculating = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language

    init(initialFileURLs: [URL] = []) {
        _fileURLs = State(initialValue: initialFileURLs)
        _selectedFileURL = State(initialValue: initialFileURLs.first)
    }

    private var resultText: String {
        fileURLs.compactMap { url in
            results[url].map { "\(url.lastPathComponent): \($0)" }
        }.joined(separator: "\n")
    }

    var body: some View {
        Form {
            Section(LocalizedStringKey("checksum.file")) {
                if fileURLs.count > 1 {
                    Picker(LocalizedStringKey("checksum.file"), selection: $selectedFileURL) {
                        ForEach(fileURLs, id: \.self) { url in Text(url.lastPathComponent).tag(Optional(url)) }
                    }
                }
                if let selectedFileURL { Text(selectedFileURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                else { Text(LocalizedStringKey("checksum.none")) }
                Button(LocalizedStringKey("checksum.choose")) { chooseFile() }
            }
            Picker(LocalizedStringKey("checksum.algorithm"), selection: $algorithm) { ForEach(ChecksumAlgorithm.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if calculating { ProgressView(value: Double(progress), total: 100).accessibilityLabel(Text(AppLocalization.format("checksum.progress", language: language, progress))) }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(fileURLs.filter { results[$0] != nil }, id: \.self) { url in
                        Text("\(url.lastPathComponent): \(results[url] ?? "")").textSelection(.enabled)
                    }
                }
                Button(LocalizedStringKey("checksum.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(resultText, forType: .string)
                }
            }
            HStack { Spacer(); Button(LocalizedStringKey("checksum.close")) { dismiss() }; Button(LocalizedStringKey("checksum.calculate")) { calculate() }.disabled(selectedFileURL == nil || calculating).keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 620)
    }
    private func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            fileURLs = [url]
            selectedFileURL = url
            results.removeAll()
        }
    }
    private func calculate() {
        guard let fileURL = selectedFileURL else { return }; calculating = true; progress = 0
        let selectedAlgorithm = algorithm
        Task.detached(priority: .userInitiated) {
            do {
                let value = try ChecksumCalculator.hash(algorithm: selectedAlgorithm, fileURL: fileURL) { value in Task { @MainActor in progress = value } }
                await MainActor.run { results[fileURL] = "\(selectedAlgorithm.rawValue):\(value)"; calculating = false; progress = 100 }
            } catch { await MainActor.run { results[fileURL] = error.localizedDescription; calculating = false } }
        }
    }
}
