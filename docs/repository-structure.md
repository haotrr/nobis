# 仓库结构

## 源码与构建

| 路径 | 职责 |
| --- | --- |
| `Apps/Nobis/Shared` | 共享应用入口与图标资源 |
| `Apps/Nobis/macOS`、`iOS` | 各平台生命周期代理、权限配置；iOS Info.plist |
| `Apps/SharingSpike` | 独立 CloudKit 实验应用 |
| `Sources/FamilyDomain` | 空间、成员、记录、修订、金额及财务模型 |
| `Sources/FamilyCore` | 业务、权限、查询、Markdown、草稿、备份和迁移 |
| `Sources/FamilyPersistence` | Core Data、本地分库、CloudKit 存储和控制 |
| `Sources/NobisUI` | 双平台界面，分组见下表 |
| `Sources/NobisCLI` | 显式导出文件上的离线只读查询 |
| `Tests/FamilyCoreTests` | Swift Testing；含模型与路由测试，不是点击式 XCUITest |
| `Config` | Cloud 配置及本机配置示例 |
| `Package.swift` | Swift 模块依赖 |
| `project.yml` → `Nobis.xcodeproj` | XcodeGen 定义及生成工程 |

## NobisUI

| 子目录 | 内容 |
| --- | --- |
| `App` | AppModel、启动分流、全局事件；`Navigation` 管理平台布局与路由 |
| `Features/Onboarding` | 首次使用与示例入口 |
| `Features/Workspace` | 今天、安排、搜索、资源关联 |
| `Features/Projects` | 项目、预览卡片、预算 |
| `Features/Notes` | 笔记、评注、Markdown 文件交换；`Editor` 为专用编辑基础设施 |
| `Features/Records` | 通用记录列表、详情、编辑与 Inspector |
| `Features/Finance` | 账本、导入、收入资产及报告 |
| `Features/Settings` | 设置、资料、家庭共享 |
| `Shared/Components` | 记录行、归属展示、原生表单输入 |
| `Shared/Styles` | 页面／表单布局、语义表面和玻璃样式 |

`NobisApp.swift` 仅创建场景和平台代理；`RootView.swift` 保留启动分流、根状态与全局事件。NobisUI 子目录仍属同一 Swift Package Target，由 SwiftPM 递归发现源码。

## 工具与资料

- `scripts/export_minty.py`：只读导出已解密 Minty 数据库副本；`test_export_minty.py` 验证只读、金额及覆盖保护。
- 根目录 [AGENTS.md](../AGENTS.md)、[DESIGN.md](../DESIGN.md)、[README.md](../README.md) 分别承载协作、设计、运行说明；专题见[文档导航](README.md)。
- `proposal.md` 定义产品方向，`proposal-detailed.md` 定义未实现能力的技术条件；图标母版在 `docs/design/`。
- `.build/`、`.build-app/`、`DerivedData/` 为忽略的构建产物；`Cloud.local.xcconfig` 为忽略的本机配置。应用数据在支持目录／沙盒中。
- 改应用 Target 或配置后运行 `xcodegen generate`；仅调整 SwiftPM 源码子目录无需重新生成工程。

## 文档分组

- `docs/`：导航、架构、仓库结构、功能总览、验证、计划和产品方案。
- `docs/features/`：笔记、财务、资源组织与共享权限等业务规则。
- `docs/guides/`：CloudKit 配置与 Minty 迁入操作。
- `docs/components/`：公共 UI 组件使用约定与源码索引。
- `docs/design/`：图标母版等设计资源；全局规范位于根目录 `DESIGN.md`。
