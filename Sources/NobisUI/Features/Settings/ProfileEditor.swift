import SwiftUI
import FamilyDomain
import ImageIO
import UniformTypeIdentifiers

struct ProfileEditor: View {
    let model: AppModel
    let expected: Member
    @State var member: Member
    @State private var importing = false
    @State private var image: CGImage?
    @State private var zoom = 1.0
    @State private var horizontal = 0.5
    @State private var vertical = 0.5
    @State private var issue: String?
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, member: Member) {
        self.model = model; expected = member; _member = State(initialValue: member)
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
            Text("名称和头像统一用于你的个人内容与已加入的 Studio；家庭成员只会看到这份展示资料。")
                .font(.caption).foregroundStyle(.secondary)
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
        }.editorDimensions(width: 460, height: 420)
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
            member.name = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try model.updateAccountProfile(member, expected: expected)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}

struct ProfileSettingsSection: View {
    let model: AppModel
    @State private var editing = false
    var body: some View {
        LifeSection(title: "个人资料", icon: "person.crop.circle") {
            if let member = model.accountProfile {
                Button { editing = true } label: {
                    HStack {
                        MemberIdentityBadge(member: member, showsAvatar: true)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                }.buttonStyle(.plain).padding(.vertical, 6)
                .sheet(isPresented: $editing) { ProfileEditor(model: model, member: member) }
            } else { Text("连接 iCloud 后设置统一名称与头像。").foregroundStyle(.secondary) }
        }
    }
}

struct StudioNameEditor: View {
    let model: AppModel
    let space: Space
    @State private var name: String
    @State private var issue: String?
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, space: Space) { self.model = model; self.space = space; _name = State(initialValue: space.name) }
    var body: some View {
        LifeDetail {
            LifeFormSection(title: "Studio", icon: "house") { LifeTextField("名称", text: $name) }
            if let issue { InlineIssue(message: issue) }
        }.modifier(LifeEditorChrome(title: "编辑 Studio", icon: "house", cancel: { dismiss() }, save: {
            do { try model.updateStudioName(name.trimmingCharacters(in: .whitespacesAndNewlines), expected: space); dismiss() }
            catch { issue = error.localizedDescription }
        })).editorDimensions(width: 460, height: 280)
    }
}
