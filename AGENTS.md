# Nobis 项目协作约定

## 工作方式

- 使用中文沟通。先核对本地代码、文档与日志，对无法确认的外部事实查证，不把推测写成结论。
- 修改前检查工作区，保留既有未提交改动和用户数据；不为解决启动问题重建身份、清空数据库或卸载应用。
- 根据任务范围完成实现与合理验证，明确报告已验证和未验证项。提交、推送、安装和云配置按用户实际授权执行。

## 阅读入口

- [README](README.md)：运行和构建。
- [DESIGN](DESIGN.md)：视觉、交互及输入行为基线；修改 UI 前阅读。
- [仓库结构](docs/repository-structure.md)、[架构](docs/architecture.md)：目录和模块边界。
- [功能清单](docs/feature-inventory.md)、[验证状态](docs/verification.md)、[后续计划](docs/roadmap.md)：实现与验收范围。

## 代码组织

- 按[仓库结构](docs/repository-structure.md)放置源码，保持业务、持久化、UI 与平台入口边界。
- 应用工程由 `project.yml` 生成。调整 Target、资源或平台配置后执行 `xcodegen generate`，不要只手改生成工程。
- NobisUI 子目录仍属于一个 Swift Package Target，移动文件不需要拆出新的模块。

## 必须保持的业务约定

- 默认共同生活，私密内容不自动上传或扩大访问范围；项目内容继承项目权限。
- 可见权限、负责人、付款人、消费归属和资产持有人分别处理。
- 金额使用最小货币单位，不跨币种直接相加；草稿、冲突不计入正式合计。
- 保存保留修订和并发检查，不覆盖历史；备份恢复到隔离目录，不覆盖当前库。
- 笔记已保存的 Markdown 是清单事实来源，自动投影为待办，双向勾选同一正文，不生成重复任务。
- 保留草稿与取消保护；中文组词期间保持候选和已输入内容，不以结束组词规避颜色或布局问题。

## 验证

按改动选择验证，不为纯文档改动重复构建：

```sh
swift test
python3 scripts/test_export_minty.py
xcodebuild -project Nobis.xcodeproj -scheme NobisMac -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Nobis.xcodeproj -scheme NobisIOS -configuration Debug -sdk iphonesimulator -derivedDataPath /tmp/nobis-today-ios CODE_SIGNING_ALLOWED=NO build
```

共享 UI、应用入口或构建配置改动应验证双平台构建。布局和文本输入改动需要针对相关页面检查窄窗口／小屏、大字号、浅深色、横竖屏及键盘；涉及中文输入时检查组词和候选保留。

测试与构建成功不等于真机、完整无障碍或 CloudKit 双账号验收。云容器启用、真实双账号和真机专项目前按用户优先级暂缓；没有新授权时不自行扩展到这些任务。

## 文档与提交范围

- 功能现状写入功能清单，设计规则写入 DESIGN，验证条件与结果写入验证状态，未完成事项写入后续计划。
- 不重复追加开发流水账、临时机器路径或已失效结论；移动文件时同步修正链接。
- 不提交构建缓存、临时日志、业务数据库、备份或本机账号配置；保留 `.gitignore` 中的排除规则。
