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
                }
                Label("个人内容私密同步，Studio 内容与家庭成员共享。", systemImage: "lock.icloud").font(.callout)
                if model.cloud.configured {
                    Text("使用同一个 Apple ID 连接你的设备。个人名称和头像只需设置一次，随后创建或加入一个 Studio。").font(.callout).foregroundStyle(.secondary)
                    Button("连接 iCloud 并开始") { model.setupAndConnect(name: name, familyName: family) }.lifePrimaryAction().disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Text("当前是未配置 iCloud 的开发预览版，正式使用请打开云端版本。").font(.caption).foregroundStyle(.secondary)
                    Button("用隔离示例体验") { model.setup(name: name.isEmpty ? "我" : name, familyName: family, partnerName: "示例成员", demo: true) }.buttonStyle(.plain)
                }
                Text("PRO NOBIS · 为了我们").font(.caption2).tracking(2).foregroundStyle(.tertiary)
            }.padding(40).frame(maxWidth: 540)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background { LifeBackground() }
    }
}
