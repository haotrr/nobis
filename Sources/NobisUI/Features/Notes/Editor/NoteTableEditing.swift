import Foundation

extension DocumentBlockBuffer {
    enum TableAction { case rowBefore, rowAfter, deleteRow, rowUp, rowDown, columnBefore, columnAfter, deleteColumn, columnLeft, columnRight }

    func tableCell(_ id: UUID) -> (row: Int, column: Int) {
        guard let focus, focus.target.hasPrefix("\(id)-") else { return (0, 0) }
        let parts = focus.target.dropFirst(id.uuidString.count + 1).split(separator: "-")
        guard parts.count == 2, let row = Int(parts[0]), let column = Int(parts[1]) else { return (0, 0) }
        return (row, column)
    }

    func changeTable(_ id: UUID, action: TableAction) {
        var next = blocks
        guard let index = next.firstIndex(where: { $0.id == id }),
              case .table(var rows, var alignment) = next[index].content,
              let width = rows.first?.count, width > 0 else { return }
        let cell = tableCell(id)
        var row = min(max(0, cell.row), rows.count - 1), column = min(max(0, cell.column), width - 1)
        switch action {
        case .rowBefore, .rowAfter:
            row = max(1, row + (action == .rowAfter ? 1 : 0))
            rows.insert(Array(repeating: "", count: width), at: row)
        case .deleteRow:
            guard row > 0, rows.count > 1 else { return }
            rows.remove(at: row); row = min(row, rows.count - 1)
        case .rowUp, .rowDown:
            let target = row + (action == .rowUp ? -1 : 1)
            guard row > 0, target > 0, target < rows.count else { return }
            rows.swapAt(row, target); row = target
        case .columnBefore, .columnAfter:
            column += action == .columnAfter ? 1 : 0
            for r in rows.indices { rows[r].insert("", at: column) }
            alignment.insert("---", at: column)
        case .deleteColumn:
            guard width > 1 else { return }
            for r in rows.indices { rows[r].remove(at: column) }
            alignment.remove(at: column); column = min(column, width - 2)
        case .columnLeft, .columnRight:
            let target = column + (action == .columnLeft ? -1 : 1)
            guard target >= 0, target < width else { return }
            for r in rows.indices { rows[r].swapAt(column, target) }
            alignment.swapAt(column, target); column = target
        }
        next[index].content = .table(rows: rows, alignment: alignment)
        replace(next, undo: undo, focus: NoteEditorFocus(target: "\(id)-\(row)-\(column)"))
    }
}
