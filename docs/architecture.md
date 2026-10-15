# v0.1 架构与 Store 路由

模块职责与目录见[仓库结构](repository-structure.md)。本页只说明数据与存储约束。

```text
NobisMac / NobisIOS (SwiftUI)
  → FamilyCore（会话、空间校验、用例、账务汇总）
  → Repository
  → RoutedRepository
    → CoreDataRepository（本地个人 / 家庭草稿）
    → CloudFamilyRepository（CloudKit private / shared，修订与审计同次 save）
    → PrivateCloudRepository（独立个人快照，按已核验 Apple ID 隔离）

nobis CLI → 显式导出包 → 校验 → 同一 FamilyCore（只读）
NobisSharingSpike → 独立 NSPersistentCloudKitContainer → private / shared
```

## 持久化边界

应用支持目录 `Nobis/identity.json` 保存本地创建的成员标识，不是 Apple ID 凭据。`Stores/spaces.json` 是空间目录；`Stores/<space UUID>.sqlite` 保存该空间的根、修订与审计。Mac 沙盒运行时路径位于应用容器中。

SpaceRoot 的 payload 保存空间元数据；RecordRevision、AuditEvent 通过 optional inverse 关系连接根。每个实体包含逻辑 ID 与 Codable JSON 二进制 payload。未使用 CloudKit 不支持的唯一约束；本地库不参与云同步，共享家庭使用独立云存储。十万条普通财务 payload 和十万修订已做隔离测量；大附件／大 payload 仍待验证。

本地一次写入只改变一个物理 Store；新增修订和审计同事务落盘，失败 rollback。库层拒绝覆盖历史。业务层校验父版本集合；投影以无子节点的修订为 head。多 head 为冲突，墓碑抑制自动复活。财务冲突排除正式合计，并报告各受影响币种的待核对数量。UI 选择版本会形成引用全部 head 的新修订。

家庭草稿中的另一成员只是本地分工/分摊标签，没有登录能力；不能推导其已接受邀请。正式共享家庭由设置中的 iCloud 流程另行创建或加入，不复用这些占位身份。

业务金额与分摊规则见[财务报告](features/financial-reports.md)，资源权限见[共同与私密](features/shared-life-design.md)。

## 备份

单个 JSON 包含 manifest（schema、范围、数量、时间和 SHA-256）及 base64 编码的业务 JSON。校验和用于检测损坏，不提供加密或来源认证。恢复时检查 UUID、空间/成员、父版本、环、关联和金额结构，先保存当前空间备份，再导入全新隔离 Core Data 目录；当前库不覆盖。保留原业务 ID 供隔离核对，不注册或复用旧 CloudKit 共享 ID。恢复合并支持同类范围的显式成员映射、差异与冲突预览：在内存库校验关联后一次保存新增当前版本，不覆盖目标修订，不迁入删除状态，不扩大私密范围。提交前核对权限与完整目标快照，过期预览拒绝写入；保存迁入前目标备份和完整来源备份。原作者及源修订留在来源备份，新增修订使用当前操作人；Minty 增量导入按来源键复用实际迁入的关联 ID。正式重新建家庭及云共享迁移仍待实现。

## 构建模式

主应用 Cloud 配置已接入共享数据路径，普通 Debug 保留本地试用。CloudKit P0 真机验收尚未通过，Cloud 配置用于开发验证。尚不可用的 AI 写入没有确认入口；独立 Spike 的探针 actor 为测试标识，不用于业务身份。

## 云共享存储

`CloudFamilyController` 在明确启用的 CloudDebug/CloudRelease 构建中连接 iCloud。CloudKit userRecordID 经容器命名空间映射为稳定成员 UUID；不按称呼、邮箱或本地占位成员匹配。AccessSession 按空间选择 actor；Repository 在保存时再次检查实时授权，因此旧编辑窗口不能凭旧 session 绕过撤权。

共享根只包含新建家庭及其记录。原个人和家庭草稿不迁移。接受邀请前核验容器/格式/私有范围；接受后重新获取服务器 CKShare，核对当前身份、拥有者、接受状态、权限、根归属和根对应的 share，全部满足才开放。导入暂缺父修订、关联或审计时，不把部分账务投影显示成完整结果。云端有相同逻辑 ID 的不一致镜像时保留原存储并拒绝猜选。

当前成员来自核验后的 CKShare；离开成员的 UUID 留在历史账务中，不授予读取权限。只读参与者可以看记录但不能保存。最多两位已接受成员是应用校验，不是 CloudKit 云端人数限制。

撤权与账号更换立即撤销 Repository 的 grant；UI 树重建，通知撤销，专用云目录关闭并清理。先落 `access-denied` 标记，清理成功才移除；失败/重启不能恢复旧 grant。缓存清理使用本地 Core Data coordinator 与专用目录删除，**不调用会删除云端对象的 purgeObjectsAndRecordsInZone**。个人库、家庭草稿和用户主动导出的文件不在清理目录内。

设备曾验证的 grant 可在同一账户的暂时网络失败时使用；账户身份未确认或已明确失权时不可使用。远端导入/导出事件和前台唤醒触发检查，事件合并并遵守重试间隔；“导出完成”不代表另一台设备收到了记录。

