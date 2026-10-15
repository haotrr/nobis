# 本地验收矩阵

## 覆盖与判定

| 流程 | 覆盖证据 | 边界 |
| --- | --- | --- |
| 录入／编辑／冲突 | FamilyCore、RecordPanel、WorkspaceUI、LocalStability：保存修订、过期编辑拒绝、取消保护、刷新失败后旧结果与重试、权限失败清空 | 不修改正式库 |
| 笔记与清单 | Document、DocumentCompletion、DocumentManagementDraft、NoteDraftWriter：保存、草稿恢复、评注、双向清单、已读写入失败恢复 | 云逐字协作不在范围 |
| 编辑器与照片 | NoteImageImport、NoteEmbeddedImage、NoteSearchReplacement、MDTextKitIntegration；iOS 原生控件 XCTest | 无新增 UI 布局；真实相册慢速原图及真机手感未替代 |
| 安排／订阅／提醒 | DailyRefresh、WorkspaceQuery、Reminder、LocalStability：跨日、时区、暂停、搜索、静默时段、DST、提醒删除差集与失败前保留 | 调度计划不等于通知中心实际送达 |
| 财务／报表 | Financial、FinancialReport、FinancialBrowsing、FinancialReconciliation：多币种、退款、归属、资产九项、月报年报、冲突和草稿排除 | 真实持有范围仍由用户确定 |
| 导入／恢复 | BasicFlow、MintyMigration、RecoveryMerge、MintyCopyAcceptance：幂等、完整副本对账、备份、映射、合并、重启、旧数据不变 | 只使用原 JSON 副本的再次复制；不执行正式迁入 |
| 日期与损坏数据 | LocalStability、LocalMetadataFile：非法日期解码拒绝、极端年份、日期往返、文件保护、失败不重建 | 系统文件保护实机故障不以模拟写入失败替代 |
| 性能与历史 | ReportPerformance、LargeStoreLoading、LocalStability：12,000 条、100,000 条／修订、8,001 修订约 15 MB 备份逐值往返、图环／缺父／跨空间拒绝 | 单机 Debug 数据，不等于 GUI 帧率或最低系统性能 |

## 当前结果

- 双平台 Debug 构建通过。
- iOS 模拟器原生编辑器 21 项测试通过。
- Python Minty 导出器测试通过。
- 新增 LocalStability 6 项测试通过，包含参数化无效日期。
- 完整 Swift 回归 202 项 / 38 套件通过，Minty／规模可选项全部启用；家庭 346 条、个人 1,318 条副本对账及恢复合并通过。原三份 JSON 副本与再次复制的输入均经 SHA-256 核对未变。
- 采用 Pacific/Apia 进程时区的日期回归通过。
- 追加十万记录与千条×百修订两组完整备份落盘／读取／校验，分别为 151,315,773 与 156,632,743 字节，逐值等于原快照；单机 Debug 往返约 5.91 / 5.76 秒。两组再次保存、重启、账本及初始化检查通过。时间含编码、落盘、读取和解码，不等于 UI 响应。
- 最终 `git diff --check` 通过；没有修改持久化 schema、正式数据、第三方源码或云配置。

## 仍需真实环境的条件

后台通知送达、休眠／旅行时区变化、最低系统兼容、长文和真实相册交互、十万条 GUI 响应尚不作为已验收。按用户既定范围暂缓云和专项无障碍，不将这些条件写成实现完成。
