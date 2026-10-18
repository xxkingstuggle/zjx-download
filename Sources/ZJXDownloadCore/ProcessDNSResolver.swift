import Foundation

@_silgen_name("zjx_apply_process_doh")
private func applyProcessDoH(_ url: UnsafePointer<CChar>) -> Int32

@_silgen_name("zjx_disable_process_doh")
private func disableProcessDoH()

/// Applies DNS policy only to this app process. It never changes macOS system DNS.
public enum ProcessDNSResolver {
    @discardableResult
    public static func apply(mode: DNSMode, dohURL: String) -> String? {
        guard mode == .doh else {
            disableProcessDoH()
            return nil
        }
        guard let url = URL(string: dohURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            disableProcessDoH()
            return "DoH 地址必须是有效的 HTTPS URL；当前已回退到系统 DNS。"
        }
        let result = url.absoluteString.withCString(applyProcessDoH)
        guard result == 1 else {
            disableProcessDoH()
            return "无法应用 DoH 服务地址；当前已回退到系统 DNS。"
        }
        return nil
    }
}