Apple 的系统面板更新 share 后，主应用调用 persistUpdatedShare 更新本地 metadata。参与者退出通过删除自己 shared database 中的 share 完成；拥有者移除参与者通过更新 CKShare 完成。分享/撤权请求失败不显示成功；真实跨设备行为仍等待开发容器与真机验收。

## 个人私密云存储

用户在设置中显式启用后，`PrivateCloudController` 使用当前容器的 private database、独立 `NobisPersonalV1` zone 和单个 CKAsset 快照。个人记录不加入家庭关系图，不创建 CKShare；验证空间类型、唯一拥有者、修订作者和完整审计，拒绝带 share 或 parent 的远端记录。账号变化立即阻断旧 Repository，缓存按容器及核验身份隔离，原本地空间不自动上传。

保存使用服务器 change tag 并发检查，合并不可变修订与审计，冲突保留分支。快照按稳定顺序编码，资产枚举键字典保持兼容格式并排序，避免设备间编码顺序导致重复上传。单快照限制 40 MB；保存后、回到前台及前台每 30 秒同步，无变化只读取摘要。后台及时送达、大库增量传输尚未保证。

浏览“仅自己”合并本地与个人云；启用后新个人内容默认进入个人云，空间标签区分本地与云。家庭成员身份和财务归属不由此改变。

## 笔记与兼容格式

`document` 复用 RecordBody.notes 存储 Markdown；`comment` 是独立可审计记录，根评注关联文档，回复关联根评注，避免留言修改正文修订。可选 documentQuote 保存引用快照。权限、存储和 CloudKit 路由沿用空间；不增加共享成员模型。备份 envelope 当前为 6，可读取 1–6，业务 Snapshot schema 为 1；共享格式为 5，不自动升级旧共享。具体功能和限制见 [documents.md](features/documents.md)。

## 源码依据

- [记录与校验](../Sources/FamilyCore/FamilyCore.swift)、[领域模型](../Sources/FamilyDomain/Models.swift)
- [存储路由](../Sources/FamilyCore/RoutedRepository.swift)、[CloudKit 控制器](../Sources/FamilyPersistence/CloudFamilyController.swift)
- [备份格式](../Sources/FamilyCore/Backup.swift)、[离线 CLI](../Sources/NobisCLI/main.swift)

## 本机提醒

`ReminderPreferences` 保存在当前数据目录的独立元数据文件，不进入业务备份或云记录。读取失败停用提醒并显示错误，不静默恢复默认启用。`ReminderPlanning` 从可访问的活跃待办／订阅生成确定性计划，排除删除、冲突及已发布来源；记录时区与设备静默时区分开处理。日历匹配处理夏令时，标识继续按发生日期／提前天数去重。AppModel 串行合并调度更新，代次与访问 epoch 阻止旧计划回写；关闭时撤销本应用待发送通知。最多安排最近 60 条，前台及时区变化重算；应用未运行时的时区变化不保证立即重排。隔离模式完全跳过系统通知中心。

## 报表计算与规模

单次报表使用授权快照创建 `FinancialReportIndex`，按所有修订头的年份／月份建立候选集合，冲突在各受影响期间计数且同一期间不重复。CSV 与图表复用索引，来源记录走 ID 字典；币种分组就地累加，避免来源数组重复复制。期末资产和资产历史按持有人／币种／日期分组。索引不跨刷新保留，导出重新授权及读取；`records` 与 `reportView` 的权限判断和投影使用同一次 Repository 加载。未引入磁盘索引、schema 升级或长期结果缓存；首次投影仍需全库读取与 JSON 解码，长修订历史仍可能成为瓶颈。

## 首次加载与历史投影

本地 `loadSpaces()` 只解码空间根；云仓库保留默认完整读取及授权检查。完整加载按物理空间批量读取修订／审计 payload，校验所属空间，遇到未保存的 Core Data 上下文拒绝读取。启动同步复用刚解码的快照，普通刷新重新读取授权快照；续费复核、列表、账本共享一次投影，新增续费任务后再读取，不跨刷新缓存。

投影通过父版本 ID 集合筛出并去重修订头，保留所有历史、分叉与删除语义；保存使用 ID 字典验证不可变历史，拒绝重复 ID、覆盖或物理删除。没有数据库 schema 变更，首次读取仍需全库 JSON 解码。十万条范围与测量限制见[验证状态](verification.md)。

## 笔记相册照片

iOS 通过 PhotosPicker 的文件传输读取用户选择的图片，ImageIO 在后台缩小并转为 JPEG（最长边 1600 像素，必要时继续缩小），不携带原照片定位元数据。图片以内嵌 JPEG data URL 随 Markdown 进入既有草稿、修订、数据库和备份，不依赖相册临时文件或另建共享权限。正文仍限 20,000 字，单篇嵌入图片解码后合计不超过 512 KiB，Markdown 文件不超过 800 KiB；超限不插入，提示拆分笔记。导入导出共用同一容量校验；大量图片及云端跨账号传输不在本轮验收范围。
