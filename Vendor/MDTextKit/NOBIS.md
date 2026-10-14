# Nobis 内置 MDTextKit

- 上游：https://github.com/AFutureD/MDTextKit
- 基线：0.1.2，commit `b9cac228bd099bb19c15ad9de3775a6a68197c8c`。
- 许可：MIT，原文见 [LICENSE](LICENSE)。仅引入 MDTextKit，未复制 AGPL 的 Noto 应用代码。
- `Sources`、`Tests`、Demo 及原始 README 一并保留；这是可直接修改的本地 Swift Package，不是 submodule，也不依赖远程下载。
- 根包在 macOS 链接 `MDTextKitUI`，iOS 链接本地新增的 `MDTextKitUIKit`；两端复用 PolarMark，UIKit 不依赖 AppKit。

## 本地补丁

| 位置 | 变化 |
| --- | --- |
| Package.swift | 部署声明为 macOS 14 / iOS 17，Swift 工具链仍要求 6.2+；最低系统运行验收另行记录 |
| MDTextKitUIKit | 同源 AST／语法标注缓存供排版、选区与命令复用，同源同样式不重复排版；新增挂载后焦点请求，字号按控件 trait 取值。UIKit 原生文本视图，复用 PolarMark 排版与格式操作；保持 Markdown 字符及 UTF-16 选区，组词期间暂停回传／重排／格式操作；已提交输入和格式修改共用可注入撤销栈，正文与单元格共享历史 |
| MDTextView | 中文组词期间不重排／回传，提交统一注册撤销；只读表格不创建输入控件，禁用只读标题／折叠写入；单元格共用 Markdown 格式快捷键；焦点及组合文本状态通知工具栏；组词开始时保留当前段落布局，每次 marked-text 更新后恢复缩进／对齐，避免临时输入样式重置导致横向跳动 |
| MDImageTextStyler / MDImageTextAttachment | 增加宿主图片数据回调，由 Nobis 异步加载 HTTPS 图片；组件渲染期间不做网络读取；宿主可预留固定尺寸，加载后原位更新附件图像并等比居中绘制，不触发全文重排 |
| MDTableAttachmentViewController | 单元格监听已提交的 Markdown 变化，立即回写正文，共享正文撤销栈，局部恢复表格、单元格及选区；完整表格标记保留末行；序列化转义管线字符 |
| MDFormatting | 全选区格式与混合格式区分，修正正文与列表混选判断 |
| PMKAST+ClearFormatting | 双端共用行内／标题清除及选区映射，保留内容结构；支持仅取消标题 |
| MDTextView / MDTextKitUIKit / 表格 | 宿主整篇查找回调、表格单元格匹配定位与转义管线坐标转换、当前行列菜单中文标签；Mac 显式接收图片文件拖放及 PNG 粘贴类型；UIKit 增加标题级别、编号列表、引用、删除线与行内代码命令 |
| MDTextView+ImageInsertion | 新增图片 Markdown 序列化与选区末尾插入 API；保留选区正文、中文组词保护和原生撤销重做。宿主负责图片读取、存储及容量策略 |
| MDEditorController | 附件变化先更新索引和解析状态，再通知宿主 |

Nobis 适配层为 `Sources/NobisUI/Features/Notes/Editor/MDTextKitEditor.swift`：主题、链接白名单、图片加载、SwiftUI 绑定和工具栏命令。业务草稿、权限、保存、修订和清单投影仍由原模块负责。

## 开发与更新

```sh
swift test --package-path Vendor/MDTextKit
swift test --filter MDTextKitIntegrationTests
```

升级时先对照此基线合并上游，再检查上述补丁、双平台构建和宿主测试。同步更新本文件的版本、MIT 许可及 `Sources/NobisUI/Resources/MDTextKit-LICENSE.txt`。详细集成约定见 [组件说明](../../docs/components/mdtextkit.md)。

UIKit 宿主保留触屏表格、图片及代码块布局，正文与表格单元格使用新内核。语法标记以次要颜色保留可编辑，不移植 AppKit 的附件视图及隐藏标记布局。原生控件测试：`xcodebuild -project Nobis.xcodeproj -scheme NobisEditorTests -destination "platform=iOS Simulator,name=Nobis Design QA" test`。

- 清单边界：任务项只吸收显式缩进的续行；无缩进普通正文在换行后退出任务范围，避免完成状态与颜色扩散。普通列表仍保留原有续行解析。

- UIKit 正文回车调用共享 AST 换行操作以续建清单和退出空项；组词期间、表格单元格及代码不拦截输入法／字面换行。

- 查找高亮：UIKit 使用只读显示属性，组词期间延后；Mac 表格使用显示副本与活动单元格临时属性，不污染序列化或撤销记录。
