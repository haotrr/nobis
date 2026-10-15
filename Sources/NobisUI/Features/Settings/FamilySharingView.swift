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
                    if model.cloud.hasUnpreparedFamily {
                        Button("继续完成云家庭连接") { Task { await model.cloud.prepareInvitation(presentInvitation: false) } }.disabled(model.cloud.isBusy)
                    } else if model.cloud.canCreateFamily {
                        Text("没有找到已有云家庭。若另一台设备刚创建，请稍后再检查，避免重复创建。").font(.caption).foregroundStyle(.secondary)
                        TextField("新家庭名称", text: $familyName)
                        Button("新建云家庭…") { creating = true }.disabled(model.cloud.isBusy)
                    } else {
                        Text("正在查找已有云家庭，找到后会自动打开。").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("同一 Apple ID 的设备无需邀请。另一位成员请打开你发来的共享邀请。原有本地内容不会自动上传。").font(.caption).foregroundStyle(.secondary)
                }
                if model.cloud.connection != nil {
                    if model.cloud.isOwner {
                        Button(model.cloud.pendingInvitationCount > 0 || (model.cloud.grant?.members.count ?? 0) > 1 ? "管理家庭共享…" : "邀请另一位成员…") { Task { await model.cloud.prepareInvitation() } }.disabled(model.cloud.isBusy)
                        Text("自己的设备无需邀请，可直接使用同一 Apple ID 同步。邀请另一位后，对方才能查看和编辑这个云家庭。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("退出家庭…", role: .destructive) { leaving = true }.disabled(model.cloud.isBusy)
                    }
                    if model.cloud.grant == nil { Button(model.cloud.isOwner ? "修复云家庭连接" : "重试加入") { Task { if model.cloud.isOwner { await model.cloud.prepareInvitation(presentInvitation: false) } else { await model.cloud.retryInvitation() } } }.disabled(model.cloud.isBusy) }
                    ForEach(model.cloud.participants) { row in
                        HStack {
                            VStack(alignment: .leading) { MemberIdentityBadge(name: row.name, identity: row.participant.userIdentity.userRecordID?.recordName ?? row.name, showsAvatar: true); Text(row.status).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if model.cloud.isOwner && !row.isOwner { Button("移除…", role: .destructive) { removing = row }.disabled(model.cloud.isBusy) }
                        }
                    }
                }
                if model.cloud.isBusy { ProgressView("正在与 iCloud 通信…") }
                if model.cloud.enabled {
                    LabeledContent("传输状态", value: model.cloud.syncStatus)
                    if let issue = model.cloud.syncIssue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    if let date = model.cloud.syncProgress.lastDownload { LabeledContent("最近接收完成", value: date.formatted()) }
                    if let date = model.cloud.syncProgress.lastUpload { LabeledContent("最近上传完成", value: date.formatted()) }
                    Text("上传完成是本机观察，不代表另一台设备已收到。系统会自动安排传输；连接检查不会强制立即上传。").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("共享与隐私") {
                    Text("Studio 内容在成员间共享；个人内容通过独立私密区同步。旧本地数据需先备份核对迁移。移除成员后，其设备联网核验时停止访问；已经导出的文件无法收回。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("创建空的云家庭？内容会在你的设备间同步，邀请另一位后才与对方共享。", isPresented: $creating) {
            Button("创建云家庭") { Task { await model.cloud.createFamily(name: familyName, memberName: model.localMemberName) } }
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
struct CloudSetupView: View {
    let model: AppModel
    var body: some View {
        NavigationStack {
            LifeDetail {
                FamilySharingSection(model: model)
            }.navigationTitle("连接 iCloud")
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(model.cloud.grant == nil ? "稍后继续" : "开始使用") { model.showingCloudSetup = false }
                } }
        }.editorDimensions(height: 540)
            .task { if !model.cloud.enabled { await model.cloud.connect() } }
    }
}

struct FamilyInvitationView: View {
    let model: AppModel
    @State private var name = ""
    var body: some View {
        NavigationStack {
            LifeDetail {
                LifeSection(title: "一起生活", icon: "person.2") {
                Text("加入 \(model.cloud.invitation?.share[CKShare.SystemFieldKey.title] as? String ?? "家庭")").font(.title2)
                Text("加入后你可以查看和编辑这个家庭的项目、订阅、任务、日程与账单。你的个人空间和已有本地家庭草稿不会上传或迁入。")
                Text("系统接受邀请后仍需导入家庭数据和验证身份。完成前不会显示“已加入”。").font(.caption).foregroundStyle(.secondary)
                if let issue = model.cloud.issue { Text(issue).foregroundStyle(.orange) }
                Button("接受邀请并加入") { Task { await model.cloud.acceptInvitation() } }.lifePrimaryAction().disabled(model.cloud.isBusy || !model.ready)
                if model.setupRequired {
                    TextField("你的称呼", text: $name).textFieldStyle(.roundedBorder)
                    Button("继续并接受邀请") {
                        model.setup(name: name, familyName: "我们的家", partnerName: "")
                        if model.ready { Task { await model.cloud.acceptInvitation() } }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.cloud.isBusy)
                } else if !model.ready { Text("本地资料尚未打开，请先处理启动错误后重试。") }
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
        let nsError = error as NSError?
        let cancelled = nsError?.domain == NSCocoaErrorDomain && nsError?.code == NSUserCancelledError
        let message = cancelled ? nil : error?.localizedDescription
        Task { @MainActor in controller.preparedShare = nil; if let message { controller.reportSharingError(message) } else { await controller.connect() } }
    }
}
#endif
