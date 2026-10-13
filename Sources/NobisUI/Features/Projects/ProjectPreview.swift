import SwiftUI
import FamilyDomain
import FamilyCore

struct ProjectPreview: View {
    let model: AppModel
    let record: Record
    private var projectContent: [Record] {
        let ids = Set([record.id] + model.activeRecords.filter { $0.body.parentProjectID == record.id }.map(\.id))
        return model.activeRecords.filter { !ids.isDisjoint(with: $0.body.projectIDs) }
    }
    private var tasks: [Record] { projectContent.filter { $0.body.kind == .task && $0.body.status != .cancelled } }
    private var checklist: [NoteChecklistItem] { NoteChecklistItem.items(in: projectContent, includeCompleted: true) }
    private var completed: Int { tasks.filter { $0.body.status == .completed }.count + checklist.filter(\.completed).count }
    private var total: Int { tasks.count + checklist.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                if record.body.isPinned == true { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("置顶") }
                Text(record.body.title).font(.title3.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            ResourceOwnership(model: model, spaceID: record.latest.spaceID)
            if record.conflicted { Label("待核对", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            else if record.body.status != .active { Text(record.body.status.title).font(.caption).foregroundStyle(.secondary) }
            if let parentID = record.body.parentProjectID, let parent = model.activeRecords.first(where: { $0.id == parentID }) { Label(parent.body.title, systemImage: "folder").font(.caption).foregroundStyle(.secondary) }
            if let date = record.body.date { Label(date.description, systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
            if total > 0 {
                ProgressView(value: Double(completed), total: Double(total)).accessibilityHidden(true)
                Text("已完成 \(completed) / \(total) 项待办").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).lifeCard()
            .contentShape(RoundedRectangle(cornerRadius: 26))
    }
}
