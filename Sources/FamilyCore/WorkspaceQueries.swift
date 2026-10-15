import Foundation
import FamilyDomain

/// A projection of a saved Markdown line, never a second task record.
public struct NoteChecklistItem: Identifiable, Sendable {
    public let document: Record
    public let line: Int
    public let completed: Bool
    public let title: String
    public var id: String { "\(document.id):\(line)" }
    public static func search(_ query: String, in items: [Self]) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            terms.allSatisfy { term in
                item.title.localizedCaseInsensitiveContains(term) || item.document.body.title.localizedCaseInsensitiveContains(term)
            }
        }
    }
    public static func items(in records: [Record], includeCompleted: Bool = false) -> [Self] {
        records.filter { !$0.deleted && !$0.conflicted && $0.body.kind == .document && $0.body.status == .active && $0.body.sharedDestination == nil }.flatMap { document in
            MarkdownBlock.parse(document.body.notes).compactMap { block -> Self? in
                guard case .task(let line, let completed, let title) = block, includeCompleted || !completed else { return nil }
                return Self(document: document, line: line, completed: completed, title: title)
            }
        }
    }
}

public extension FamilyCore {
    @discardableResult func toggleChecklist(_ item: NoteChecklistItem) throws -> Revision {
        let current = try record(item.document.id, spaceID: item.document.latest.spaceID)
        guard !current.deleted, !current.conflicted, current.body.status == .active,
              Set(current.heads.map(\.id)) == Set(item.document.heads.map(\.id)) else { throw NobisError.conflict }
        guard let text = MarkdownBlock.togglingTask(in: current.body.notes, line: item.line) else { throw NobisError.conflict }
        var body = current.body; body.notes = text
        return try save(body, spaceID: current.latest.spaceID, recordID: current.id, expected: Set(current.heads.map(\.id)))
    }
}

public enum WorkspaceQuery {
    public static func search(_ query: String, in records: [Record]) -> [Record] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return records.filter { record in
            !record.deleted && record.body.sharedDestination == nil && record.body.kind != .comment &&
            terms.allSatisfy { term in [record.body.title, record.body.notes, record.body.noteGroup ?? "", record.body.kind.title].contains { $0.localizedCaseInsensitiveContains(term) } }
        }
    }
    public static func occurs(_ record: Record, on day: LocalDay, timeZone: TimeZone = .current) -> Bool {
        guard !record.deleted, record.body.sharedDestination == nil, record.body.status == .active else { return false }
        let b = record.body
        if b.kind == .event {
            if b.allDay { guard let start = b.date else { return false }; return start <= day && day <= (b.endDate ?? start) }
            guard let start = b.startAt, let end = b.endAt else { return false }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            let lower = calendar.startOfDay(for: day.date(timeZone: timeZone))
            guard let upper = calendar.date(byAdding: .day, value: 1, to: lower) else { return false }
            return start < upper && end > lower
        }
        return [.task, .subscription].contains(b.kind) && b.date == day
    }
}
