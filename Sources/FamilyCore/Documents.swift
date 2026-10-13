import Foundation
import FamilyDomain

public extension FamilyCore {
    /// Replies point to a root comment; roots point to the document, always in the same space.
    func documentComments(_ documentID: UUID, spaceID: UUID) throws -> [Record] {
        let document = try record(documentID, spaceID: spaceID)
        guard document.body.kind == .document, !document.deleted else { throw NobisError.notFound }
        let comments = try records(spaceID: spaceID).filter { $0.body.kind == .comment }
        let roots = Set(comments.filter { $0.body.relatedRecordID == documentID }.map(\.id))
        return comments.filter { $0.body.relatedRecordID == documentID || $0.body.relatedRecordID.map(roots.contains) == true }
            .sorted { $0.latest.createdAt < $1.latest.createdAt }
    }
}

extension FamilyCore {
    func validateDocument(_ body: RecordBody, current: Record?, spaceID: UUID, deleted: Bool) throws {
        guard body.kind == .comment else {
            guard body.documentQuote == nil else { throw NobisError.validation("引用原文仅用于文档评注。") }
            return
        }
        guard !deleted, !body.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.notes.count <= 4_000, (body.documentQuote?.count ?? 0) <= 2_000,
              body.projectIDs.isEmpty, body.sharedDestination == nil,
              let targetID = body.relatedRecordID else { throw NobisError.validation("评注须关联文档，内容为 1–4,000 字，引用最多 2,000 字。评注保留历史，不支持删除。") }
        let target = try record(targetID, spaceID: spaceID)
        var document = target
        if target.body.kind == .comment {
            guard !target.deleted, !target.conflicted, target.body.status == .active,
                  let documentID = target.body.relatedRecordID else { throw NobisError.validation("请重新打开评注后回复。") }
            document = try record(documentID, spaceID: spaceID)
            guard body.documentQuote == nil, body.status == .active else { throw NobisError.validation("回复不能单独解决或添加引用。") }
        }
        guard document.body.kind == .document, !document.deleted, !document.conflicted,
              document.body.sharedDestination == nil else { throw NobisError.validation("文档不可用或需要先核对冲突。") }
        if let current {
            // Text and attribution stay immutable; any writer can resolve or reopen a root thread.
            var comparable = body
            comparable.status = current.body.status
            guard comparable == current.body else { throw NobisError.validation("已发布评注不可改写，请添加回复。") }
        } else {
            guard body.status == .active else { throw NobisError.validation("新评注须为未解决状态。") }
            if let quote = body.documentQuote {
                guard !quote.isEmpty, document.body.notes.contains(quote) else { throw NobisError.validation("引用须来自当前文档原文，请重新复制。") }
            }
        }
    }
}
