import SwiftUI
import FamilyDomain
import FamilyCore

struct OnboardingView: View {
    let model: AppModel
    @State private var name = ""
    @State private var family = "我们的家"
    @State private var partner = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Nobis").font(.system(size: 54, weight: .medium, design: .serif))
                Text("为了我们，也为了各自的生活。").font(.title2)
                Text("把待办、订阅和一起期待的事，放在一个安静的地方。").foregroundStyle(.secondary)
                VStack(spacing: 16) {
                    TextField("你的称呼", text: $name).textFieldStyle(.roundedBorder)
                    DisclosureGroup("本地空间选项") {
                        TextField("共同生活的名称", text: $family).textFieldStyle(.roundedBorder)
                        TextField("另一位成员的称呼（可选）", text: $partner).textFieldStyle(.roundedBorder)
                    }
                }
                Label("个人内容仅保存在本机；云家庭中的内容才会同步。", systemImage: "lock").font(.callout)
                if model.cloud.configured {
                    Text("连接 iCloud 后，自动查找你已有的云家庭。也可以新建云家庭，在自己的设备间同步，稍后再邀请另一位。旧内容不会自动上传。").font(.callout).foregroundStyle(.secondary)
                    Button("连接 iCloud 并开始") { model.setupAndConnect(name: name, familyName: family) }.lifePrimaryAction().disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button(model.cloud.configured ? "暂时只在此设备使用" : "开始我们的生活") { model.setup(name: name, familyName: family, partnerName: partner) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("用示例内容体验") { model.setup(name: name.isEmpty ? "我" : name, familyName: family, partnerName: partner.isEmpty ? "伴侣" : partner, demo: true) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Text("PRO NOBIS · 为了我们").font(.caption2).tracking(2).foregroundStyle(.tertiary)
            }.padding(40).frame(maxWidth: 540)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background { LifeBackground() }
    }
}
