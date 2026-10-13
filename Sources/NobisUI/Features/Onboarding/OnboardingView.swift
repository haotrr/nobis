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
                    TextField("共同生活的名称", text: $family).textFieldStyle(.roundedBorder)
                    TextField("另一位成员的称呼（可选）", text: $partner).textFieldStyle(.roundedBorder)
                }
                Label("个人内容单独存储，不会因创建家庭而共享。", systemImage: "lock").font(.callout)
                Text("先在此设备开始记录。家庭草稿中的称呼只用于分工和分摊；创建后可在设置中连接 iCloud，创建或加入双人家庭。原有个人内容不会自动上传。").font(.callout).foregroundStyle(.secondary)
                Button("开始我们的生活") { model.setup(name: name, familyName: family, partnerName: partner) }.lifePrimaryAction().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("用示例内容体验") { model.setup(name: name.isEmpty ? "我" : name, familyName: family, partnerName: partner.isEmpty ? "伴侣" : partner, demo: true) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Text("PRO NOBIS · 为了我们").font(.caption2).tracking(2).foregroundStyle(.tertiary)
            }.padding(40).frame(maxWidth: 540)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background { LifeBackground() }
    }
}
