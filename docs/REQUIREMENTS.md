# QuizGate iOS 孩子端 · 需求与拦截方案

## 1. 目标需求（硬需求，不可让步）

家长在后台设定某个 App（当前靶子＝红果短剧）后：

1. 孩子**正在使用该 App**时，累计时长到阈值；
2. **必须当场把该 App 拦下来 / 挡住**，逼孩子答题；
3. 答对才解锁放行。

> 「到点发一条通知提醒」不满足需求——已明确否决。要的是**拦截**，不是提醒。

## 2. 平台现实（一句话）

iOS 上「拦住另一个 App」这件事，**只有两条正门**，且**两条都要付费开发者账号 + 正规签名**才能生效：

| 路线 | 机制 | 前置 | 是否需要 Apple 特批 |
|---|---|---|---|
| A · Screen Time 盾 | FamilyControls / DeviceActivity / ManagedSettings | 付费账号 + 描述文件 | **要**（Family Controls 是受限权限，逐个扩展申请，人工审核） |
| B · VPN 掐网 | NetworkExtension（Personal VPN） | 付费账号 + 描述文件 | **不要**（Personal VPN 能力自己在 Xcode 勾选即可） |

- **纯侧载（TrollStore / 越狱免签）两条都过不去强制层**：实测里系统对授权恒回 `Not Determined`、盾牌写入回读恒为空。
- 两条路的差别只在「要不要等 Apple 审批」，**不在于「要不要付费账号」**——付费账号是共同前提。

## 3. 路线 A · Screen Time 盾（现有实现，保留不删）

- 代码在 `Extensions/`（Monitor / ShieldAction / ShieldConfig）+ `Kit/Sources/`（GatePolicy / ShieldWriter）。
- 效力边界（已设备实证）：iOS 的盾在 **App 启动那一刻**判定，**不打断已经在前台跑着的那一次**；「正在看时到点立刻遮挡」是**安卓无障碍悬浮窗专属**，iOS 公开 API 无解。
- 要让这条真正拦得住，必须拿到 Apple 审批下来的 Family Controls 权限并用其重签。

## 4. 路线 B · VPN 流量限制（本次新增，先做原型）

思路：多数 App 离网即废。到点后让目标 App 的网络不通，视频/内容加载不出来，孩子被迫离开——作为**不依赖 Apple 特批**的替代拦截手段。承认它不完美。

### 4.1 三种可选实现形态

1. **`NEFilterDataProvider`（内容过滤）**——最干净，每条流能直接读 `flow.bundleIdentifier`，可对单个 App 精确放行/丢弃。
   **但只能由 MDM 配置描述文件下发**，普通 App / 消费者自装**无法激活** ⇒ 对消费产品基本排除。
2. **`NEPacketTunnelProvider`（包隧道）**——拿到的是 IP 包，**无法可靠判定属于哪个 App** ⇒ 难以「只掐红果、其它照常」。
3. **`NEAppProxyTCP/UDPProvider`（App 代理）**——按 flow 回调，可区分来源 App，对目标 App 的流直接丢弃、其余代理转发 ⇒ **最适合「限制单独一个 App 的流量」**。默认走这条做原型。

### 4.2 已知弱点（务必写进验收预期）

- 孩子可在「设置 → 通用 → VPN」关掉配置，或切蜂窝数据绕过 ⇒ 需要「检测到 VPN 被关就再弹/重连」的对峙，且受 iOS 限制。
- 效果是「画面转圈 / 加载失败」，**不是我们的答题页盖上去**；答题闭环仍需主 App 侧完成。
- App 代理需要**自建一个转发后端**，否则「代理所有流量」会变成「全部断网」。
- App Store 审核对「用 VPN 能力做内容屏蔽而非真正 VPN」有被拒风险（属审核政策，非技术不可能）。

## 5. 决策与下一步

1. **先花一次构建做「可行性探测」**，再投 VPN 开发量：在越狱/侧载靶机上调用 `NEVPNManager.current().saveToPreferences` 写一条最小 VPN 配置，看系统认不认注入的 Personal VPN entitlement。
   - 存成功 ⇒ 侧载下 VPN 有戏，继续做 App 代理原型；
   - 报「missing entitlement / not authorized」⇒ VPN 同样必须付费账号 + 描述文件，回到「要不要办账号」这个总前提。
2. 探测通过后，按 `NEAppProxyProvider` 做「按 App 掐网」原型，复用现有规则下发与心跳通道。

## 6. 范围外（本轮不做，登记备查）

- 服务端 / 家长后台（Vue）改动——仍按冻结约定不推。
- 协议 proto 变更——冻结。
