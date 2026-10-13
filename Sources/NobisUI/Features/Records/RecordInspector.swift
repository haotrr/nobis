import SwiftUI
import FamilyDomain

@MainActor @Observable public final class RecordPanelState {
    public private(set) var recordID: UUID?
    public private(set) var editingRecord: Record?
    public private(set) var hasChanges = false
    public private(set) var needsDiscardConfirmation = false
    private enum Destination { case record(UUID?), details }
    private var pending: Destination?
    public init() {}
    public func open(_ id: UUID) {
        guard id != recordID else { return }
        request(.record(id))
    }
    public func close() { request(.record(nil)) }
    public func cancelEditing() { request(.details) }
    private func request(_ destination: Destination) {
        if editingRecord != nil && hasChanges {
            pending = destination; needsDiscardConfirmation = true
        } else { apply(destination) }
    }
    private func apply(_ destination: Destination) {
        finishEditing()
        if case .record(let id) = destination { recordID = id }
    }
    public func edit(_ record: Record) {
        guard record.id == recordID, !record.deleted, !record.conflicted, record.body.sharedDestination == nil else { return }
        editingRecord = record; hasChanges = false
    }
    public func updateChanges(_ changed: Bool, recordID: UUID) {
        guard editingRecord?.id == recordID else { return }
        hasChanges = changed
    }
    public func finishEditing() { editingRecord = nil; hasChanges = false; pending = nil; needsDiscardConfirmation = false }
    public func dismissDiscardPrompt() { needsDiscardConfirmation = false }
    public func keepEditing() { pending = nil; needsDiscardConfirmation = false }
    public func discardAndContinue() {
        guard let destination = pending else { return }
        apply(destination)
    }
    /// Access loss must remove both the presentation and its captured editing payload.
    public func reset() { recordID = nil; finishEditing() }
}

struct RecordLink<LabelContent: View>: View {
    let model: AppModel
    let record: Record
    @ViewBuilder let label: () -> LabelContent
    var body: some View {
        if record.body.kind == .document && !record.deleted && !record.conflicted && record.body.sharedDestination == nil {
            NavigationLink { DocumentDetail(model: model, documentID: record.id) } label: { label() }
        } else if record.body.kind == .project && !record.deleted && !record.conflicted {
            NavigationLink { ProjectWorkspace(model: model, projectID: record.id) } label: { label() }
        } else {
        #if os(macOS)
        if record.body.kind == .project {
            NavigationLink { RecordDetail(model: model, recordID: record.id) } label: { label() }
        } else {
            Button { model.recordPanel.open(record.id) } label: { label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(RecordSelectionStyle(selected: model.recordPanel.recordID == record.id))
                .accessibilityAddTraits(model.recordPanel.recordID == record.id ? [.isSelected] : [])
        }
        #else
        NavigationLink { RecordDetail(model: model, recordID: record.id) } label: { label() }
        #endif
        }
    }
}

struct RecordInspector: View {
    let model: AppModel
    private var record: Record? { model.records.first { $0.id == model.recordPanel.recordID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.recordPanel.close() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .keyboardShortcut(model.recordPanel.editingRecord == nil ? .cancelAction : nil)
                .buttonStyle(.borderless).help("关闭详情（Esc）").accessibilityLabel("关闭右侧面板")
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.recordPanel.editingRecord == nil ? (record?.body.kind.title ?? "记录") + "详情" : "编辑" + (record?.body.kind.title ?? "记录")).font(.headline)
                    if model.recordPanel.editingRecord != nil { Text(model.recordPanel.hasChanges ? "有未保存的修改" : "尚未修改").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let record, model.recordPanel.editingRecord == nil, !record.deleted, !record.conflicted, record.body.sharedDestination == nil {
                    Button("编辑") { model.recordPanel.edit(record) }.keyboardShortcut("e", modifiers: .command).help("编辑记录（⌘E）").disabled(!model.canWrite(spaceID: record.latest.spaceID))
                }
            }.padding(12).nobisGlass(radius: 20).padding(12)
            if let record {
                if let editing = model.recordPanel.editingRecord {
                    if [.monthlyIncome, .assetSnapshot].contains(editing.body.kind) {
                        FinancialRecordEditor(model: model, kind: editing.body.kind, existing: editing, onFinish: { model.recordPanel.finishEditing() })
                            .id(editing.id)
                    } else {
                        RecordEditor(model: model, kind: editing.body.kind, existing: editing, onFinish: { model.recordPanel.finishEditing() })
                            .id(editing.id)
                    }
                } else {
                    NavigationStack {
                        RecordDetail(model: model, recordID: record.id, onEdit: { model.recordPanel.edit(record) })
                            .id(record.id)
                    }
                }
            } else {
                ContentUnavailableView("记录不可用", systemImage: "doc.questionmark", description: Text("记录可能已删除或访问权限已改变。"))
            }
        }
        .frame(maxHeight: .infinity)
        .background { LifeBackground() }
        .confirmationDialog("放弃正在编辑的内容？", isPresented: Binding(get: { model.recordPanel.needsDiscardConfirmation }, set: { if !$0 { model.recordPanel.dismissDiscardPrompt() } })) {
            Button("放弃修改并继续", role: .destructive) { model.recordPanel.discardAndContinue() }
            Button("继续编辑", role: .cancel) { model.recordPanel.keepEditing() }
        }
    }
}

/// Keep commit controls next to the form, rather than merging into the window toolbar.
struct InspectorEditorActions: View {
    let cancel: () -> Void
    let save: () -> Void
    var hasChanges: Bool = true
    var saveTitle: String = "保存修改"
    var saveKey: KeyEquivalent = .return
    var cancelTitle = "取消"
    var status: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel("保存状态：\(status)")
            }
            HStack {
            Button(cancelTitle, action: cancel).keyboardShortcut(.cancelAction)
            Spacer()
            Button(saveTitle, action: save)
                .lifePrimaryAction()
                .keyboardShortcut(saveKey, modifiers: .command)
                .disabled(!hasChanges)
            }
        }
        .padding(12)
        .nobisGlass(radius: 20)
        .padding(12)
    }
}

private struct RecordSelectionStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.tint.opacity(configuration.isPressed ? 0.20 : selected ? 0.10 : 0))
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(.tint).frame(width: contrast == .increased ? 4 : 3)
                        .padding(.vertical, 10).offset(x: -7)
                }
            }
    }
}
