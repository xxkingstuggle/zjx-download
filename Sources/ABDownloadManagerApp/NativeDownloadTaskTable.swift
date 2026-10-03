import AppKit
import SwiftUI
import ABDownloadManagerCore

@MainActor
struct NativeDownloadTaskTable: NSViewRepresentable {
    let model: AppModel
    let tasks: [DownloadTask]
    let projectionRevision: UInt64
    let progressRevision: UInt64
    let sortField: String
    let sortAscending: Bool
    let visibleColumnIDs: Set<String>
    let columnWidths: [String: CGFloat]
    let onSort: (String, Bool) -> Void
    let onColumnResize: (String, CGFloat) -> Void

    static let rowHeight: CGFloat = 44

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let table = NativeTaskNSTableView(frame: .zero)
        table.headerView = NSTableHeaderView()
        table.usesAutomaticRowHeights = false
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .controlBackgroundColor
        table.setAccessibilityLabel(AppLocalization.string("downloads.active", language: model.settings.language))
        table.registerForDraggedTypes([.URL, .string, .fileURL])

        for definition in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.id))
            column.title = AppLocalization.string(definition.titleKey, language: model.settings.language)
            column.minWidth = definition.minimumWidth
            column.maxWidth = definition.maximumWidth
            column.width = columnWidths[definition.id] ?? definition.defaultWidth
            column.resizingMask = .userResizingMask
            if definition.sortField != nil {
                column.sortDescriptorPrototype = NSSortDescriptor(key: definition.sortField, ascending: false)
            }
            table.addTableColumn(column)
        }

        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.doubleAction = #selector(Coordinator.openSelectedTask(_:))
        table.target = context.coordinator
        table.contextMenuProvider = { [weak coordinator = context.coordinator] ids in
            coordinator?.makeContextMenu(for: ids)
        }
        table.deleteSelection = { [weak model] in _ = model?.requestDeleteConfirmation() }
        table.newFromClipboard = { [weak model] in model?.beginNewDownload(prefillFromClipboard: true) }
        table.clearSelection = { [weak model] in model?.clearSelection() }
        table.dropLinks = { [weak coordinator = context.coordinator] text in
            coordinator?.addDroppedLinks(text)
        }
        scrollView.documentView = table
        context.coordinator.tableView = table
        context.coordinator.update(from: self)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NativeTaskNSTableView else { return }
        context.coordinator.tableView = table
        context.coordinator.update(from: self)
    }

    fileprivate static let columns: [ColumnDefinition] = [
        .init(id: "selection", titleKey: "task.select", minimumWidth: 38, defaultWidth: 42, maximumWidth: 56, sortField: nil),
        .init(id: "fileName", titleKey: "task.file", minimumWidth: 200, defaultWidth: 215, maximumWidth: 600, sortField: "fileName"),
        .init(id: "downloadedSize", titleKey: "task.size", minimumWidth: 115, defaultWidth: 115, maximumWidth: 280, sortField: "downloadedSize"),
        .init(id: "status", titleKey: "task.status", minimumWidth: 105, defaultWidth: 110, maximumWidth: 260, sortField: "status"),
        .init(id: "speed", titleKey: "task.speed", minimumWidth: 95, defaultWidth: 95, maximumWidth: 200, sortField: nil),
        .init(id: "timeRemaining", titleKey: "task.remaining", minimumWidth: 95, defaultWidth: 95, maximumWidth: 180, sortField: nil),
        .init(id: "createdAt", titleKey: "date_added", minimumWidth: 110, defaultWidth: 115, maximumWidth: 260, sortField: "createdAt"),
        .init(id: "startedAt", titleKey: "task.startedDate", minimumWidth: 140, defaultWidth: 170, maximumWidth: 260, sortField: "startedAt"),
        .init(id: "completedAt", titleKey: "task.finishedDate", minimumWidth: 140, defaultWidth: 170, maximumWidth: 260, sortField: "completedAt"),
        .init(id: "connectionCount", titleKey: "task.connections", minimumWidth: 90, defaultWidth: 110, maximumWidth: 150, sortField: "connectionCount"),
    ]

    fileprivate struct ColumnDefinition {
        let id: String
        let titleKey: String
        let minimumWidth: CGFloat
        let defaultWidth: CGFloat
        let maximumWidth: CGFloat
        let sortField: String?
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: NativeDownloadTaskTable
        fileprivate weak var tableView: NativeTaskNSTableView?
        private var lastProjectionRevision: UInt64?
        private var lastProgressRevision: UInt64?
        private var lastSelection = Set<Int64>()
        private var lastVisibleColumnIDs = Set<String>()
        private var lastColumnWidths: [String: CGFloat] = [:]
        private var lastLanguage = ""
        private var lastSort = (field: "", ascending: false)
        private var suppressSelectionCallback = false
        private var activeMenuSelection = Set<Int64>()

        init(_ parent: NativeDownloadTaskTable) { self.parent = parent }

        func update(from parent: NativeDownloadTaskTable) {
            self.parent = parent
            guard let tableView else { return }
            tableView.usesAutomaticRowHeights = false
            tableView.rowHeight = NativeDownloadTaskTable.rowHeight

            if lastLanguage != parent.model.settings.language {
                for definition in NativeDownloadTaskTable.columns {
                    tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.id))?.title = AppLocalization.string(definition.titleKey, language: parent.model.settings.language)
                }
                tableView.setAccessibilityLabel(AppLocalization.string("downloads.active", language: parent.model.settings.language))
                lastLanguage = parent.model.settings.language ?? ""
            }

            if lastVisibleColumnIDs != parent.visibleColumnIDs {
                for definition in NativeDownloadTaskTable.columns {
                    tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.id))?.isHidden = !parent.visibleColumnIDs.contains(definition.id)
                }
                lastVisibleColumnIDs = parent.visibleColumnIDs
            }

            if lastColumnWidths != parent.columnWidths {
                for definition in NativeDownloadTaskTable.columns {
                    guard let width = parent.columnWidths[definition.id], let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.id)), abs(column.width - width) > 0.5 else { continue }
                    column.width = width
                }
                lastColumnWidths = parent.columnWidths
            }

            if lastSort.field != parent.sortField || lastSort.ascending != parent.sortAscending {
                if NativeDownloadTaskTable.columns.contains(where: { $0.sortField == parent.sortField }) {
                    tableView.sortDescriptors = [NSSortDescriptor(key: parent.sortField, ascending: parent.sortAscending)]
                } else {
                    tableView.sortDescriptors = []
                }
                lastSort = (parent.sortField, parent.sortAscending)
            }

            if lastProjectionRevision != parent.projectionRevision {
                // NSTableView selection is stored as row indexes. A sort
                // changes which task each index represents, and a reload can
                // clear the native selection before the model update arrives.
                // Suppress that transient callback, then rebuild selected row
                // indexes from stable task IDs so sorting keeps the same tasks
                // selected while filters still prune hidden IDs in AppModel.
                let wasSuppressingSelectionCallback = suppressSelectionCallback
                suppressSelectionCallback = true
                tableView.reloadData()
                suppressSelectionCallback = wasSuppressingSelectionCallback
                synchronizeSelection()
                lastProjectionRevision = parent.projectionRevision
            } else if lastProgressRevision != parent.progressRevision {
                let rows = tableView.rows(in: tableView.visibleRect)
                if rows.location != NSNotFound, rows.length > 0 {
                    let columns = IndexSet(integersIn: 0..<tableView.numberOfColumns)
                    tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)), columnIndexes: columns)
                }
            }
            lastProgressRevision = parent.progressRevision

            if lastSelection != parent.model.selectedIDs {
                synchronizeSelection()
                let visibleRows = tableView.rows(in: tableView.visibleRect)
                let selectionColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("selection"))
                if visibleRows.location != NSNotFound, visibleRows.length > 0, selectionColumn >= 0 {
                    tableView.reloadData(forRowIndexes: IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)), columnIndexes: IndexSet(integer: selectionColumn))
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.tasks.count }

        func rowID(at index: Int) -> Int64? {
            parent.tasks.indices.contains(index) ? parent.tasks[index].id : nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.tasks.indices.contains(row), let tableColumn else { return nil }
            let task = parent.tasks[row]
            let columnID = tableColumn.identifier.rawValue
            let reuseID = NSUserInterfaceItemIdentifier("native-task-cell.\(columnID)")
            let cell = (tableView.makeView(withIdentifier: reuseID, owner: self) as? NativeTaskCellView) ?? NativeTaskCellView(identifier: reuseID, columnID: columnID)
            cell.configure(task: task, columnID: columnID, model: parent.model)
            if columnID == "selection" {
                cell.selectionHandler = { [weak self] id, selected in self?.setSelection(id, selected: selected) }
            }
            return cell
        }

        private func setSelection(_ id: Int64, selected: Bool) {
            var ids = parent.model.selectedIDs
            if selected { ids.insert(id) } else { ids.remove(id) }
            parent.model.replaceSelection(ids, preferredPrimary: selected ? id : nil)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback, let tableView else { return }
            var ids = Set<Int64>()
            for row in tableView.selectedRowIndexes where parent.tasks.indices.contains(row) { ids.insert(parent.tasks[row].id) }
            let clicked = tableView.clickedRow
            let primary = parent.tasks.indices.contains(clicked) ? parent.tasks[clicked].id : nil
            parent.model.replaceSelection(ids, preferredPrimary: primary)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
                  NativeDownloadTaskTable.columns.contains(where: { $0.sortField == key }) else { return }
            parent.onSort(key, descriptor.ascending)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
            parent.onColumnResize(column.identifier.rawValue, column.width)
        }

        @objc func openSelectedTask(_ sender: Any?) {
            guard let tableView, parent.tasks.indices.contains(tableView.clickedRow) else { return }
            let task = parent.tasks[tableView.clickedRow]
            Task { await parent.model.openTask(task) }
        }

        func makeContextMenu(for ids: Set<Int64>) -> NSMenu? {
            guard !ids.isEmpty else { return nil }
            activeMenuSelection = ids
            let menu = NSMenu()
            let selectedTasks = parent.tasks.filter { ids.contains($0.id) }
            if ids.count == 1, let task = selectedTasks.first, task.status == .completed {
                menu.addItem(item("task.open", #selector(openContextTask(_:))))
                menu.addItem(item("task.reveal", #selector(revealTasks(_:))))
                menu.addItem(.separator())
            }
            if ids.count == 1, selectedTasks.first?.canEdit == true {
                menu.addItem(item("task.edit", #selector(editTask(_:))))
                menu.addItem(.separator())
            }
            if !selectedTasks.isEmpty && selectedTasks.allSatisfy({ $0.status == .completed }) {
                menu.addItem(item("commands.redownload", #selector(redownloadTasks(_:))))
                menu.addItem(.separator())
            }
            menu.addItem(item("selection.start", #selector(startTasks(_:))))
            menu.addItem(item("selection.pause", #selector(pauseTasks(_:))))
            menu.addItem(item("selection.retry", #selector(retryTasks(_:))))
            menu.addItem(.separator())
            menu.addItem(item("commands.copyURLs", #selector(copyURLs(_:))))
            menu.addItem(item("commands.copyCurl", #selector(copyCurl(_:))))
            menu.addItem(item("commands.copyJSON", #selector(copyJSON(_:))))
            if parent.model.hasChecksumFiles(ids: ids) {
                menu.addItem(item("commands.checksumSelected", #selector(checksumTasks(_:))))
            }
            menu.addItem(queueMenu())
            menu.addItem(categoryMenu())
            menu.addItem(.separator())
            menu.addItem(item("selection.cancel", #selector(cancelTasks(_:))))
            menu.addItem(item("common.delete", #selector(deleteTasks(_:))))
            return menu
        }

        private func item(_ key: String, _ action: Selector) -> NSMenuItem {
            let result = NSMenuItem(title: AppLocalization.string(key, language: parent.model.settings.language), action: action, keyEquivalent: "")
            result.target = self
            return result
        }

        private func queueMenu() -> NSMenuItem {
            let parentItem = NSMenuItem(title: AppLocalization.string("commands.moveToQueue", language: parent.model.settings.language), action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: parentItem.title)
            for queue in parent.model.queues {
                let child = NSMenuItem(title: queue.name, action: #selector(moveToQueue(_:)), keyEquivalent: "")
                child.target = self
                child.representedObject = NSNumber(value: queue.id)
                submenu.addItem(child)
            }
            parentItem.submenu = submenu
            parentItem.isEnabled = !parent.model.queues.isEmpty
            return parentItem
        }

        private func categoryMenu() -> NSMenuItem {
            let parentItem = NSMenuItem(title: AppLocalization.string("commands.moveToCategory", language: parent.model.settings.language), action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: parentItem.title)
            for category in parent.model.categories {
                let child = NSMenuItem(title: category.name, action: #selector(moveToCategory(_:)), keyEquivalent: "")
                child.target = self
                child.representedObject = NSNumber(value: category.id)
                submenu.addItem(child)
            }
            parentItem.submenu = submenu
            parentItem.isEnabled = !parent.model.categories.isEmpty
            return parentItem
        }

        private func synchronizeSelection() {
            guard let tableView else { return }
            var rows = IndexSet()
            for (index, task) in parent.tasks.enumerated() where parent.model.selectedIDs.contains(task.id) { rows.insert(index) }
            if rows != tableView.selectedRowIndexes {
                let wasSuppressingSelectionCallback = suppressSelectionCallback
                suppressSelectionCallback = true
                tableView.selectRowIndexes(rows, byExtendingSelection: false)
                suppressSelectionCallback = wasSuppressingSelectionCallback
            }
            lastSelection = parent.model.selectedIDs
        }

        func addDroppedLinks(_ text: String) {
            Task { await parent.model.addLinks(text, folder: parent.model.settings.defaultDownloadFolder, start: false) }
        }

        @objc private func startTasks(_ sender: Any?) { let ids = activeMenuSelection; Task { await parent.model.start(ids: ids) } }
        @objc private func pauseTasks(_ sender: Any?) { let ids = activeMenuSelection; Task { await parent.model.pause(ids: ids) } }
        @objc private func retryTasks(_ sender: Any?) { let ids = activeMenuSelection; Task { await parent.model.retry(ids: ids) } }
        @objc private func cancelTasks(_ sender: Any?) { let ids = activeMenuSelection; Task { await parent.model.cancel(ids: ids) } }
        @objc private func copyURLs(_ sender: Any?) { parent.model.copyURLs(ids: activeMenuSelection) }
        @objc private func copyCurl(_ sender: Any?) { let ids = activeMenuSelection; Task { await parent.model.copyCurl(ids: ids) } }
        @objc private func copyJSON(_ sender: Any?) { parent.model.copyTaskJSON(ids: activeMenuSelection) }
        @objc private func redownloadTasks(_ sender: Any?) { let ids = activeMenuSelection; Task { await parent.model.redownload(ids: ids) } }
        @objc private func checksumTasks(_ sender: Any?) { parent.model.showChecksumForSelection(ids: activeMenuSelection) }
        @objc private func editTask(_ sender: Any?) { parent.model.requestEdit(ids: activeMenuSelection) }
        @objc private func revealTasks(_ sender: Any?) { parent.model.revealTasks(ids: activeMenuSelection) }
        @objc private func deleteTasks(_ sender: Any?) { _ = parent.model.requestDeleteConfirmation(ids: activeMenuSelection) }
        @objc private func openContextTask(_ sender: Any?) {
            guard let id = activeMenuSelection.first, let task = parent.tasks.first(where: { $0.id == id }) else { return }
            Task { await parent.model.openTask(task) }
        }
        @objc private func moveToQueue(_ sender: NSMenuItem) {
            guard let id = (sender.representedObject as? NSNumber)?.int64Value else { return }
            Task { await parent.model.move(ids: activeMenuSelection, queueID: id, categoryID: nil, movingQueue: true) }
        }
        @objc private func moveToCategory(_ sender: NSMenuItem) {
            guard let id = (sender.representedObject as? NSNumber)?.int64Value else { return }
            Task { await parent.model.move(ids: activeMenuSelection, queueID: nil, categoryID: id, movingQueue: false) }
        }
    }
}

@MainActor
private final class NativeTaskNSTableView: NSTableView {
    var contextMenuProvider: ((Set<Int64>) -> NSMenu?)?
    var dropLinks: ((String) -> Void)?
    var deleteSelection: (() -> Void)?
    var newFromClipboard: (() -> Void)?
    var clearSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if command, characters == "a" {
            selectAll(nil)
            return
        }
        if command, characters == "v" {
            newFromClipboard?()
            return
        }
        if event.keyCode == 53 {
            deselectAll(nil)
            clearSelection?()
            return
        }
        if event.keyCode == 51, modifiers.isEmpty {
            deleteSelection?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let coordinator = delegate as? NativeDownloadTaskTable.Coordinator else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let ids = Set(selectedRowIndexes.compactMap { index in
            coordinator.rowID(at: index)
        })
        return contextMenuProvider?(ids)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        return types.contains(.URL) || types.contains(.string) || types.contains(.fileURL) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let text = pasteboard.string(forType: .URL)
            ?? pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: .fileURL)
        guard let text, !text.isEmpty else { return false }
        dropLinks?(text)
        return true
    }
}

@MainActor
private final class NativeTaskCellView: NSTableCellView {
    private let icon = NSImageView(frame: .zero)
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator(frame: .zero)
    private let selectionButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let stack = NSStackView()
    private let columnID: String
    private var taskID: Int64 = 0
    var selectionHandler: ((Int64, Bool) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier, columnID: String) {
        self.columnID = columnID
        super.init(frame: .zero)
        self.identifier = identifier
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch columnID {
        case "selection":
            selectionButton.target = self
            selectionButton.action = #selector(toggleSelection(_:))
            selectionButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(selectionButton)
            NSLayoutConstraint.activate([
                selectionButton.centerXAnchor.constraint(equalTo: centerXAnchor),
                selectionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        case "fileName":
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(subtitle)
            addSubview(icon)
            addSubview(stack)
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        case "status":
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.style = .bar
            progress.controlSize = .mini
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(progress)
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        default:
            addSubview(title)
            title.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        textField = columnID == "selection" ? nil : title
    }

    required init?(coder: NSCoder) { nil }

    func configure(task: DownloadTask, columnID: String, model: AppModel) {
        taskID = task.id
        let language = model.settings.language
        switch columnID {
        case "selection":
            selectionButton.state = model.selectedIDs.contains(task.id) ? .on : .off
            selectionButton.setAccessibilityLabel("\(AppLocalization.string("task.select", language: language)) \(task.fileName)")
            selectionButton.setAccessibilityIdentifier("download-selection-\(task.id)")
            setAccessibilityLabel("\(AppLocalization.string("task.select", language: language)) \(task.fileName)")
        case "fileName":
            let host = task.source.url.host ?? task.source.url.absoluteString
            title.stringValue = task.fileName
            subtitle.stringValue = host
            title.setAccessibilityLabel(task.fileName)
            subtitle.setAccessibilityLabel(host)
            icon.image = NSImage(systemSymbolName: statusSymbol(task.status), accessibilityDescription: localizedStatus(task.status, language: language))
            icon.contentTintColor = task.status == .failed ? .systemRed : task.status == .completed ? .systemGreen : .controlAccentColor
            setAccessibilityLabel("\(task.fileName), \(host), \(localizedStatus(task.status, language: language))")
        case "status":
            title.stringValue = localizedStatus(task.status, language: language)
            progress.doubleValue = task.progress
            title.setAccessibilityLabel("\(title.stringValue), \(Int(task.progress * 100))%")
            progress.setAccessibilityLabel("\(Int(task.progress * 100))%")
            setAccessibilityLabel("\(title.stringValue), \(Int(task.progress * 100))%")
        case "downloadedSize":
            title.stringValue = task.totalSize.map {
                "\(ByteDisplayFormatter.string(task.downloadedSize, unit: model.settings.sizeUnit)) / \(ByteDisplayFormatter.string($0, unit: model.settings.sizeUnit))"
            } ?? ByteDisplayFormatter.string(task.downloadedSize, unit: model.settings.sizeUnit)
            setAccessibilityLabel(title.stringValue)
        case "connectionCount":
            title.stringValue = "\(task.connectionCount)"
            setAccessibilityLabel(AppLocalization.string("task.connections", language: language) + " \(title.stringValue)")
        case "createdAt":
            let locale = appDateLocale(language)
            title.stringValue = model.settings.useRelativeDateTime
                ? task.createdAt.formatted(.relative(presentation: .named).locale(locale))
                : task.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
            setAccessibilityLabel(title.stringValue)
        case "startedAt":
            title.stringValue = task.startedAt.map { formatDate($0, settings: model.settings) } ?? "—"
            setAccessibilityLabel("\(AppLocalization.string("task.startedDate", language: language)): \(title.stringValue)")
        case "completedAt":
            title.stringValue = task.completedAt.map { formatDate($0, settings: model.settings) } ?? "—"
            setAccessibilityLabel("\(AppLocalization.string("task.finishedDate", language: language)): \(title.stringValue)")
        case "timeRemaining":
            title.stringValue = model.progress[task.id]?.eta.map(formatDuration) ?? "—"
            setAccessibilityLabel("\(AppLocalization.string("task.remaining", language: language)): \(title.stringValue)")
        case "speed":
            let instant = model.progress[task.id]?.bytesPerSecond ?? 0
            let average = task.startedAt.map { Double(task.downloadedSize) / max(0.001, Date().timeIntervalSince($0)) } ?? instant
            let speed = model.settings.useAverageSpeed ? average : instant
            title.stringValue = ByteDisplayFormatter.string(Int64(max(0, speed)), unit: model.settings.speedUnit, suffix: "/s")
            setAccessibilityLabel(title.stringValue)
        default:
            title.stringValue = ""
            setAccessibilityLabel("")
        }
        toolTip = task.source.url.absoluteString
    }

    private func statusSymbol(_ status: DownloadStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        default: "arrow.down.circle"
        }
    }

    private func localizedStatus(_ status: DownloadStatus, language: String?) -> String {
        let key: String = switch status {
        case .created: "status.created"
        case .downloading: "status.downloading"
        case .paused: "status.paused"
        case .completed: "status.completed"
        case .failed: "status.failed"
        case .stopped: "status.stopped"
        case .cancelled: "status.cancelled"
        case .merging: "status.merging"
        }
        return AppLocalization.string(key, language: language)
    }

    @objc private func toggleSelection(_ sender: NSButton) {
        selectionHandler?(taskID, sender.state == .on)
    }

    private func formatDate(_ date: Date, settings: AppSettings) -> String {
        let locale = appDateLocale(settings.language)
        return settings.useRelativeDateTime
            ? date.formatted(.relative(presentation: .named).locale(locale))
            : date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(remainder)s" }
        return "\(remainder)s"
    }
}

private func appDateLocale(_ language: String?) -> Locale {
    Locale(identifier: SupportedAppLanguage.foundationIdentifier(for: language ?? SupportedAppLanguage.defaultCode))
}
