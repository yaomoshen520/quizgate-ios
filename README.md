# quizgate-ios

孩子端的 iOS 实现。和 `quizgate-android` 打同一个后端、走同一份 `.proto`、同一套线协议。

**这个仓库只谈业务实现，不谈打包、签名和分发。**

## 生成工程并跑起来

```bash
brew install xcodegen protobuf swift-protobuf
bash tools/gen-proto.sh -ServerRoot ../anti-addiction   # 协议唯一真源在后端仓库
xcodegen generate                                       # project.yml → QuizGate.xcodeproj
open QuizGate.xcodeproj
```

`project.yml` 入仓，`*.xcodeproj/` 不入仓 —— pbxproj 是二进制级的合并灾难源。

后端地址和 App Group 只在 `project.yml` 顶部的 `settings.base` 定义一次：
`QUIZGATE_API_BASE`（当前 `http://192.168.1.76:8080`）、`QUIZGATE_APP_GROUP`。

## 目录

| 路径 | 内容 |
|---|---|
| `Kit/Sources/SharedState.swift` | 四个进程共享的唯一数据契约。三态读取（ok / absent / **corrupt**） |
| `Kit/Sources/GatePolicy.swift` | 纯函数策略引擎。不 import 任何系统管控 API，所以单测能真跑 |
| `Kit/Sources/ShieldWriter.swift` | 唯一的落盾/解盾入口，主 App 与 Monitor 共用 |
| `Kit/Sources/SelectionArchive.swift` | 不透明 token 集合的原样存取 |
| `Kit/Sources/QuizGateAPI.swift` | protobuf 出口。`post` 等响应，`fireAndForget` 不等 |
| `Kit/Sources/Outbox.swift` | 断网兜底队列，有上限 |
| `App/Sources/` | 三屏 SwiftUI + 心跳 + 监控配置 |
| `Extensions/` | Monitor / ShieldConfig / ShieldAction |

## 四条改变设计的硬约束

这四条不是实现偷懒，是 iOS 的能力边界。写代码之前先接受它们。

1. **拿不到当前前台 App。** Android 的「看着你刷视频，时间到就把手机接过来」在 iOS 上不存在。
   时长只能由聚合阈值事件推算，**精度上限就是阈值粒度**，所以首页倒计时一律写「约」。
2. **盾牌是系统固定模板，塞不进交互视图。** 答题不可能发生在盾牌里，只能发生在主 App。
3. **盾牌按钮跳不到主 App（iOS 26.5 以下）。** 社区的 URL scheme 写法实测不通。
   这里不搬未验证的 hack，改为盾牌文案直接写「打开 QuizGate，答对就能继续玩」，孩子自己去点。
   iOS 26.5 起走官方 `openParentalControlsApp`。
4. **选哪些 App 必须在这台机器上做一次。** token 不透明，不能转成 bundle id 传后端再传回来。
   所以家长后台对 iOS 设备**只能调时长，不能远端配 App 列表**。

另外两条实现约束：监控进行中不能改阈值（必须 stop → 重配 → start）；
系统最小监控粒度 15 分钟，家长配的阈值小于 15 会被抬到 15，UI 上明说，不静默抬。

## 刻意不做的

- **`graceMinutes`（宽限期）**：Android 的语义是「离开监管 App 超过 N 分钟就清零本轮」，
  前提是知道前台是哪个 App。iOS 没有这个能力，所以这一项**无对应物，不是漏做**。
- **`watched_packages` / `game_packages`**：那是 Android 包名，iOS 消费不了，
  `mapRule` 直接不收。所以协议层复用没问题，但这两项对 iOS 设备不下发。
- **游戏模式（`GameModeRule`）**：整块依赖前台检测，iOS 侧留空。
- 打包、签名、描述文件、App Store。
- 启动图标（`Assets.xcassets` 里还没有图标资源）。

## 还没真机验证过的（别当结论用）

