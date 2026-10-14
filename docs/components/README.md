# 公共组件

全局视觉与交互规则见 [DESIGN.md](../../DESIGN.md)。本目录用于记录跨页面组件的使用约定；简单组件以源码注释为准，不按文件逐一建立文档。

| 组件范围 | 源码 | 主要约束 |
| --- | --- | --- |
| 页面与表单 | [WorkspaceStyle.swift](../../Sources/NobisUI/Shared/Styles/WorkspaceStyle.swift) | 复用布局和操作栏，适配窄屏、动态字号与键盘 |
| 表面与玻璃 | [Styles](../../Sources/NobisUI/Shared/Styles) | 使用语义颜色，保留旧系统、减少透明度和增强对比度回退 |
| 表单文本输入 | [LifeNativeTextInput.swift](../../Sources/NobisUI/Shared/Components/LifeNativeTextInput.swift) | iOS 组词期间保留候选、文字与焦点，外观切换不结束组词 |
| 身份与归属 | [ResourceIdentity.swift](../../Sources/NobisUI/Shared/Components/ResourceIdentity.swift) | 区分可见范围、成员身份和财务归属 |
| 记录行 | [RecordRows.swift](../../Sources/NobisUI/Shared/Components/RecordRows.swift) | 按上下文省略常态状态与继承归属；保留异常、混合范围身份和金额，小屏和大字号可重排 |

笔记专用编辑器位于 `Sources/NobisUI/Features/Notes/Editor`，业务行为见[笔记文档](../features/documents.md)。新增组件文档应说明适用场景、状态与交互约束，不重复抄写 API 或全局样式规则。

- [MDTextKit 笔记编辑组件](mdtextkit.md)：本地源码、双端边界与修改入口。
