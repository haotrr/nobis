# 主应用 CloudKit 配置与双人验收

主应用现已包含 CloudKit 家庭存储、身份映射、系统邀请、参与者移除、退出与本机失权清理。代码及无签名构建通过，不等于已经连接或验证真实 iCloud。

## 开发环境配置

1. 在 Xcode → Settings → Accounts 登录有 CloudKit 能力的 Apple Developer 团队。账号登录由你操作，不需要向 Codex 提供密码、令牌或验证码。
2. 在同一团队登记 Mac/iOS App ID：默认 `com.haotrr.nobis.mac` 与 `com.haotrr.nobis.ios`。如不可用，可在 `project.yml` 改为自己的标识，再运行 `xcodegen generate`。
3. 为两个 App ID 启用 iCloud / CloudKit 与 Push Notifications，并把它们都关联到同一个 development 容器。不要与旧 Spike 或其他 App 混用已有数据的容器。
4. 复制 `Config/Cloud.local.xcconfig.example` 为 `Config/Cloud.local.xcconfig`，填写 Team ID 与已登记的容器 ID：

```xcconfig
DEVELOPMENT_TEAM = 你的TEAMID
NOBIS_CLOUD_CONTAINER = iCloud.你已登记的容器
```

此文件已被 Git 忽略。工程提供的 `iCloud.com.haotrr.nobis.dev` 只是默认配置，不代表远端容器已存在。

5. 打开 `Nobis.xcodeproj`，分别选择 `NobisMac-Cloud` 和 `NobisIOS-Cloud`。运行使用 **CloudDebug / Development**；确认 Signing 自动签名成功，entitlement 中的容器与账号一致。
6. 在两台使用不同 Apple ID 的真机安装同一个 development 版本。也可 Mac + iPhone 使用不同 Apple ID。两端必须同一容器、同一 development 环境。不要把 development 与 TestFlight 的 production 混测。

普通 `NobisMac` / `NobisIOS` Scheme 仍使用本地 Debug，不申请 iCloud 权限，现有本地空间保留。CloudRelease 的签名环境是 Production；开发验证时不要发布 production 或部署生产 schema。

## A 创建并邀请 B

1. 两端先完成本地个人空间创建。旧家庭草稿只是本地数据，不会自动迁入云端或与 Apple ID 合并。
2. A 在“设置 → 家庭与 iCloud”连接当前账户，等待首次导入检查完成，再创建新的共享家庭。
3. 系统邀请面板出现后，只邀请 B 一人。发出邀请与“B 已加入”是两种状态；未接受时显示等待。
4. B 打开邀请链接，在 Nobis 确认共享范围并接受。只有服务器参与者身份/权限、共享根与 share 关联都到齐，才出现可操作的家庭空间。中间应显示“正在准备家庭数据”。
5. A、B 分别创建和完成一项任务，核对两端记录 ID、修订 ID 和负责人。再各记一笔测试支出，核对分摊与币种合计。
6. 重启两端复核数据；再测试离线写入、同时修改、恢复网络后的分支保留。不要只看“最近导出”时间。

系统共享面板不能由应用强制限制邀请人数；Nobis 仅支持最多两位已接受成员，检测到超额会停止业务访问，拥有者需从系统管理移除多余成员。这不是 CloudKit 的人数 ACL。

## 撤权、退出和账户更换

| 场景 | 操作与期望 |
| --- | --- |
| A 移除 B | A 从参与者列表确认移除；远端保存成功后更新名单。B 重新联网检查时禁止读写、清空界面和通知、移除本机云缓存。A 记录保留，历史成员 ID 保留用于账务。 |
| B 主动退出 | B 确认退出；远端成功才显示已退出。失败保留重试入口，不伪称完成。 |
| 系统停止共享 | 系统成功回调后立即关闭缓存访问，不再执行一次云端删除。拥有者请先导出需要保留的记录。 |
| 切换 / 退出 iCloud | 收到账户变更或确定未登录事件后立即关闭旧会话并清理云镜像，个人与家庭草稿的本地库不受影响。新账户须重新验证，不能复用旧离线授权。 |
| 临时断网 / 限流 | 同一已核验账户可继续使用此前授权的离线家庭；显示离线和最后观察值。首次未知身份不会因此获得权限。 |
| 清理中断 | 磁盘 deny 标记阻止旧离线权限恢复；下次连接先继续本地清理，再加载存储。 |

退出或更换账号前，先确认重要变更已同步或导出。失权清理会移除尚在本机的云空间镜像，已导出的文件和永久离线副本无法远程收回。

## 验收记录

请记录两端设备/系统、build、脱敏 A/B 角色、操作序列、根/记录/修订 UUID、状态和截图。无需记录 Apple ID 密码。核验任务：T01 邀请/加入、T02 私有隔离、T03 离线、T04 并发、T05 删除、T06 撤权。具体结果登记到 `docs/verification.md`。

## 实现依据

- [Apple 共享 Core Data 对象](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)：关系对象图共享及系统面板的元数据更新。
- [persistUpdatedShare](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/persistupdatedshare%3Ainpersistentstore%3Acompletion%3A)：保存 share 并等待相应 CloudKit 导出完成。
- [Mac 私有共享选项](https://developer.apple.com/documentation/appkit/nscloudsharingservicedelegate/options%28for%3Ashare%3A%29)：仅允许私有、读写邀请。

实体仍通过增量 schema 演进。真实服务的收敛、后台送达和生产 schema 尚未验证，配置好账号后继续用测试数据验收。

格式和授权实现见[架构](../architecture.md)，旧数据迁入边界见[共同与私密](../features/shared-life-design.md)。

## 独立共享实验应用

`NobisSharingSpike` 是独立 iOS 技术验证应用，不能代替主应用验收。配置独立 development 容器、团队、Bundle ID 与 entitlement，在两台不同 Apple ID 设备使用测试数据。

1. A 加载开发存储并创建一个测试家庭根。
2. A 通过系统邀请面板邀请 B；B 接受后加载 shared store，核对根已导入。
3. 双方新增传输探针，核对完整 UUID 集合；重启后再次核对。
4. A 撤销 B，观察权限与缓存事件。

Spike 支持 private/shared store、系统共享及同根对象传输，但没有主应用的完整成员映射与失权清理；不能据此放行 T06。主应用已有对应代码，真实服务验收仍未完成。实验不得使用个人正式数据或部署 production schema。
