# Nobis

为了我们。面向共同生活的 macOS / iOS 原生应用。

**当前为 v0.1 开发试用版，主应用已接入 CloudKit 双人共享代码，尚未通过真实双 Apple ID 验收。** 默认 Scheme 使用原有本地模式；选择 Cloud Scheme 并配置开发者团队/容器后可创建或加入云端家庭。原有个人数据和家庭草稿保持本地。

视觉与交互规范见 [Nobis Design](DESIGN.md)。

## 运行

最低系统为 iOS 17 / macOS 14。当前使用 Xcode 27、Swift 6.4 验证，源码语言模式 Swift 6，无第三方运行时依赖。

```sh
open Nobis.xcodeproj
```

选择 `NobisMac` / `NobisIOS` 运行本地版；选择 `NobisMac-Cloud` / `NobisIOS-Cloud` 运行共享版。共享版先按 [CloudKit 配置与验收](docs/guides/cloudkit-setup.md) 设置开发团队、同一容器和 development 签名。首次启动可建立空空间或体验示例内容。

```sh
swift test
xcodebuild -project Nobis.xcodeproj -scheme NobisMac -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Nobis.xcodeproj -scheme NobisIOS -sdk iphonesimulator -derivedDataPath /tmp/nobis-today-ios CODE_SIGNING_ALLOWED=NO build
```

仅 Debug 构建支持 `--nobis-review-directory /绝对路径/隔离目录`，以独立数据目录启动并禁用云连接和通知；目录应由副本验收准备。测试专用应用包还可在 Info.plist 设置 `NobisReviewDirectory`，避免自动重启丢失启动参数。正式构建忽略这两个入口，不把私有副本提交进仓库。

Xcode 工程已包含在仓库；修改 `project.yml` 后使用 `xcodegen generate` 重新生成。

## 功能与文档

项目协作约定见 [AGENTS.md](AGENTS.md)。

已实现今天、项目、笔记与评注、待办／日程／订阅、家庭账本、收入资产报告，以及本地备份和迁移工具。完整范围见[功能清单](docs/feature-inventory.md)。

- [文档导航](docs/README.md)
- [仓库结构](docs/repository-structure.md)与[架构](docs/architecture.md)
- [设计基线](DESIGN.md)
- [验证状态](docs/verification.md)与[后续计划](docs/roadmap.md)

## 只读 CLI

在 App 的“设置 → 数据与恢复 → 导出备份与隔离恢复 → 导出所选范围”选择文件，再执行：

```sh
swift run nobis spaces.list --export /绝对路径/备份.json
swift run nobis projects.list --export /绝对路径/备份.json --space <空间UUID>
swift run nobis ledger.summary --export /绝对路径/备份.json --space <空间UUID> --from 2026-10-01 --through 2026-10-31
swift run nobis subscriptions.upcoming --export /绝对路径/备份.json --space <空间UUID>
swift run nobis records.get --export /绝对路径/备份.json --space <空间UUID> --id <记录UUID>
```

stdout 为 JSON，stderr 为诊断，参数错误退出 2、越界退出 3。输出包含 `api_version`（当前为 2）、`data`、`sources`、`warnings`、`observed_at`、`sync_observation`、`visibility_scope`。导出文件持有者可读取文件中全部数据；这不是在线授权服务，不接收“切换成员”参数。

## 当前边界

普通构建保持本地试用。CloudKit 主应用代码已经实现，但真实双 Apple ID 邀请、并发、离线重连与撤权尚未验收。真机专项、完整 VoiceOver、万条性能、生产 schema 与长期恢复演练也未完成，详见[后续计划](docs/roadmap.md)。小屏模拟器的代表性浅深色与中文键盘场景已有验证，不能代替完整设备验收。

产品规划见[产品方向](docs/proposal.md)和[技术演进方案](docs/proposal-detailed.md)；已实现能力见[功能清单](docs/feature-inventory.md)。
