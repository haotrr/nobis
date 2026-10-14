import SwiftUI
import UniformTypeIdentifiers
import FamilyCore
#if os(iOS)
import PhotosUI
#endif

struct NoteImageContent: Equatable {
    var alt: String
    var address: String
    var title: String
    var markdown: String { DocumentBlock(.image(alt: alt, address: address, title: title), trailingNewline: false).markdown }
}

/// A staged edit: preview and imports do not touch the document until Apply succeeds.
struct NoteImageInspector: View {
    let original: NoteImageContent
    var canEdit = true
    var apply: (NoteImageContent?) throws -> Void
    var close: () -> Void
    @State private var draft: NoteImageContent
    @State private var previewAddress: String
    @State private var image: Image?
    @State private var data: Data?
    @State private var issue: String?
    @State private var loading = false
    @State private var loadID = UUID()
    @State private var importing = false
    @State private var picking = false
    @State private var importURL: URL?
    @State private var discard = false
    @State private var copied = false
    @State private var retry = UUID()
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var importingPhoto = false
    #endif
    private var busy: Bool {
        #if os(iOS)
        importing || importingPhoto
        #else
        importing
        #endif
    }

    init(content: NoteImageContent, canEdit: Bool = true, apply: @escaping (NoteImageContent?) throws -> Void, close: @escaping () -> Void) {
        original = content; self.canEdit = canEdit; self.apply = apply; self.close = close
        _draft = State(initialValue: content)
        _previewAddress = State(initialValue: content.address)
    }
    private var dirty: Bool { draft != original }
    var body: some View {
        ScrollView {
        VStack(spacing: 12) {
            HStack {
                Text("图片").font(.headline)
                Spacer()
                Button("关闭") { if dirty { discard = true } else { close() } }.keyboardShortcut(.cancelAction)
                if canEdit { Button("应用") { commit(draft) }.disabled(!dirty || busy).keyboardShortcut(.defaultAction) }
            }
            if let data {
                NoteZoomImage(data: data, label: draft.alt.isEmpty ? "笔记图片" : draft.alt).id(previewAddress)
            } else {
                ZStack {
                    Color.primary.opacity(0.04)
                    if loading { ProgressView("正在加载图片") }
                    else { VStack { Label("图片暂时无法显示", systemImage: "photo"); Button("重试") { retry = UUID() } } }
                }.frame(height: 300)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { imageActions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 12) { imageActions }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless)
            if busy {
                HStack {
                    ProgressView("正在读取图片…")
                    Button("取消读取") {
                        importURL = nil
                        #if os(iOS)
                        photo = nil
                        #endif
                    }
                }
            }
            if canEdit {
                TextField("图片说明", text: $draft.alt).textFieldStyle(.roundedBorder)
                TextField("图片标题（可选）", text: $draft.title).textFieldStyle(.roundedBorder)
                if !draft.address.hasPrefix(NoteEmbeddedImage.prefix) {
                    HStack {
                        TextField("HTTPS 图片地址", text: $draft.address).textFieldStyle(.roundedBorder)
                            .onSubmit { previewAddress = draft.address }
                        Button("预览") { previewAddress = draft.address }
                    }
                }
            }
            if let issue { Text(issue).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 680, minHeight: 520, idealHeight: 640)
        #endif
        .interactiveDismissDisabled(dirty || busy)
        .confirmationDialog("放弃这次图片修改？", isPresented: $discard) {
            Button("放弃修改", role: .destructive) { close() }
            Button("继续编辑", role: .cancel) {}
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): importURL = url
            case .failure(let error): issue = error.localizedDescription
            }
        }
        #if os(iOS)
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .task(id: photo) {
            guard let photo else { return }
            importingPhoto = true
            defer { importingPhoto = false }
            do {
                guard let picked = try await photo.loadTransferable(type: NotePickedPhoto.self) else { throw NoteEmbeddedImage.ImportError.invalid }
                guard !Task.isCancelled else { return }
                draft.address = picked.address; previewAddress = picked.address; issue = nil
            } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
        #endif
        .task(id: importURL) {
            guard let url = importURL else { return }
            importing = true
            defer { importing = false; importURL = nil }
            do {
                let address = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try NoteEmbeddedImage.importFile(url)
                }.value
                guard !Task.isCancelled else { return }
                draft.address = address; previewAddress = address; issue = nil
            } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
        .task(id: previewAddress + retry.uuidString) { await loadImage() }
    }
    @ViewBuilder private var imageActions: some View {
        Button(copied ? "已复制" : "复制图片", systemImage: "doc.on.doc") { copyImage() }.disabled(data == nil)
        if canEdit {
            Menu {
                #if os(iOS)
                Button("从相册选择") { photo = nil; showPhotos = true }
                #endif
                Button("从文件选择") { picking = true }
            } label: { Label("替换图片", systemImage: "photo") }.disabled(busy)
            Button("删除图片", role: .destructive) { commit(nil) }.disabled(busy)
        }
    }
    private func commit(_ value: NoteImageContent?) {
        do {
            if let value, !value.address.hasPrefix(NoteEmbeddedImage.prefix) {
                guard let url = URL(string: value.address), url.scheme?.lowercased() == "https", url.host != nil else { throw NoteImageEditError.invalidAddress }
            }
            try apply(value); close()
        } catch { issue = error.localizedDescription }
    }
    @MainActor private func loadImage() async {
        let operation = UUID(); loadID = operation
        image = nil; data = nil; copied = false; loading = true
        defer { if loadID == operation { loading = false } }
        let address = previewAddress
        do {
            let bytes: Data
            if address.hasPrefix(NoteEmbeddedImage.prefix) {
                guard let embedded = await Task.detached(priority: .userInitiated, operation: { NoteEmbeddedImage.data(address) }).value else { throw NoteEmbeddedImage.ImportError.invalid }
                bytes = embedded
            } else {
                guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil else { throw NoteImageEditError.invalidAddress }
                let (download, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      response.url?.scheme?.lowercased() == "https", download.count <= 20 * 1_024 * 1_024 else { throw NoteEmbeddedImage.ImportError.invalid }
                bytes = download
            }
            guard !Task.isCancelled else { return }
            #if os(macOS)
            guard let native = NSImage(data: bytes) else { throw NoteEmbeddedImage.ImportError.invalid }
            image = Image(nsImage: native)
            #else
            guard let native = UIImage(data: bytes) else { throw NoteEmbeddedImage.ImportError.invalid }
            image = Image(uiImage: native)
            #endif
            data = bytes; issue = nil
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
    private func copyImage() {
        guard let data else { return }
        #if os(macOS)
        guard let native = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.writeObjects([native])
        #else
        guard let native = UIImage(data: data) else { return }
        UIPasteboard.general.image = native
        copied = true
        #endif
    }
}

enum NoteImageEditError: LocalizedError {
    case changed, invalidAddress
    var errorDescription: String? {
        switch self {
        case .changed: "正文已变化，请关闭图片面板后重新打开再修改。"
        case .invalidAddress: "请使用有效的 HTTPS 图片地址。"
        }
    }
}

struct NoteImageEdit {
    let source: String
    let range: NSRange
    let content: NoteImageContent
    private let newline: Bool

    init?(source: String, at location: Int) {
        var offset = 0
        for block in DocumentBlocks.parse(source) {
            let length = block.markdown.utf16.count
            defer { offset += length }
            guard location >= offset, location < offset + length,
                  case .image(let alt, let address, let title) = block.content else { continue }
            self.source = source
            range = NSRange(location: offset, length: length)
            content = NoteImageContent(alt: alt, address: address, title: title)
            newline = block.markdown.hasSuffix("\n")
            return
        }
        return nil
    }
    func replacementText(_ replacement: NoteImageContent?) -> String {
        replacement.map { $0.markdown + (newline ? "\n" : "") } ?? ""
    }
    func applying(to current: String, replacement: NoteImageContent?) throws -> String {
        guard current == source else { throw NoteImageEditError.changed }
        let updated = (current as NSString).replacingCharacters(in: range, with: replacementText(replacement))
        try DocumentContentLimits.validate(updated)
        return updated
    }
}

extension DocumentBlockBuffer {
    func replaceImage(_ original: DocumentBlock, with replacement: NoteImageContent?) throws {
        guard let index = blocks.firstIndex(where: { $0.id == original.id }), blocks[index] == original else { throw NoteImageEditError.changed }
        var next = blocks
        if let replacement { next[index].content = .image(alt: replacement.alt, address: replacement.address, title: replacement.title) }
        else { next.remove(at: index) }
        if next.isEmpty { next = [DocumentBlock(.text(""))] }
        try DocumentContentLimits.validate(next.map(\.markdown).joined())
        let focusedBlock = next[min(index, next.count - 1)]
        let targetName: String
        switch focusedBlock.content {
        case .text: targetName = focusedBlock.id.uuidString
        case .code: targetName = "code:\(focusedBlock.id)"
        case .table: targetName = "\(focusedBlock.id)-0-0"
        case .image: targetName = "image:\(focusedBlock.id)"
        }
        let target = NoteEditorFocus(target: targetName)
        replace(next, undo: undo, focus: target)
    }
}
