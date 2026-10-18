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
            if page == .about {
                aboutPage
            } else if page == .translators {
                translatorsPage
            } else {
                licensesPage
            }
            if let linkError { Text(linkError).font(.caption).foregroundStyle(.red) }
            HStack {
                if page != .about { Button("返回", action: { page = .about }) }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 360)
    }

    private var aboutPage: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text(ProductIdentity.name).font(.title2.weight(.semibold))
            Text("版本 \(ProductIdentity.version) · macOS 原生下载器").foregroundStyle(.secondary)
            Text("本 App 和 Chrome 扩展按 Apache-2.0 发布。Chrome 集成保留 AB Download Manager 与原作者 AmirHossein Abdolmotallebi 的署名；本次净室重写不打包第三方运行时库。")
                .font(.callout).multilineTextAlignment(.center).frame(maxWidth: 500)
            HStack(spacing: 14) {
                externalLink("项目网站", "https://abdownloadmanager.com/")
                externalLink("本项目源码", "https://github.com/xxkingstuggle/zjx-download")
                externalLink("上游源码", "https://github.com/amir1376/ab-download-manager")
                externalLink("浏览器扩展源码", "https://github.com/amir1376/ab-download-manager-browser-integration")
            }
            HStack(spacing: 14) {
                externalLink("支持上游项目", "https://github.com/amir1376/ab-download-manager/blob/master/DONATE.md")
                externalLink("Telegram 频道", "https://t.me/abdownloadmanager")
                externalLink("Telegram 讨论组", "https://t.me/abdownloadmanager_discussion")
                externalLink("本项目问题反馈", "https://github.com/xxkingstuggle/zjx-download/issues/new")
            }
            HStack(spacing: 18) {
                Button("翻译者") { page = .translators }
                Button("许可证与依赖") { page = .licenses }
            }
        }
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
            List {
                VStack(alignment: .leading, spacing: 4) {
                    Text("zjx-download App · Apache-2.0").font(.headline)
                    Text("SwiftUI、AppKit、Foundation、Network.framework、Keychain 与 IOKit 均为 macOS 系统框架。")
                        .font(.caption).foregroundStyle(.secondary)
                    externalLink("查看完整许可证", "https://github.com/xxkingstuggle/zjx-download/blob/main/LICENSE")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chrome 扩展 · Apache-2.0").font(.headline)
                    Text("当前扩展为独立重写；打包时不含第三方运行时 npm 包。")
                        .font(.caption).foregroundStyle(.secondary)
                    externalLink("扩展许可证", "https://github.com/xxkingstuggle/zjx-download/blob/main/browser-extension/LICENSE")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("上游署名 · AB Download Manager").font(.headline)
                    Text("保留上游项目及原作者署名。当前重写不包含上游运行时依赖。")
                        .font(.caption).foregroundStyle(.secondary)
                    externalLink("上游项目", "https://github.com/amir1376/ab-download-manager-browser-integration")
                }
            }
            Text("完整许可证文件和构建依赖清单随源码及扩展包提供。")
                .font(.caption).foregroundStyle(.secondary)
        }
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
