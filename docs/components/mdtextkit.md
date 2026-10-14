# Markdown 编辑组件

Mac 与 iOS 笔记均接入仓库内的 [MDTextKit](../../Vendor/MDTextKit/NOBIS.md)。Mac 使用 AppKit 前端，iOS 使用新增的 UIKit 前端，并保留 `BlockDocumentEditor` 的触屏内容块布局。本地包源码和上游测试均可直接修改，入口为 `Vendor/MDTextKit/Package.swift`，不要求下载 GitHub 依赖。工具链至少 Swift 6.2。

## 接入边界

- `MDTextKitEditor` 把完整 Markdown 绑定到现有正文草稿；编辑和只读展示复用同一排版引擎。指定清单行高亮或独立勾选回调的阅读场景仍走原生 `MarkdownPreview`，保留来源定位。
- Markdown 原位排版，光标进入语法结构时显示标记；标题、列表、表格、代码均处于统一文本流中。
- 回显同一正文不重新载入，不清空撤销；外部导入则载入新的正文。中文候选期间不重排、不派发格式操作、不回传临时拼音；提交后才更新草稿。组词期间保留当前段落的缩进与对齐；仅恢复布局属性，不执行 Markdown 重排或结束候选。
- 正文由页面统一纵向滚动，高度按内容测量并缓存；输入和窗口改宽后保持光标可见。工具栏显示选中／混合格式，中文组词期间禁用格式命令，链接弹窗保留原选区；表格单元格仅支持行内格式。
- 表格与正文共享撤销栈，表格撤销局部恢复内容、单元格和选区，结构操作可撤销；单元格提交后立即更新正文；代码示例仍由现有业务解析器排除，不产生待办。保存、修订、并发冲突、评注和权限不由组件处理。
- 链接只允许 http / https / mailto；未提供本地文件解析器或附件上传。HTTPS 图片由宿主异步加载，只读展示需主动点击加载；图片预留 4:3、最高 420 点区域，失败保持占位尺寸，成功原位更新像素而不重排正文。iOS 编辑与阅读图片同样固定展示区域，完整等比显示并允许留白。
- 不支持的语法保留为 Markdown；Mac 扩展语法在 iOS 上不保证相同排版。折叠标记会进入 Markdown，属于正文修改。
- 许可随应用资源打包，可在「设置 → 关于 Nobis → 开源许可」查看。

## iOS 接入

- `MDTextKitUIKit.MDMarkdownTextView` 使用共享 PolarMark 解析与格式操作，正文、表格单元格和代码输入通过 `MarkdownTextEditor` 绑定到原草稿链路。
- 正文原位排版，保留可编辑的 Markdown 标记并以次要颜色显示；不复制 Mac 的附件控件和隐藏标记布局。表格保留触屏单元格与行列菜单，图片沿用 HTTPS 加载。
- UIKit 输入原语抑制重复撤销登记，按已提交内容保存撤销快照；中文组词只在提交时回传，格式命令不强制结束组词。相同正文回显不重设缓冲区或撤销历史。
- 同一正文的 AST 与语法标注供排版、选区格式查询和格式命令复用；正文或字号／编辑模式变化时刷新相应缓存，组词期间不解析临时文本。
- 正文通过原生实际排版尺寸参与 SwiftUI 页面滚动，单元格与代码保留独立视口；光标显露合并到布局后执行。内容插入和结构撤销恢复目标焦点与 UTF-16 选区。
- 草稿、管理属性合并、修订检查及项目权限仍由原业务模块负责。

## 改动分工

| 要改什么 | 位置 |
| --- | --- |
| 主题、正文布局、工具栏与绑定 | `Sources/NobisUI/Features/Notes/Editor/MDTextKitEditor.swift` |
| SwiftUI 双端路由 | 同目录 `VisualDocumentEditor.swift`、`MarkdownPreview.swift` |
| iOS 原生输入与排版 | `Vendor/MDTextKit/Sources/MDTextKitUIKit` |
| 输入、撤销、表格交互 | `Vendor/MDTextKit/Sources/MDTextKitUI` |
| 排版、附件、正文操作 | `Vendor/MDTextKit/Sources/MDTextKit` |
| Markdown 解析与结构操作 | `Vendor/MDTextKit/Sources/PolarMark` |
| 草稿、修订和清单业务 | `Sources/FamilyCore` 与现有 `DocumentsView` |

验证命令及本轮覆盖范围见[验证状态](../verification.md)。上游基线与本地补丁必须同步记入 `Vendor/MDTextKit/NOBIS.md`，避免升级时覆盖修复。
