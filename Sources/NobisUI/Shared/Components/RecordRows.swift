import SwiftUI
import FamilyDomain
import FamilyCore

extension RecordKind: Identifiable { public var id: String { rawValue } }
struct TaskRow: View {
    let model: AppModel; let record: Record
    var inheritedSpaceID: UUID? = nil
    var body: some View {
        HStack {
            Button { model.changeStatus(record, to: record.body.status == .completed ? .active : .completed) } label: { Image(systemName: record.body.status == .completed ? "checkmark.circle.fill" : "circle").font(.title3).touchTarget() }.buttonStyle(.plain).accessibilityLabel("\(record.body.status == .completed ? "重新打开任务" : "完成任务")：\(record.body.title)").disabled(record.conflicted)
            RecordLink(model: model, record: record) { RecordRow(model: model, record: record, showIcon: false, inheritedSpaceID: inheritedSpaceID) }.buttonStyle(.plain)
        }
    }
}
struct RecordRow: View {
    let model: AppModel
    let record: Record
    var showIcon = true
    var inheritedSpaceID: UUID? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var textSize
    private var showsOwnership: Bool { inheritedSpaceID != record.latest.spaceID || model.space(for: record) == nil }
    private var showsStatus: Bool {
        record.body.status != .active && record.body.status != .confirmed
            && !(record.body.kind == .task && record.body.status == .completed && !showIcon)
    }
    private var stacked: Bool { horizontalSizeClass == .compact || textSize.isAccessibilitySize }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if showIcon { Image(systemName: record.body.kind.icon).font(.title3).foregroundStyle(.secondary).frame(width: 28).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 5) {
                Text(record.body.title).font(.body).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .strikethrough(record.body.kind == .task && record.body.status == .completed)
                if showsOwnership || record.conflicted || showsStatus || record.body.date != nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { metadata }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 4) { metadata }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if record.body.kind == .transaction {
                    Text(transactionSummary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !record.body.notes.isEmpty {
                        Text(record.body.notes).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                    }
                }
                if stacked { amount }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !stacked { amount }
            #if os(macOS)
            if record.body.kind == .project { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true) }
            #endif
        }.padding(.vertical, 14).contentShape(Rectangle())
    }
    private var transactionSummary: String {
        let body = record.body
        var parts = [body.transactionKind.title, body.category].filter { !$0.isEmpty }
        for id in body.projectIDs {
            parts.append(model.ledgerIndex.recordsByID[id]?.body.title ?? "项目不可用")
        }
        if let finance = body.finance {
            if finance.consumption == .personal { parts.append("消费：" + finance.consumer) }
            else if finance.consumption == .family { parts.append("家庭消费") }
            if !finance.originalRecorder.isEmpty { parts.append("记录：" + finance.originalRecorder) }
        }
        if body.subscriptionID != nil && body.category != "订阅" { parts.append("订阅") }
        if !body.account.isEmpty && body.account != "默认账户" { parts.append(body.account) }
        return parts.joined(separator: " · ")
    }
    @ViewBuilder private var metadata: some View {
        if showsOwnership {
            ResourceOwnership(model: model, spaceID: record.latest.spaceID)
        }
        if record.conflicted {
            Label("待核对", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if showsStatus {
            Text(record.body.status.title)
        }
        if let date = record.body.date { Text(date.description) }
    }
    @ViewBuilder private var amount: some View {
        if let money = record.body.money {
            Text(money.formatted).monospacedDigit().font(.callout).fixedSize(horizontal: false, vertical: true)
        } else if record.body.kind == .subscription {
            Text("\(record.body.unknownPriceCurrency?.rawValue ?? "") 价格待核实").font(.caption).foregroundStyle(.secondary)
        }
    }
}