- `eventDidReachThreshold` 的漏报率与延迟量级；主 App 被杀后还触发吗。
  代码按「**可能不来、也会重复来**」写：来不去重会重复计时，不来靠主 App 每 30 秒拉后端兜底。
- extension 的内存/执行时间上限具体数值。
- token 归档后隔几天 / 换设备 / 重装是否还能解码。官方新增了 `tokensDidExpire`，
  触发条件没写。
- 授权被家长撤回后状态不刷新（社区结论是**要重启 App** 才更新）。

## 协议口径

和 Android 完全一致，没有 JSON 层：

```
POST {base}/api/device/{enroll,next-question,answer,usage,heartbeat,gate-event}
Content-Type: application/x-protobuf
Accept:       application/x-protobuf
X-Quizgate-Token: <enroll 拿到的设备令牌>
```

401/403 收敛成「必须重新 enroll」，重试没有意义。
心跳的 `accessibility_connected` 在 iOS 上映射成「闸门有没有能力执行」——语义等价，
但**服务端告警文案对 iOS 设备需要另写**，不能照搬「无障碍已关闭」。

## 一个仓库一个客户端

| 仓库 | 端 |
|---|---|
| `quizgate-ios`（本仓库） | iOS 孩子端唯一事实源 |
| `quizgate-android` | Android 孩子端 |
| `quizgate-harmony` | 鸿蒙 NEXT 孩子端 |
| `quizgate-server` | 后端；`proto/quizgate.proto` 是全项目协议的唯一真源 |
| `quizgate-console` | 家长后台 |

`quizgate-android` 的 `ios` 分支里曾有第二套 iOS 客户端（手写 `Proto.swift` 解码器、`Package.swift` + SPM 单 target、
无 FamilyControls/DeviceActivity/扩展）。2026-11-09 只把它三条**语义**并进来，脚手架不并：

- `QuizGateAPI.checked()`：200 之后先认 `Content-Type: application/x-protobuf`、再卡 2 MiB 大小上界，
  才把字节交给解析器。`post` 和新增的 `postRaw`（补发队列用）共用这一条校验。
- `OutboxStore.acknowledged(events:replyData:)`：**http 200 不等于这一条已经记账**，
  必须 `accepted + duplicated` 覆盖到本批条数才允许出队（`duplicated` 算数，重传本就靠服务端按 `event_id` 去重）。
- `AppModel.flushOutbox()`：`deviceBound == false` 时不发。未绑定的事件会以「没有孩子档案」落库，
  家长认领之后追不回来；留着晚发只会多等一轮，删早了就是丢数据。

没有并进来的，以及原因：

- **他的 `Proto.swift` 手写解码器**：我们走 `protoc --swift_out`，生成物由 `tools/gen-proto.sh` 从服务端那份
  `.proto` 现生成、不入库。手写解码器要自己维护字段号，正是最容易和后端对不上的那种代码。
- **他的 `Tests/…/Fixtures/wire.json` 金样测试**：那 22 个样本是给手写解码器兜底的；
  protoc 生成的代码不存在同一类漂移风险，真正的漂移点是「仓库里那份 `.proto` 快照过期」，
  那个由 `gen-proto.sh -ServerRoot` 管。留作后续项，不在这轮补。
- **他的 `normalizeAddress`**：本仓库的后端地址来自 `QUIZGATE_API_BASE`（build setting，家长不输入），
  没有可校验的用户输入口。这同时是**一个已知缺口**：Release 包换后端地址要重新编译，
  和 Android 那边「Release 没有设后端地址的入口」是同一个问题。
- **`applyExtension` / `extensionStatus`（游戏延期审批）**：他那里也只是接口封装，没有用量生产者；
  iOS 侧前台检测能力缺失（见上面硬约束 1），接上就是承诺一件证明不了的事。

`usage` 路径在协议里存在，但 iOS 客户端目前**一条用量都不发**（只有 `gate-event`）。
家长后台的 iOS 设备报表为空是预期行为，不是丢数据。