import SwiftUI
import AppKit
import ZJXDownloadCore

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .about
    @State private var linkError: String?

    private enum Page { case about, translators, licenses }

    var body: some View {
        VStack(spacing: 14) {
            ScrollView {
                if page == .about {
                    aboutPage
                } else if page == .translators {
                    translatorsPage
                } else {
                    licensesPage
                }
            }
            if let linkError { Text(linkError).font(.caption).foregroundStyle(.red) }
            HStack {
                if page != .about { Button("返回", action: { page = .about }) }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 410, idealHeight: 450)
    }

    private var aboutPage: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text(ProductIdentity.name).font(.title2.weight(.semibold))
            Text("版本 \(ProductIdentity.version) · macOS 原生下载器").foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("重构作者：张家鑫 · Xin (@xxkingstuggle)")
                    .font(.subheadline.weight(.semibold))
                Text("© 2026 Xin (@xxkingstuggle) · Apache-2.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    brandPill("官方网站 myzjx.com", symbol: "globe", url: "https://myzjx.com", prominent: true)
                    brandPill("产品主页", symbol: "sparkles", url: "https://myzjx.com/software/zjx-download/", prominent: false)
                    brandPill("GitHub @xxkingstuggle", symbol: "chevron.left.forwardslash.chevron.right", url: "https://github.com/xxkingstuggle", prominent: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 510)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )

            Text("本 App 和 Chrome 扩展按 Apache-2.0 发布。Chrome 集成严格保留上游 AB Download Manager 与原作者 AmirHossein Abdolmotallebi 的署名；本次净室重写不打包第三方运行时库。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            HStack(spacing: 14) {
                externalLink("本项目源码", "https://github.com/xxkingstuggle/zjx-download")
                externalLink("本项目问题反馈", "https://github.com/xxkingstuggle/zjx-download/issues/new")
                externalLink("上游网站", "https://abdownloadmanager.com/")
                externalLink("上游源码", "https://github.com/amir1376/ab-download-manager")
            }
            HStack(spacing: 14) {
                externalLink("上游浏览器扩展", "https://github.com/amir1376/ab-download-manager-browser-integration")
                externalLink("支持上游项目", "https://github.com/amir1376/ab-download-manager/blob/master/DONATE.md")
                externalLink("Telegram 频道", "https://t.me/abdownloadmanager")
                externalLink("Telegram 讨论组", "https://t.me/abdownloadmanager_discussion")
            }
            HStack(spacing: 18) {
                Button("翻译者") { page = .translators }
                Button("许可证与依赖") { page = .licenses }
            }
        }
    }

    private func brandPill(_ title: String, symbol: String, url rawURL: String, prominent: Bool) -> some View {
        Button {
            guard let url = URL(string: rawURL), NSWorkspace.shared.open(url) else {
                linkError = "无法使用系统默认浏览器打开链接。"
                return
            }
            linkError = nil
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Color.accentColor : Color.secondary.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .help(rawURL)
    }

    private var translatorsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("翻译者").font(.title2.bold())
            Text("此净室版本目前提供简体中文界面。没有本项目已核实的翻译者姓名可列，因此保留项目与上游的公开贡献入口，不猜测或复制未经确认的署名。")
                .fixedSize(horizontal: false, vertical: true)
            Text("上游翻译工作由 Crowdin 项目维护；上游代码贡献者名单可在 GitHub 查看。本项目的翻译与署名更正可通过本项目问题页反馈。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            externalLink("上游翻译项目", "https://crowdin.com/project/ab-download-manager")
            externalLink("查看上游贡献者", "https://github.com/amir1376/ab-download-manager/graphs/contributors")
            externalLink("提交本项目翻译或署名反馈", "https://github.com/xxkingstuggle/zjx-download/issues/new?title=Translation%20feedback")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var licensesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("许可证与依赖").font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                licenseCard(
                    title: "zjx-download App · Apache-2.0",
                    summary: "SwiftUI、AppKit、Foundation、Network.framework、Keychain 与 IOKit 均为 macOS 系统框架。",
                    linkTitle: "查看完整许可证",
                    linkURL: "https://github.com/xxkingstuggle/zjx-download/blob/main/LICENSE"
                )
                licenseCard(
                    title: "Chrome 扩展 · Apache-2.0",
                    summary: "当前扩展为独立重写；打包时不含第三方运行时 npm 包。",
                    linkTitle: "扩展许可证",
                    linkURL: "https://github.com/xxkingstuggle/zjx-download/blob/main/browser-extension/LICENSE"
                )
                licenseCard(
                    title: "上游署名 · AB Download Manager",
                    summary: "保留上游项目及原作者署名。当前重写不包含上游运行时依赖。",
                    linkTitle: "上游项目",
                    linkURL: "https://github.com/amir1376/ab-download-manager-browser-integration"
                )
            }
            Text("完整许可证文件和构建依赖清单随源码及扩展包提供。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func licenseCard(title: String, summary: String, linkTitle: String, linkURL: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            externalLink(linkTitle, linkURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }

    private func externalLink(_ title: String, _ rawURL: String) -> some View {
        Button(title) {
            guard let url = URL(string: rawURL), NSWorkspace.shared.open(url) else {
                linkError = "无法使用系统默认浏览器打开链接。"
                return
            }
            linkError = nil
        }
        .buttonStyle(.link)
    }
}
