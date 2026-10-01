import AppKit
import MicPriorityCore
import SwiftUI

// AppKit owns gap insertion, scrolling and drag cancellation; ordering commits only on drop.
struct PriorityTable: NSViewRepresentable {
    @ObservedObject var controller: InputController
    let row: (SavedInput, Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 56
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.verticalMotionCanBeginDrag = true
        table.setAccessibilityLabel("麦克风优先级，可拖动排序")
        table.focusRingType = .none
        table.draggingDestinationFeedbackStyle = .gap
        table.registerForDraggedTypes([Coordinator.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("priority"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.dragging { context.coordinator.table?.reloadData() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let dragType = NSPasteboard.PasteboardType("com.local.MicPriority.priorityUID")
        var parent: PriorityTable
        weak var table: NSTableView?
        var dragging = false
        private var draggedUIDs: [String] = []
        init(_ parent: PriorityTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.controller.preferences.priorities.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let saved = parent.controller.preferences.priorities[row]
            return NSHostingView(rootView: parent.row(saved, row).frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard !parent.controller.configurationBlocked else { return nil }
            let item = NSPasteboardItem()
            item.setString(parent.controller.preferences.priorities[row].uid, forType: Self.dragType)
            return item
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            dragging = true
            draggedUIDs = parent.controller.preferences.priorities.map(\.uid)
            session.animatesToStartingPositionsOnCancelOrFail = true
            if let index = rowIndexes.first {
                let name = parent.controller.name(draggedUIDs[index])
                let preview = NSImage(size: NSSize(width: 240, height: 34), flipped: false) { bounds in
                    NSColor.controlBackgroundColor.setFill()
                    NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
                    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
                    ("\(index + 1)   \(name)" as NSString).draw(in: bounds.insetBy(dx: 12, dy: 9), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: style
                    ])
                    return true
                }
                session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                    item.setDraggingFrame(NSRect(origin: item.draggingFrame.origin, size: preview.size), contents: preview)
                }
            }
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            draggedUIDs = []
            tableView.reloadData()
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource as? NSTableView === tableView, !parent.controller.configurationBlocked,
                  draggedUIDs == parent.controller.preferences.priorities.map(\.uid),
                  info.draggingPasteboard.string(forType: Self.dragType) != nil,
                  (0...numberOfRows(in: tableView)).contains(row) else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard self.tableView(tableView, validateDrop: info, proposedRow: row, proposedDropOperation: dropOperation) == .move,
                  let uid = info.draggingPasteboard.string(forType: Self.dragType),
                  let index = parent.controller.preferences.priorities.firstIndex(where: { $0.uid == uid }) else { return false }
            parent.controller.move(from: IndexSet(integer: index), to: row)
            return true
        }
    }
}

struct InputRadio: NSViewRepresentable {
    let selected: Bool
    let enabled: Bool
    let label: String
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.choose))
        button.setButtonType(.radio)
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.state = selected ? .on : .off
        button.isEnabled = enabled
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }
    @MainActor final class Coordinator: NSObject {
        var parent: InputRadio
        init(_ parent: InputRadio) { self.parent = parent }
        @objc func choose(_ sender: NSButton) {
            sender.state = parent.selected ? .on : .off
            parent.action()
        }
    }
}
