# Nobis 内置 MDTextKit

- 上游：https://github.com/AFutureD/MDTextKit
- 基线：0.1.2，commit `b9cac228bd099bb19c15ad9de3775a6a68197c8c`。
- 许可：MIT，原文见 [LICENSE](LICENSE)。仅引入 MDTextKit，未复制 AGPL 的 Noto 应用代码。
- `Sources`、`Tests`、Demo 及原始 README 一并保留；这是可直接修改的本地 Swift Package，不是 submodule，也不依赖远程下载。
- 根包仅在 macOS 链接 `MDTextKitUI`；iOS 继续使用 Nobis 原生块编辑器。

## 本地补丁

| 位置 | 变化 |
| --- | --- |
| Package.swift | 部署声明降为 macOS 14，Swift 工具链仍要求 6.2+；最低系统运行验收另行记录 |
| MDTextView | 中文组词期间不重排／回传，提交统一注册撤销；只读表格不创建输入控件，禁用只读标题／折叠写入；单元格共用 Markdown 格式快捷键；焦点及组合文本状态通知工具栏；组词开始时保留当前段落布局，每次 marked-text 更新后恢复缩进／对齐，避免临时输入样式重置导致横向跳动 |
| MDImageTextStyler / MDImageTextAttachment | 增加宿主图片数据回调，由 Nobis 异步加载 HTTPS 图片；组件渲染期间不做网络读取 |
| MDTableAttachmentViewController | 单元格监听已提交的 Markdown 变化，立即回写正文，共享正文撤销栈，局部恢复表格、单元格及选区；完整表格标记保留末行；序列化转义管线字符 |
| MDFormatting | 全选区格式与混合格式区分，修正正文与列表混选判断 |
| MDEditorController | 附件变化先更新索引和解析状态，再通知宿主 |

Nobis 适配层为 `Sources/NobisUI/Features/Notes/Editor/MDTextKitEditor.swift`：主题、链接白名单、图片加载、SwiftUI 绑定和工具栏命令。业务草稿、权限、保存、修订和清单投影仍由原模块负责。

## 开发与更新

```sh
swift test --package-path Vendor/MDTextKit
swift test --filter MDTextKitIntegrationTests
```

升级时先对照此基线合并上游，再检查上述补丁、双平台构建和宿主测试。同步更新本文件的版本、MIT 许可及 `Sources/NobisUI/Resources/MDTextKit-LICENSE.txt`。详细集成约定见 [组件说明](../../docs/components/mdtextkit.md)。
