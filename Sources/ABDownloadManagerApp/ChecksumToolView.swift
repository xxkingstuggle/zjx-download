import SwiftUI
import AppKit
import ABDownloadManagerCore

struct ChecksumToolView: View {
    @State private var fileURL: URL?
    @State private var algorithm: ChecksumAlgorithm = .sha256
    @State private var result = ""
    @State private var progress = 0
    @State private var calculating = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language

    var body: some View {
        Form {
            Section(LocalizedStringKey("checksum.file")) {
                HStack { if let fileURL { Text(fileURL.path).lineLimit(1) } else { Text(LocalizedStringKey("checksum.none")) }; Spacer(); Button(LocalizedStringKey("checksum.choose")) { chooseFile() } }
            }
            Picker(LocalizedStringKey("checksum.algorithm"), selection: $algorithm) { ForEach(ChecksumAlgorithm.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if calculating { ProgressView(value: Double(progress), total: 100).accessibilityLabel(Text(AppLocalization.format("checksum.progress", language: language, progress))) }
            if !result.isEmpty { TextField(LocalizedStringKey("toolbar.checksum"), text: $result).textSelection(.enabled); Button(LocalizedStringKey("checksum.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) } }
            HStack { Spacer(); Button(LocalizedStringKey("checksum.close")) { dismiss() }; Button(LocalizedStringKey("checksum.calculate")) { calculate() }.disabled(fileURL == nil || calculating).keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 620)
    }
    private func chooseFile() { let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; if panel.runModal() == .OK { fileURL = panel.url; result = "" } }
    private func calculate() {
        guard let fileURL else { return }; calculating = true; progress = 0
        let selectedAlgorithm = algorithm
        Task.detached(priority: .userInitiated) {
            do { let value = try ChecksumCalculator.hash(algorithm: selectedAlgorithm, fileURL: fileURL) { value in Task { @MainActor in progress = value } }; await MainActor.run { result = "\(selectedAlgorithm.rawValue):\(value)"; calculating = false; progress = 100 } }
            catch { await MainActor.run { result = error.localizedDescription; calculating = false } }
        }
    }
}
