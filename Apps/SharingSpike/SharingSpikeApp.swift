import SwiftUI
import UIKit
import CloudKit
import CoreData
import FamilyDomain
import FamilyPersistence

@MainActor @Observable final class SpikeModel {
    static let shared = SpikeModel()
    var stack: CloudSharingSpike?
    var roots: [NSManagedObject] = []
    var revisions: [String] = []
    var log = "仅用于开发容器和测试数据。"
    var share: CKShare?
    var containerID: String { Bundle.main.object(forInfoDictionaryKey: "NobisCloudContainer") as? String ?? "" }
    func load() async {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NobisSharingSpike")
            let stack = CloudSharingSpike(directory: directory, containerIdentifier: containerID)
            try await stack.load(); self.stack = stack; refresh()
            log = "存储已就绪；不代表对方已收到数据。"
        } catch { log = error.localizedDescription }
    }
    func refresh() {
        guard let stack else { return }
        do {
            roots = try stack.container.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "SpaceRoot"))
            revisions = try stack.container.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "RecordRevision")).compactMap {
                guard let data = $0.value(forKey: "payload") as? Data, let revision = try? JSONDecoder().decode(Revision.self, from: data) else { return nil }
                return "\(revision.body.title) · \(revision.id.uuidString)"
            }
        } catch { log = error.localizedDescription }
    }
    func createRoot() {
        guard let stack else { return }
        do {
            guard roots.isEmpty else { log = "已有根对象，请复用现有共享。"; return }
            let me = Member(name: "测试拥有者"), family = UUID()
            let space = Space(id: family, name: "Nobis 共享验证", kind: .family, ownerID: me.id, members: [me])
            let context = stack.container.viewContext
            let root = NSEntityDescription.insertNewObject(forEntityName: "SpaceRoot", into: context)
            guard let privateStore = stack.container.persistentStoreCoordinator.persistentStores.first(where: { $0.url?.lastPathComponent == "private.sqlite" }) else { throw NobisError.forbidden }
            context.assign(root, to: privateStore); root.setValue(family.uuidString, forKey: "logicalID"); root.setValue(try JSONEncoder().encode(space), forKey: "payload")
            try context.save(); refresh(); log = "家庭测试根已本地保存。"
        } catch { stack.container.viewContext.rollback(); log = error.localizedDescription }
    }
    func prepareShare() async {
        guard let stack, let root = roots.first else { return }
        do { share = try await stack.shareFamilyRoot(root) } catch { log = error.localizedDescription }
    }
    func accept(_ metadata: CKShare.Metadata) async {
        if stack == nil { await load() }
        do { try await stack?.accept(metadata); refresh(); log = "邀请已接受，等待共享根导入；尚未完成业务成员映射。" }
        catch { log = error.localizedDescription }
    }
    func addRevision() {
        guard let stack, let root = roots.first, let data = root.value(forKey: "payload") as? Data else { return }
        do {
            let space = try JSONDecoder().decode(Space.self, from: data)
            // Technical transport probe only. This is deliberately NOT a production membership mapping.
            let revision = Revision(spaceID: space.id, actorID: UUID(), body: RecordBody(kind: .task, title: "传输探针 \(Date.now.formatted())"))
            let context = stack.container.viewContext, object = NSEntityDescription.insertNewObject(forEntityName: "RecordRevision", into: context)
            guard let store = root.objectID.persistentStore else { throw NobisError.forbidden }
            context.assign(object, to: store); object.setValue(root, forKey: "root"); object.setValue(revision.id.uuidString, forKey: "logicalID"); object.setValue(try JSONEncoder().encode(revision), forKey: "payload")
            try context.save(); refresh(); log = "探针已保存在此设备，请在另一设备手动核对 UUID。"
        } catch { stack.container.viewContext.rollback(); log = error.localizedDescription }
    }
}

@main struct SharingSpikeApp: App {
    @UIApplicationDelegateAdaptor(SpikeDelegate.self) private var delegate
    @State private var model = SpikeModel.shared
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("CloudKit 开发验证") {
                        Text(model.containerID).font(.caption)
                        Text("独立测试库，不连接 Nobis 正式个人或家庭数据。身份映射、撤权和冲突收敛仍须按验收表测试。")
                        Button("加载开发存储") { Task { await model.load() } }.disabled(model.stack != nil)
                        Button("A：创建测试家庭根") { model.createRoot() }.disabled(model.stack == nil || !model.roots.isEmpty)
                        Button("A：系统邀请与共享管理") { Task { await model.prepareShare() } }.disabled(model.roots.isEmpty)
                        Button("A / B：新增传输探针") { model.addRevision() }.disabled(model.roots.isEmpty)
                        Button("刷新本机导入结果") { model.refresh() }
                        Text(model.log).textSelection(.enabled)
                    }
                    Section("已导入根：\(model.roots.count)") { ForEach(model.revisions, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } }
                }.navigationTitle("Nobis Sharing Spike")
                .sheet(isPresented: Binding(get: { model.share != nil }, set: { if !$0 { model.share = nil } })) {
                    if let share = model.share { CloudShareView(share: share, container: CKContainer(identifier: model.containerID)) }
                }
            }
        }
    }
}
final class SpikeDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) { Task { await SpikeModel.shared.accept(metadata) } }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role); config.delegateClass = SpikeSceneDelegate.self
        if let metadata = options.cloudKitShareMetadata { Task { await SpikeModel.shared.accept(metadata) } }
        return config
    }
}
final class SpikeSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) { Task { await SpikeModel.shared.accept(metadata) } }
}
struct CloudShareView: UIViewControllerRepresentable {
    let share: CKShare; let container: CKContainer
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]; controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) { SpikeModel.shared.log = error.localizedDescription }
        func itemTitle(for csc: UICloudSharingController) -> String? { "Nobis 共享验证" }
    }
}
