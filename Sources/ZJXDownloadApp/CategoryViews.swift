import SwiftUI
import AppKit
import ZJXDownloadCore

struct CategoryViews: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: TaskCoordinator
    @State private var editingID: Int64?
    @State private var name = ""
    @State private var symbol = "folder"
    @State private var extensionsText = ""
    @State private var patternsText = ""
    @State private var folder = ""
    @State private var error: String?
    @State private var pendingDelete: Int64?
    @State private var confirmRestore = false

    private var categories: [CategoryRecord] { coordinator.data.categories.sorted { $0.order < $1.order } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("下载分类").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            List {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(category.name, systemImage: category.symbol)
                            Spacer()
                            Button("上移") { reorder(category.id, offset: -1) }.disabled(index == 0)
                            Button("下移") { reorder(category.id, offset: 1) }.disabled(index == categories.count - 1)
                            Button("编辑") { beginEditing(category) }
                            Button("删除", role: .destructive) { pendingDelete = category.id }
                        }
                        Text("扩展名：\(category.extensions.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !category.urlPatterns.isEmpty {
                            Text("URL：\(category.urlPatterns.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let destinationDirectory = category.destinationDirectory {
                            Text(destinationDirectory).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 3)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    TextField("分类名称", text: $name).textFieldStyle(.roundedBorder)
                    TextField("SF Symbol", text: $symbol).textFieldStyle(.roundedBorder).frame(width: 160)
                }
                TextField("扩展名，空格或逗号分隔", text: $extensionsText).textFieldStyle(.roundedBorder)
                TextField("URL 匹配规则，每行一项", text: $patternsText).textFieldStyle(.roundedBorder)
                GridRow {
                    TextField("分类保存目录（可选）", text: $folder).textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseFolder() }
                }
            }
            HStack {
                Button("自动分类未分类任务") { coordinator.autoCategorizeUnassigned() }
                Button("恢复默认分类…") { confirmRestore = true }
                if editingID != nil { Button("取消编辑") { clearDraft() } }
                Spacer()
                Button(editingID == nil ? "新建分类" : "保存分类") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(20).frame(width: 760, height: 650)
        .confirmationDialog("删除分类？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除分类", role: .destructive) {
                if let pendingDelete { coordinator.deleteCategory(pendingDelete) }
                self.pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { Text("只删除分类记录和任务归属，不会删除任务或下载文件。") }
        .confirmationDialog("恢复预置分类？", isPresented: $confirmRestore) {
            Button("替换分类并重新归类", role: .destructive) {
                do { try coordinator.restoreDefaultCategories(); clearDraft() }
                catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("会替换当前分类规则，并按默认扩展名重新归类现有任务；不会移动或删除文件。") }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { folder = panel.url?.path ?? folder }
    }

    private func beginEditing(_ category: CategoryRecord) {
        editingID = category.id
        name = category.name
        symbol = category.symbol
        extensionsText = category.extensions.joined(separator: " ")
        patternsText = category.urlPatterns.joined(separator: "\n")
        folder = category.destinationDirectory ?? ""
        error = nil
    }

    private func save() {
        let exts = extensionsText.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            .filter { !$0.isEmpty }
        let patterns = patternsText.split(whereSeparator: \.isNewline).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let destination = folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : folder
        do {
            if let editingID {
                try coordinator.updateCategory(editingID) {
                    $0.name = name
                    $0.symbol = symbol.isEmpty ? "folder" : symbol
                    $0.extensions = exts
                    $0.urlPatterns = patterns
                    $0.destinationDirectory = destination
                }
            } else {
                _ = try coordinator.createCategory(name: name, symbol: symbol.isEmpty ? "folder" : symbol,
                                                   extensions: exts, patterns: patterns, destination: destination)
            }
            clearDraft()
        } catch { self.error = error.localizedDescription }
    }

    private func reorder(_ id: Int64, offset: Int) {
        var ids = categories.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let destination = index + offset
        guard ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
        do { try coordinator.reorderCategories(ids) } catch { self.error = error.localizedDescription }
    }

    private func clearDraft() {
        editingID = nil; name = ""; symbol = "folder"; extensionsText = ""; patternsText = ""; folder = ""; error = nil
    }
}
