import AppKit
import ABDownloadManagerCore

@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let onLinks: @MainActor ([String]) -> Void

    init(onLinks: @escaping @MainActor ([String]) -> Void) { self.onLinks = onLinks }
    func start() { guard timer == nil else { return }; timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } } }
    func stop() { timer?.invalidate(); timer = nil }
    private func check() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string) else { return }
        let links = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { value -> String? in
            guard let url = URL(string: String(value)), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return url.absoluteString
        }
        if !links.isEmpty { onLinks(links) }
    }
}
