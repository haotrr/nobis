import SwiftUI
import FamilyDomain
import FamilyCore

extension RecordKind: Identifiable { public var id: String { rawValue } }
struct TaskRow: View {
    let model: AppModel; let record: Record
    var body: some View {
        HStack {
            Button { model.changeStatus(record, to: record.body.status == .completed ? .active : .completed) } label: { Image(systemName: record.body.status == .completed ? "checkmark.circle.fill" : "circle").font(.title3).touchTarget() }.buttonStyle(.plain).accessibilityLabel("\(record.body.status == .completed ? "重新打开任务" : "完成任务")：\(record.body.title)").disabled(record.conflicted)
            RecordLink(model: model, record: record) { RecordRow(model: model, record: record, showIcon: false) }.buttonStyle(.plain)
        }
    }
}
struct RecordRow: View {
    let model: AppModel
    let record: Record
    var showIcon = true
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var textSize
    private var stacked: Bool { horizontalSizeClass == .compact || textSize.isAccessibilitySize }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if showIcon { Image(systemName: record.body.kind.icon).font(.title3).foregroundStyle(.secondary).frame(width: 28).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 5) {
                Text(record.body.title).font(.body).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .strikethrough(record.body.kind == .task && record.body.status == .completed)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metadata }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 4) { metadata }
                }.font(.caption).foregroundStyle(.secondary)
                if stacked { amount }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !stacked { amount }
            #if os(macOS)
            if record.body.kind == .project { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true) }
            #endif
        }.padding(.vertical, 14).contentShape(Rectangle())
    }
    @ViewBuilder private var metadata: some View {
        ResourceOwnership(model: model, spaceID: record.latest.spaceID)
        Text(record.conflicted ? "待核对" : record.body.status.title)
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
