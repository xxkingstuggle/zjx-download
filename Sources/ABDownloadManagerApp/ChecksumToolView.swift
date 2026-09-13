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

    var body: some View {
        Form {
            Section("File") {
                HStack { Text(fileURL?.path ?? "No file selected").lineLimit(1); Spacer(); Button("Choose…") { chooseFile() } }
            }
            Picker("Algorithm", selection: $algorithm) { ForEach(ChecksumAlgorithm.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if calculating { ProgressView(value: Double(progress), total: 100).accessibilityLabel("Checksum progress \(progress) percent") }
            if !result.isEmpty { TextField("Checksum", text: $result).textSelection(.enabled); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) } }
            HStack { Spacer(); Button("Close") { dismiss() }; Button("Calculate") { calculate() }.disabled(fileURL == nil || calculating).keyboardShortcut(.defaultAction) }
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
