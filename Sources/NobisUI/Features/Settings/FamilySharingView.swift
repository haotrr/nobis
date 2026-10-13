import SwiftUI
import CloudKit
import FamilyDomain
import FamilyPersistence
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor public enum NobisCloudInvitation {
    public static var receive: ((CKShare.Metadata) -> Void)?
    public static var pending: CKShare.Metadata?
    public static func deliver(_ metadata: CKShare.Metadata) { if let receive { receive(metadata) } else { pending = metadata } }
}

struct FamilySharingSection: View {
    let model: AppModel
    @State private var familyName = "我们的家"
    @State private var creating = false
    @State private var leaving = false
    @State private var removing: CloudFamilyParticipant?
    #if os(macOS)
    @State private var presenter: MacFamilySharePresenter?
    #endif
    var body: some View {
        LifeSection(title: "家庭与 iCloud", icon: "icloud") {
            Text(model.cloud.configured ? model.cloud.state : "尚未启用 iCloud 共享")
            if let issue = model.cloud.issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !model.cloud.configured {
                Text("此版本暂未启用 iCloud 共享。内容仍保存在此设备，你可以继续记录并导出备份。").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(model.cloud.enabled ? "检查共享权限与同步状态" : "连接当前 iCloud 账户") { Task { await model.cloud.connect() } }.disabled(model.cloud.isBusy)
                if model.cloud.accountID != nil && model.cloud.connection == nil {
                    TextField("新家庭名称", text: $familyName)
                    Button("创建新的共享家庭…") { creating = true }.disabled(model.cloud.isBusy || !model.cloud.canCreateFamily)
                    Button("继续准备已有家庭的邀请") { Task { await model.cloud.prepareInvitation() } }.disabled(model.cloud.isBusy)
                    Text("新建空的云端家庭。原有家庭草稿与个人记录不会迁入，也不会把占位成员与 Apple ID 自动合并。").font(.caption)
                }
                if model.cloud.connection != nil {
                    if model.cloud.isOwner {
                        Button("邀请另一位成员 / 管理共享…") { Task { await model.cloud.prepareInvitation() } }.disabled(model.cloud.isBusy)
                        Text("请只邀请一位成员。系统面板支持重新发出邀请和撤销共享；不提供公开链接访问。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("退出家庭…", role: .destructive) { leaving = true }.disabled(model.cloud.isBusy)
                    }
                    if model.cloud.grant == nil { Button("重新打开邀请 / 重试加入") { Task { await model.cloud.retryInvitation() } }.disabled(model.cloud.isBusy) }
                    ForEach(model.cloud.participants) { row in
                        HStack {
                            VStack(alignment: .leading) { MemberIdentityBadge(name: row.name, identity: row.participant.userIdentity.userRecordID?.recordName ?? row.name, showsAvatar: true); Text(row.status).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if model.cloud.isOwner && !row.isOwner { Button("移除…", role: .destructive) { removing = row }.disabled(model.cloud.isBusy) }
                        }
                    }
                }
                if model.cloud.isBusy { ProgressView("正在与 iCloud 通信…") }
                if let date = model.cloud.lastImport { LabeledContent("最近导入", value: date.formatted()) }
                if let date = model.cloud.lastExport { LabeledContent("最近导出", value: date.formatted()) }
                Text("导出完成不代表对方设备已经收到。失权会在设备重新联网并核验后生效；无法收回已经导出的文件。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("创建共享家庭？以后保存在这个空间的记录会向受邀成员共享。", isPresented: $creating) {
            Button("创建共享家庭") { Task { await model.cloud.createFamily(name: familyName, memberName: model.localMemberName) } }
        }
        .confirmationDialog("退出后将停止访问并清理此设备的家庭缓存。请先导出自己需要保留的数据。", isPresented: $leaving) {
            Button("确认退出家庭", role: .destructive) { Task { await model.cloud.leave() } }
        }
        .confirmationDialog("移除这位成员的家庭访问权限？其设备下次联网核验后会清理缓存。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let row = removing { Button("确认移除 \(row.name)", role: .destructive) { removing = nil; Task { await model.cloud.revoke(row.participant) } } }
        }
        #if os(iOS)
        .sheet(isPresented: Binding(get: { model.cloud.preparedShare != nil }, set: { if !$0 { model.cloud.preparedShare = nil } })) {
            if let share = model.cloud.preparedShare, let container = model.cloud.ckContainer { FamilyCloudShareSheet(share: share, container: container, controller: model.cloud) }
        }
        #else
        .onChange(of: model.cloud.preparedShare) { _, share in
            guard let share, let container = model.cloud.ckContainer else { return }
            let presenter = MacFamilySharePresenter(controller: model.cloud)
            self.presenter = presenter; presenter.present(share: share, container: container)
        }
        #endif
    }
}
struct FamilyInvitationView: View {
    let model: AppModel
    var body: some View {
        NavigationStack {
            LifeDetail {
                LifeSection(title: "一起生活", icon: "person.2") {
                Text("加入 \(model.cloud.invitation?.share[CKShare.SystemFieldKey.title] as? String ?? "家庭")").font(.title2)
                Text("加入后你可以查看和编辑这个家庭的项目、订阅、任务、日程与账单。你的个人空间和已有本地家庭草稿不会上传或迁入。")
                Text("系统接受邀请后仍需导入家庭数据和验证身份。完成前不会显示“已加入”。").font(.caption).foregroundStyle(.secondary)
                if let issue = model.cloud.issue { Text(issue).foregroundStyle(.orange) }
                Button("接受邀请并加入") { Task { await model.cloud.acceptInvitation() } }.lifePrimaryAction().disabled(model.cloud.isBusy || !model.ready)
                if !model.ready { Text("请先关闭此页完成本地个人空间创建，再重新打开邀请。") }
                }
            }.navigationTitle("家庭邀请")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后") { model.cloud.invitation = nil } } }
        }.editorDimensions(height: 330)
    }
}

#if os(iOS)
struct FamilyCloudShareSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let controller: CloudFamilyController
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let sheet = UICloudSharingController(share: share, container: container)
        sheet.availablePermissions = [.allowPrivate, .allowReadWrite]
        sheet.delegate = context.coordinator; return sheet
    }
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let controller: CloudFamilyController
        init(controller: CloudFamilyController) { self.controller = controller }
        func itemTitle(for csc: UICloudSharingController) -> String? { "Nobis 双人家庭" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) { controller.preparedShare = nil; controller.reportSharingError(error.localizedDescription) }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { if let share = csc.share { Task { await controller.shareDidSave(share) } } }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { Task { await controller.systemStoppedSharing() } }
    }
}
#else
@MainActor final class MacFamilySharePresenter: NSObject, NSCloudSharingServiceDelegate {
    private let controller: CloudFamilyController
    private var service: NSSharingService?
    init(controller: CloudFamilyController) { self.controller = controller }
    func present(share: CKShare, container: CKContainer) {
        let provider = NSItemProvider(); provider.registerCloudKitShare(share, container: container)
        guard let service = NSSharingService(named: .cloudSharing) else { controller.preparedShare = nil; controller.reportSharingError("系统共享服务暂不可用，请检查 iCloud 登录状态。"); return }
        self.service = service; service.delegate = self
        service.perform(withItems: [provider])
    }
    nonisolated func options(for cloudKitSharingService: NSSharingService, share provider: NSItemProvider) -> NSSharingService.CloudKitOptions { [.allowPrivate, .allowReadWrite] }
    nonisolated func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) { Task { await controller.shareDidSave(share) } }
    nonisolated func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) { Task { await controller.systemStoppedSharing() } }
    nonisolated func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in controller.preparedShare = nil; if let message { controller.reportSharingError(message) } else { await controller.connect() } }
    }
}
#endif
