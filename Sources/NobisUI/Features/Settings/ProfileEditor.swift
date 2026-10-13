import SwiftUI
import FamilyDomain
import ImageIO
import UniformTypeIdentifiers

struct ProfileEditor: View {
    let model: AppModel
    let space: Space
    @State var member: Member
    @State private var familyName: String
    @State private var importing = false
    @State private var image: CGImage?
    @State private var zoom = 1.0
    @State private var horizontal = 0.5
    @State private var vertical = 0.5
    @State private var issue: String?
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, space: Space, member: Member) {
        self.model = model; self.space = space; _member = State(initialValue: member); _familyName = State(initialValue: space.name)
    }
    private var crop: CGImage? {
        guard let image else { return nil }
        let side = Double(min(image.width, image.height)) / zoom
        return image.cropping(to: CGRect(x: (Double(image.width) - side) * horizontal, y: (Double(image.height) - side) * vertical, width: side, height: side))
    }
    var body: some View {
        LifeDetail {
            LifeFormSection(title: "成员资料", icon: "person.crop.circle") {
                LifeTextField("称呼", text: $member.name)
                LifeAdaptiveRow {
                    if let crop { Image(decorative: crop, scale: 1).resizable().scaledToFit().frame(width: 96, height: 96).clipShape(Circle()) }
                    else { IdentityAvatar(name: member.name, identity: member.id.uuidString, avatarData: member.avatarData).dynamicTypeSize(.large).scaleEffect(2).padding(20) }
                    Button("选择头像…") { importing = true }
                    if member.avatarData != nil || image != nil { Button("移除头像") { member.avatarData = nil; image = nil } }
                }
                if image != nil {
                    Slider(value: $zoom, in: 1...3) { Text("缩放") }
                    Slider(value: $horizontal, in: 0...1) { Text("水平裁剪位置") }
                    Slider(value: $vertical, in: 0...1) { Text("垂直裁剪位置") }
                }
            }
            if space.kind == .family, model.core?.session.actorID(in: space.id) == space.ownerID {
                LifeFormSection(title: "家庭", icon: "house") { LifeTextField("家庭名称", text: $familyName) }
            }
            Text(model.cloud.grant?.spaceID == space.id ? "此家庭中的称呼和头像随家庭数据同步；Apple 账号和共享权限不变。" : "保存到此本地空间；未连接 iCloud 的成员是本地标识。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            if let issue { InlineIssue(message: issue) }
        }
        .modifier(LifeEditorChrome(title: "编辑资料", icon: "person.crop.circle", cancel: { dismiss() }, save: save))
        #if os(iOS)
        .presentationDetents(image == nil && !textSize.isAccessibilitySize ? [.height(480), .large] : [.large])
        .presentationDragIndicator(.visible)
        #endif
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 10_000_000 else { throw NobisError.validation("请选择小于 10 MB 的图片。") }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 768] as CFDictionary) else { throw NobisError.validation("无法读取这张图片。") }
                image = thumbnail; zoom = 1; horizontal = 0.5; vertical = 0.5
            } catch { issue = error.localizedDescription }
        }.editorDimensions(width: 460, height: space.kind == .family ? 480 : 360)
    }
    private func save() {
        do {
            if let crop {
                guard let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NobisError.validation("无法处理头像。") }
                context.interpolationQuality = .high; context.draw(crop, in: CGRect(x: 0, y: 0, width: 256, height: 256))
                let data = NSMutableData()
                guard let output = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw NobisError.validation("无法处理头像。") }
                CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw NobisError.validation("无法保存头像。") }
                member.avatarData = data as Data
            }
            try model.updateDisplay(spaceID: space.id, name: familyName.trimmingCharacters(in: .whitespacesAndNewlines), member: member, expected: space)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}

struct ProfileSettingsSection: View {
    let model: AppModel
    @State private var selection: ProfileSelection?
    private struct ProfileSelection: Identifiable { let space: Space; let member: Member; var id: String { space.id.uuidString + member.id.uuidString } }
    private var profiles: [ProfileSelection] {
        model.spaces.flatMap { space in
            let actor = model.core?.session.actorID(in: space.id)
            return space.members.filter { member in
                model.cloud.grant?.spaceID == space.id ? member.id == actor : space.ownerID == actor
            }.map { ProfileSelection(space: space, member: $0) }
        }
    }
    var body: some View {
        LifeSection(title: "称呼与头像", icon: "person.crop.circle") {
            ForEach(profiles) { profile in
                Button { selection = profile } label: {
                    HStack {
                        MemberIdentityBadge(member: profile.member, showsAvatar: true)
                        Spacer()
                        Text(profile.space.name).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                }.buttonStyle(.plain).padding(.vertical, 6).disabled(!model.canWrite(spaceID: profile.space.id))
            }
        }.sheet(item: $selection) { item in ProfileEditor(model: model, space: item.space, member: item.member) }
    }
}
