# Markdown 编辑组件

Mac 笔记使用仓库内的 [MDTextKit](../../Vendor/MDTextKit/NOBIS.md)；iOS 保留 `BlockDocumentEditor`。本地包源码和上游测试均可直接修改，入口为 `Vendor/MDTextKit/Package.swift`，不要求下载 GitHub 依赖。工具链至少 Swift 6.2。

## 接入边界

- `MDTextKitEditor` 把完整 Markdown 绑定到现有正文草稿；编辑和只读展示复用同一排版引擎。指定清单行高亮或独立勾选回调的阅读场景仍走原生 `MarkdownPreview`，保留来源定位。
- Markdown 原位排版，光标进入语法结构时显示标记；标题、列表、表格、代码均处于统一文本流中。
- 回显同一正文不重新载入，不清空撤销；外部导入则载入新的正文。中文候选期间不重排、不派发格式操作、不回传临时拼音；提交后才更新草稿。
- 表格单元格提交后立即更新正文；代码示例仍由现有业务解析器排除，不产生待办。保存、修订、并发冲突、评注和权限不由组件处理。
- 链接只允许 http / https / mailto；未提供本地文件解析器或附件上传。HTTPS 图片由宿主异步加载，只读展示需主动点击加载，失败保留占位。
- 不支持的语法保留为 Markdown；Mac 扩展语法在 iOS 上不保证相同排版。折叠标记会进入 Markdown，属于正文修改。
- 许可随应用资源打包，可在「设置 → 关于 Nobis → 开源许可」查看。

## 改动分工

| 要改什么 | 位置 |
| --- | --- |
| 主题、正文布局、工具栏与绑定 | `Sources/NobisUI/Features/Notes/Editor/MDTextKitEditor.swift` |
| SwiftUI 双端路由 | 同目录 `VisualDocumentEditor.swift`、`MarkdownPreview.swift` |
| 输入、撤销、表格交互 | `Vendor/MDTextKit/Sources/MDTextKitUI` |
| 排版、附件、正文操作 | `Vendor/MDTextKit/Sources/MDTextKit` |
| Markdown 解析与结构操作 | `Vendor/MDTextKit/Sources/PolarMark` |
| 草稿、修订和清单业务 | `Sources/FamilyCore` 与现有 `DocumentsView` |

验证命令及本轮覆盖范围见[验证状态](../verification.md)。上游基线与本地补丁必须同步记入 `Vendor/MDTextKit/NOBIS.md`，避免升级时覆盖修复。
