import Combine
import FamilyControls
import Foundation
import QuizGateKit
import SwiftUI
import UIKit
import UserNotifications

/// 主 App 的状态中枢。放行判定和账本**只在这里做**，extension 只负责落盾和吼一声。
/// 原因：extension 里发网络只能 fire-and-forget，等不了响应，做不了「答对没有」这种判定。
@MainActor
final class AppModel: ObservableObject {

    @Published var state = SharedState()
    @Published var busy = false
    @Published var banner: String?
    @Published var question: Quizgate_Question?
    @Published var explanation: String?
    @Published var answeredCorrect = false
    // 答题养成：答对回包带回的积分/连对/等级/徽章，成功层显示。离线本地判分没有这一份（achievement=nil）。
    @Published var pointsEarned: Int32 = 0
    @Published var achievement: Quizgate_AchievementState?
    @Published var newBadges: [String] = []
    // includeEntireCategory=true：iOS 选择器会把单选 App 悄悄合并成分类令牌（kingstinct #95），
    // 而分类令牌落盾会被系统拒收（实测回读 nil）。这个开关让选择器即使合并成分类，
    // 也把分类里的 App 令牌一并吐出来，好让我们走「按 App 落盾」这条系统认的主路径。
    @Published var selection = FamilyActivitySelection(includeEntireCategory: true)
    @Published var showSelectionPicker = false
    @Published var monitoringNote: String?
    /// 通知权限的原始状态，不是 Bool：「还没问过」还能自己弹一次窗，
    /// 「被拒过」在 App 里永远点不出来，两格要走的两颗按钮完全不同。
    @Published var promptStatus: UNAuthorizationStatus?
    /// 到点提示排没排进系统、排在几分钟后。首页那一行用它。
    ///
    /// 这一格必须有：「提示不准时」和「压根没排上」在家长后台长得一模一样，
    /// 而这两件事的修法完全不同（前者是通道天花板，后者是权限没给）。
    @Published var promptNote = "到点提示还没排"

    /// VPN 掐网通道的最新一句话，直接由 VpnCutoff 喂。首页那一行和 tag=vpn 日志同源。
    @Published var vpnNote = "VPN 通道还没试过"

    /// 交给隧道的那一档，和上面那一行分两格：上面那行说的是「系统在不在吸包」这条通道
    /// 起没起起来，这一格说的是「判定要哪一档」。分开是必需的 —— 常连之后这两件事
    /// 第一次会不一致（隧道已连接、这一档还是放行），合在一行就成了「VPN 图标亮了却没拦」。
    @Published var vpnRouteNote = "这一档还没算过"

    /// 上报通道的最新一句话，首页页脚那一行。Android 那边是 `ReportState.describe()`，
    /// 两端文案逐字相同（「连接正常，没有待发的事件」/「还没试过上报」）。
    ///
    /// iOS 这一格是从两个已知事实推出来的，不是照抄 Android 的落盘记号：
    /// 队列里还压着几条 + 心跳成功过没有。**推不出「上次尝试失败了」**——
    /// 那种情况 iOS 没有落盘的记号，所以宁可不说，也不编一个"没发出去"的理由。
    @Published var channelNote = "还没试过上报"
    /// 页脚那一行该不该换成注意色。判据是"队列里还压着东西"，不是去读那句人话的开头。
    @Published var channelBacklogged = false

    /// 自测用 .individual（不需要 Family Sharing 折腾），上线用 .child。
    /// 做成开关是因为 .child 的系统弹窗要家长在同一家庭组里点，调试时很难反复触发。
    @Published var useChildAuthorization = true

    private let monitoring = MonitoringController()
    private let cutoff = VpnCutoff()
    private var heartbeatTask: Task<Void, Never>?
    private var signal: DarwinSignal?

    /// 上一次已经写进诊断日志的那个决策形态。
    /// 只用来把「30 秒一次的心跳」压成「状态变了才记一行」，所以刻意不落盘。
    private var lastLoggedDecision: String?

    /// 上一次因为盾牌状态而给孩子发过提示没有。同上，只在翻转的那一次动手，
    /// 否则每 30 秒一次心跳就往通知中心塞一条。
    private var lastPromptedShield: Bool?

    /// 一轮监控区间的寿命上界：本轮 schedule 最长寿到当天 23:59，所以超过 20 小时
    /// 就一定已经过去了，该重配。ensureMonitoringArmed 用它判旧。
    private static let monitoringCycleHorizonMs: Int64 = 20 * 3_600_000

    var api: QuizGateAPI? {
        guard let base = AppGroup.apiBase else { return nil }
        return QuizGateAPI(base: base)
    }

    var decision: GateDecision {
        GatePolicy.decide(state, nowMs: state.nowMs())
    }

    // MARK: - 启动

    func onAppear() {
        reload()
        promptForShield()
        startObserving()
        ensureMonitoringArmed()
        Task { await enrollIfNeeded() }
        startHeartbeat()
        startRemoteStream()
        ShieldPrompt.onOpenQuiz = { [weak self] in
            // 通知被点开 = 孩子终于走到了答题入口。这里只取题，不解盾：
            // 解盾必须答对，答对了才有那一份证据。
            Task { @MainActor in await self?.loadQuestion() }
        }
        Task { await refreshPromptStatus() }
        cutoff.onChange = { [weak self] text in
            Task { @MainActor in self?.vpnNote = text }
        }
        // 首屏先翻译一次当前判定，再把系统那边的现状读一遍。
        // 这两步分开是有原因的：apply 只在「想要的」和「上次落地的」不一致时动手，
        // 而设备重启/家长在设置里手动关掉 VPN 之后，这两者会不一致地对不上账。
        syncVpnCutoff()
        cutoff.refresh(nowMs: state.nowMs())
    }

    /// 前台补一次体检：本轮大概还活着就不动，只有确认过期/没记录才重配。
    ///
    /// 为什么不能无条件重配：每轮一个新活动名 = 系统计数器从头开始，
    /// 「打开 App 就重新计时」如果成立，孩子反复点开我们的 App 就能让阈值永远攒不满。
    /// 重配只该由三件事触发：家长改了规则、选完要管的 App、答对开新一轮。
    ///
    /// 判据用**轮次年龄**而不是系统的活动列表（center.activities）：它在侧载环境
    /// 读得准不准我们没证过，一旦它误报「没挂上」而重配又照它走，误报就成了绕过口子。
    /// 本轮区间最长寿到当天 23:59，所以 20 小时是「它必然已经过去了」的上界。
    ///
    /// 不是 private：后台重挂那条通道（`BackgroundRefresh`）跑的是同一套判据。
    /// 两处各写一套「什么叫过期」，后台就会在前台明明正确的情况下把还活着的区间重配掉，
    /// 而「重新计时」恰恰是孩子最想要的那件事。
    func ensureMonitoringArmed() {
        // 还没拿到规则就先什么都不做：enroll/心跳拿到规则之后自己会重配。
        // 这里不重配是为了别在首次安装就把首页写成「家长关掉了闸门」那种误导话。
        guard state.rule != nil else { return }
        if let started = state.monitoringStartedAtMs, state.monitoringActivity != nil {
            let ageMs = state.nowMs() - started
            if ageMs >= 0 && ageMs < Self.monitoringCycleHorizonMs { return }
        }
        reconfigureMonitoring()
    }

    func onDisappear() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        signal?.stop()
        signal = nil
    }

    /// 从 App Group 重新读一份现场。不是 private：后台重挂那条通道也要走同一份读法。
    func reload() {
        switch StateStore.load() {
        case .ok(let loaded):
            state = loaded
        case .absent:
            state = SharedState()
            StateStore.save(state)
        case .corrupt(let reason):
            // 存坏了不重置：重置会抹掉 shieldApplied，等于替孩子开门。
            banner = "本地状态读不出来（\(reason)），盾牌保持原样，请连一次服务器修复"
            DiagLog.record("state", "本地状态读不出来：" + reason + "，盾牌保持原样", level: .error)
        }
        if let restored = SelectionArchive.decode(state.selectionData) {
            // includeEntireCategory 是 let，只能在 init 时定；旧存档是 false（红果被合并成
            // 了分类令牌）。重建一份 true 的并搬回令牌，下次「重新选择」时选择器才会把
            // 分类里的 App 令牌吐出来。令牌本身不会被这一步展开，必须家长再选一次。
            var expanded = FamilyActivitySelection(includeEntireCategory: true)
            expanded.applicationTokens = restored.applicationTokens
            expanded.categoryTokens = restored.categoryTokens
            expanded.webDomainTokens = restored.webDomainTokens
            selection = expanded
        }
        refreshChannelNote()
    }

    /// 重算页脚那一行。三处调用：读盘之后、往队列里塞一条之后、心跳补发之后。
    /// 读的是 Outbox 那份 plist，所以刻意只在"队列可能变了"的时候读，不放进 body 里逐帧算。
    private func refreshChannelNote() {
        let pending = OutboxStore.load().count
        channelBacklogged = pending > 0
        if pending > 0 {
            channelNote = "还有 \(pending) 条记录没发出去，联网后自动补"
        } else if state.lastSyncAtMs != nil {
            channelNote = "连接正常，没有待发的事件"
        } else {
            channelNote = "还没试过上报"
        }
    }

    private func startObserving() {
        let s = DarwinSignal()
        s.onSignal = { [weak self] in
            Task { @MainActor in
                self?.reload()
                self?.promptForShield()
                // 扩展写完盾牌就吼这一声，VPN 必须跟着同一次判定走。
                // 少了这一跳，"系统里盾牌落下了"和"网还通着"能同时成立到下一次心跳。
                self?.syncVpnCutoff()
            }
        }
        s.start()
        signal = s
    }

    // MARK: - 答题提醒

    /// 盾牌一落就给孩子发一声，一解就把还没点的那条撤掉。
    ///
    /// 三个调用点（前台首屏、Monitor 扩展吼回来的信号、心跳）看着重复，各自都少不了：
    /// 落盾多数由扩展写盘，主 App 只被 Darwin 信号叫醒；信号在 App 被划掉时收不到，
    /// 就只剩心跳那一次；而首屏这次管的是「孩子自己打开 App，盾早就落着了」。
    /// 真正的去重靠 `lastPromptedShield`，所以多调几次只会少走一步，不会多发一条。
    func promptForShield() {
        let now = state.shieldApplied
        guard now != lastPromptedShield else { return }
        lastPromptedShield = now
        if now {
            ShieldPrompt.fire(nowMs: state.nowMs())
        } else {
            ShieldPrompt.cancel()
        }
    }

    func refreshPromptStatus() async {
        promptStatus = await ShieldPrompt.status()
    }

    /// setup 那一屏的按钮。权限只在「从没问过」时弹一次窗，之后要么去系统设置，要么已经是开的。
    func enablePrompt() async {
        await ShieldPrompt.requestPermission()
        await refreshPromptStatus()
    }

    /// 权限被拒过一次之后，App 里没有任何办法再把它要回来，只有系统设置能改。
    /// 这一颗按钮就是那条唯一的出口。
    func openPromptSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 登记与绑定

    func enrollIfNeeded() async {
        guard state.deviceToken == nil else { return }
        guard let api else {
            // 这是整条上报链最上游的那个 nil：build setting 没灌进 Info.plist 时，
            // 设备会一声不响地停在「没登记」这一步，后台里连一台设备都不会出现。
            DiagLog.record("api", "登记跳过：读不到后端地址，检查 QUIZGATE_API_BASE", level: .error)
            return
        }
        busy = true
        defer { busy = false }
        var request = Quizgate_EnrollRequest()
        request.installID = state.installId
        request.deviceModel = "\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)"
        // androidApiLevel 刻意留 0：往这个字段里塞 iOS 版本号是在协议里撒谎，
        // 服务端要区分平台应当看 deviceModel，或者以后加一个平台字段。
        do {
            let reply: Quizgate_EnrollReply = try await api.post(
                "enroll", token: nil, request: request, reply: Quizgate_EnrollReply.self
            )
            state.deviceToken = reply.deviceToken
            state.bindCode = reply.bindCode
            applyServerTime(reply.serverTimeMs)
            persist()
            // 令牌和绑定码的值一律不落进日志：这一本是要出门的，
            // 而绑定码在家长认领完成之前就是这台机器的凭据。
            DiagLog.record("api", "登记成功，已拿到设备令牌", nowMs: state.nowMs())
        } catch let error as ReportUnavailable {
            banner = error.message
            DiagLog.record("api", "登记没送到：" + error.message, level: .error)
        } catch {
            banner = "登记失败：\(error.localizedDescription)"
            DiagLog.record("api", "登记异常：" + error.localizedDescription, level: .error)
        }
    }

    // MARK: - 授权与选 App（一次性本机 setup）

    func requestAuthorization() async {
        busy = true
        defer { busy = false }
        let member: FamilyControlsMember = useChildAuthorization ? .child : .individual
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: member)
            state.authorization = AuthorizationState(raw: "approved", checkedAtMs: state.nowMs())
            persist()
            banner = nil
            DiagLog.record("auth", "授权通过 member=" + (useChildAuthorization ? "child" : "individual"),
                           nowMs: state.nowMs())
            // 顺带把答题提醒要了：这一刻家长正拿着孩子手机、正等着系统弹窗，
            // 是全程唯一一处不用额外解释「为什么还要再点一下」的时机。
            await enablePrompt()
        } catch {
            state.authorization = AuthorizationState(raw: "denied", checkedAtMs: state.nowMs())
            state.recordFault("授权被拒：\(error.localizedDescription)")
            persist()
            // 这一行是「FamilyControlsError error 2」这类问题唯一的远程读数：
            // domain + code + localizedDescription 三段分开写，才能在后端按 code 归类，
            // 也才分得开「家长点了不同意」和「侧载包的 entitlement 系统根本没认」。
            let asNSError = error as NSError
            DiagLog.record("auth",
                           "授权失败 member=" + (useChildAuthorization ? "child" : "individual")
                               + " domain=" + asNSError.domain
                               + " code=" + String(asNSError.code)
                               + " desc=" + error.localizedDescription,
                           level: .error, nowMs: state.nowMs())
            // 系统那句原因必须上屏，不能只活在故障历史里：侧载（巨魔）装的包如果
            // entitlement 没被系统认下来，唯一能区分「用户拒了」和「压根没这个权限」的
            // 就是这句话，看不到就得重来一轮。
            banner = "没有拿到屏幕使用时间授权，闸门现在拦不住任何 App（\(error.localizedDescription)）"
        }
    }

    /// 家长在孩子这台机器上选完 App 之后调。
    /// 选完必须立刻重配监控，否则系统不知道要盯哪些 App。
    func saveSelection() {
        state.selectionData = SelectionArchive.encode(selection)
        DiagLog.record("selection",
                       "选择落盘令牌 apps=" + String(selection.applicationTokens.count)
                           + " cats=" + String(selection.categoryTokens.count)
                           + " web=" + String(selection.webDomainTokens.count)
                           + " iec=" + String(selection.includeEntireCategory),
                       level: .warn)
        persist()
        reconfigureMonitoring()
    }

    func reconfigureMonitoring() {
        // 先记下这一轮的起始时刻：活动名是拿它生成的，两者必须成对落盘，
        // 否则重配失败时状态里会留下一条再也 stop 不掉的孤儿活动名。
        let startedAtMs = state.nowMs()
        do {
            let result = try monitoring.reconfigure(
                rule: state.rule, selectionData: state.selectionData,
                previousActivity: state.monitoringActivity, nowMs: startedAtMs)
            switch result {
            case .started(let step, let count, let activity, let armed):
                state.monitoringActivity = activity
                state.monitoringStartedAtMs = startedAtMs
                monitoringNote = "已按 \(step) 分钟阶梯监控（\(count) 档，本轮 \(activity)）"
                if !armed {
                    // 调用没报错、系统没登记 —— 这一句是本环境最难查的那类故障唯一的读数点。
                    monitoringNote = "系统没登记这轮监控（\(activity)）：配置调用没报错，但活动列表里查不到它，闸门可能不会触发"
                    state.recordFault(monitoringNote ?? "系统没登记这轮监控")
                    reportGateEvent(kind: .gateInterrupted, detail: monitoringNote ?? "")
                }
                // armed=false 在本地已经能看到，但家长不在孩子身边；这一行让它变成远程可读。
                DiagLog.record("monitor",
                               "重配完成 step=" + String(step) + " events=" + String(count)
                                   + " activity=" + activity + " armed=" + String(armed),
                               level: armed ? .info : .error, nowMs: startedAtMs)
                persist()
                // 到点那一声明白地排给系统，不等时刻到了再发：那一刻孩子正玩在别家 App 里，
                // 我们的进程多半已经被划掉，`promptForShield()` 那条根本跑不到。
                // 第 1 档阈值就是盾牌该落的那一刻，所以排期和落盾用的是同一个数。
                ShieldPrompt.scheduleDue(dueMs: startedAtMs + Int64(step) * 60_000, nowMs: startedAtMs)
                promptNote = "到点提示已排进系统：" + String(step) + " 分钟后（App 被划掉也照样响）"
            case .noSelection:
                state.monitoringActivity = nil
                state.monitoringStartedAtMs = nil
                persist()
                monitoringNote = "还没选要管的 App"
                ShieldPrompt.cancelDue()
                promptNote = "到点提示没排：还没选要管的 App"
                DiagLog.record("monitor", "重配跳过：还没有可管的 App 选择", level: .warn, nowMs: startedAtMs)
            case .ruleDisabled:
                state.monitoringActivity = nil
                state.monitoringStartedAtMs = nil
                persist()
                monitoringNote = "家长关掉了闸门，或阈值是 0"
                // 闸门一关就必须把排好的那一条撤掉：留着就是「明明不拦了，孩子还被催着答题」。
                ShieldPrompt.cancelDue()
                promptNote = "到点提示没排：闸门是关的"
                DiagLog.record("monitor", "重配跳过：规则关闭或阈值为 0", nowMs: startedAtMs)
            }
        } catch {
            monitoringNote = "监控配置失败：\(error.localizedDescription)"
            state.recordFault(monitoringNote ?? "监控配置失败")
            persist()
            reportGateEvent(kind: .gateInterrupted, detail: monitoringNote ?? "监控配置失败")
            ShieldPrompt.cancelDue()
            promptNote = "到点提示没排：系统监控没配上"
            DiagLog.record("monitor",
                           "重配抛错 desc=" + error.localizedDescription
                               + " activity=" + (state.monitoringActivity ?? "nil"),
                           level: .error, nowMs: startedAtMs)
        }
    }

    /// 往 Outbox 存一条 gate-event，由心跳里的 flushOutbox 补发。
    /// 走 Outbox 而不是 fire-and-forget：这条是给家长看的证据，丢一条就少一次机会。
    private func reportGateEvent(kind: Quizgate_GateEventKind, detail: String) {
        guard let defaults = AppGroup.defaults else { return }
        var event = Quizgate_GateEvent()
        event.eventID = UUID().uuidString
        event.kind = kind
        event.occurredAtMs = state.nowMs()
        event.detail = detail
        var request = Quizgate_GateEventReportRequest()
        request.events = [event]
        guard let payload = try? request.serializedData() else { return }
        OutboxStore.enqueue(
            PendingReport(path: "gate-event", payload: payload, createdAtMs: state.nowMs()),
            to: defaults
        )
        refreshChannelNote()
    }

    // MARK: - 心跳（兜底：不赌系统回调）

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.heartbeat()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    /// 远程即时控制：共享 SSE 通道收到 quiz-now 就取题弹答题页。主 App 活着时即时收（iOS 后台天花板见 RemoteCommandStream）。
    private var remoteStream: RemoteCommandStream?
    private func startRemoteStream() {
        remoteStream?.stop()
        remoteStream = RemoteCommandStream { [weak self] in await self?.loadQuestion() }
        remoteStream?.start()
    }

    func heartbeat() async {
        guard let token = state.deviceToken, let api else { return }
        var request = Quizgate_HeartbeatRequest()
        // 这个字段在 Android 上叫「无障碍是否连着」。iOS 没有无障碍，
        // 这里映射成「闸门有没有能力执行」——语义等价（闸门在不在岗），
        // 但服务端告警文案对 iOS 设备需要另写，不能照搬「无障碍已关闭」。
        request.accessibilityConnected = decision.wantsShield || decision == .allow(.underThreshold)
        request.accumulatedMs = state.ledger.playedMs
        request.knownRuleVersion = state.rule?.version ?? 0
        request.appliedRuleVersion = state.rule?.version ?? 0
        // 家长后台那只狐狸认的是编号，不是中文文案：不报 play_state 的设备在后台永远静止。
        // 文案照旧一起报，为的是后台那张表的老列不至于因为 iOS 上线而空掉。
        let playState = currentPlayState()
        request.playState = playState.proto
        request.gameState = playState.gameStateText
        do {
            let reply: Quizgate_HeartbeatReply = try await api.post(
                "heartbeat", token: token, request: request, reply: Quizgate_HeartbeatReply.self
            )
            applyServerTime(reply.serverTimeMs)
            state.deviceBound = reply.deviceBound
            applyAvatar(reply.avatarID.rawValue)
            // 成就快照随心跳缓存：形象持久佩戴皇冠勋章，不必等答对那一跳（与安卓一致）。
            if reply.hasAchievement { achievement = reply.achievement }
            if reply.ruleChanged {
                state.rule = mapRule(reply.rule)
                reconfigureMonitoring()
            }
            state.lastSyncAtMs = state.nowMs()
            reconcileShield()
            persist()
            promptForShield()
            // 盾牌/判定之外还要续一次 VPN 的现状：startTunnel 返回时只是"受理"，
            // 扩展载没载起来落在后面那格 status 上，而心跳是唯一稳定回来的地方。
            cutoff.refresh(nowMs: state.nowMs())
            logHeartbeat(reply.ruleChanged)
            await flushOutbox()
            await flushLogs()
            // 放在两次 flush 之后、而不是 flushOutbox 里面：那条函数有四个提前 return
            // （没令牌 / 没 api / 没绑定 / 队列空），把刷新写在里面就等于"只有真发过才更新页脚"，
            // 而未绑定那一段时间恰好是家长最盯着页脚看的时候。
            refreshChannelNote()
        } catch let error as ReportUnavailable {
            if error.needsReenroll {
                state.deviceToken = nil
                state.bindCode = nil
                persist()
                await enrollIfNeeded()
            }
            // 连不上不改盾牌：保持现状比瞎猜安全。
            DiagLog.record("api", "心跳没送到：" + error.message, level: .warn)
        } catch {
            state.recordFault("心跳失败：\(error.localizedDescription)")
            DiagLog.record("api", "心跳异常：" + error.localizedDescription, level: .error)
        }
    }

    // MARK: - 后台唤醒

    /// 后台被系统叫醒时跑的那一次体检：读盘 → 心跳 → 本轮过期就重配。
    ///
    /// 三步全是前台已经在用的那几个方法，刻意不写「后台版」。心跳本身就把
    /// 拉规则、重配、重算盾牌、补 Outbox、搬日志这五件事全做完了，
    /// 后台需要多的只有最后那一道判据：孩子一整天没打开 App 时，区间已经跨过 23:59 了。
    func backgroundCheck() async {
        reload()
        await heartbeat()
        ensureMonitoringArmed()
    }

    // MARK: - 答题闭环

    func loadQuestion() async {
        guard let token = state.deviceToken, let api else {
            banner = "还没登记到服务器，先连一次网络"
            return
        }
        busy = true
        defer { busy = false }
        let exclude = state.ledger.lastQuestionId ?? ""
        var knowledgePoint = state.ledger.lastKnowledgePoint ?? ""
        var reply: Quizgate_NextQuestionReply?
        var failure = ""
        // 最多两轮：第一轮照旧要「同知识点变式题」，撞车就清空知识点再要一次。
        // 撞车 = 服务端把刚答错那道又发了一遍。这枚包要装的旧服务端确实有那条回退分支
        // （同知识点只剩一道题时宁可原题重发），孩子看到的就还是这道题，第二次靠记选项就能过。
        // 客户端先把它抹平，服务端那一版改了之后这一轮自然走不到。
        for attempt in 0..<2 {
            do {
                let got = try await fetchQuestion(api: api, token: token,
                                                  knowledgePoint: knowledgePoint, exclude: exclude)
                let sameAsMissed = got.hasQuestion && !exclude.isEmpty && got.question.questionID == exclude
                if sameAsMissed && attempt == 0 {
                    DiagLog.record("quiz", "服务端重发了刚答错那道 id=" + exclude
                                       + "，改成不限知识点再要一次", level: .warn, nowMs: state.nowMs())
                    knowledgePoint = ""
                    continue
                }
                reply = got
                break
            } catch let error as ReportUnavailable {
                failure = error.message
                break
            } catch {
                failure = "取题失败：" + error.localizedDescription
                break
            }
        }
        guard let reply else {
            // 两轮都没走到「拿到回包」这一步，说明网络那一跳就断了，banner 里已经是原因。
            if !failure.isEmpty { banner = failure }
            return
        }
        applyServerTime(reply.serverTimeMs)
        state.rule = mapRule(reply.rule)
        persist()
        // 「服务端没题可给」和「给了一道题」是两个世界：没有这道判断时，空应答会被当成
        // 一道题渲染——空白题干、四个空选项，孩子点哪都算错。
        guard reply.hasQuestion else {
            banner = "这孩子的题库里没有核对过的题，请家长先录题"
            DiagLog.record("quiz", "取题空手而回：服务端没给题（请求 kp=" + knowledgePoint + "）",
                           level: .warn, nowMs: state.nowMs())
            return
        }
        DiagLog.record("quiz", "取到题 id=" + reply.question.questionID
                           + " kp=" + reply.question.knowledgePoint,
                       nowMs: state.nowMs())
        question = reply.question
        explanation = nil
        answeredCorrect = false
    }

    /// 取题这一跳单独抽出来：换知识点重试和首发的唯一区别就是那两个入参。
    ///
    /// 年级一律留 0，让服务端按 child_profile 决定（它那边 grade<=0 就回退到孩子真实年级）。
    /// 设备里那个 childGrade 从来没有任何地方给它赋过值，永远是默认 3——带着 3 去抽题，
    /// 5 年级的题库一条也命中不了，服务端只会回一个没有题的应答。设备猜不到，就别猜。
    private func fetchQuestion(api: QuizGateAPI, token: String,
                               knowledgePoint: String, exclude: String) async throws -> Quizgate_NextQuestionReply {
        var request = Quizgate_NextQuestionRequest()
        request.knowledgePoint = knowledgePoint
        request.excludeQuestionID = exclude
        return try await api.post("next-question", token: token, request: request,
                                  reply: Quizgate_NextQuestionReply.self)
    }

    func submitAnswer(index: Int) async {
        guard let question, let token = state.deviceToken, let api else { return }
        busy = true
        defer { busy = false }
        var request = Quizgate_AnswerRequest()
        request.questionID = question.questionID
        request.selectedIndex = Int32(index)
        do {
            let reply: Quizgate_AnswerReply = try await api.post(
                "answer", token: token, request: request, reply: Quizgate_AnswerReply.self
            )
            if reply.correct {
                state.ledger.correctCount += 1
                // 答对 = 本轮清零开新一轮，和 Android 一致。不是「告诉你答案」。
                if let rule = state.rule {
                    var fresh = GatePolicy.startNewCycle(afterCorrectAt: state.nowMs(), rule: rule)
                    fresh.correctCount = state.ledger.correctCount
                    state.ledger = fresh
                }
                state.ledger.lastQuestionId = nil
                state.ledger.lastKnowledgePoint = nil
                answeredCorrect = true
                explanation = nil
                pointsEarned = reply.pointsEarned
                achievement = reply.hasAchievement ? reply.achievement : nil
                newBadges = reply.newBadges
                reconcileShield()
                reconfigureMonitoring()
            } else {
                state.ledger.wrongCount += 1
                state.ledger.lastQuestionId = question.questionID
                state.ledger.lastKnowledgePoint = question.knowledgePoint
                explanation = reply.explanation
            }
            persist()
            // 记「第几个选项、对不对、答完之后盾牌还在不在」：
            // 「答对了但屏幕还是拦着」这类问题只有对上这三段时间线才查得下去。
            DiagLog.record("quiz",
                           "判分 id=" + question.questionID + " picked=" + String(index)
                               + " correct=" + String(reply.correct)
                               + " shieldApplied=" + String(state.shieldApplied)
                               + " unlockUntil=" + String(state.ledger.unlockUntilMs ?? -1),
                           level: reply.correct ? .info : .warn, nowMs: state.nowMs())
        } catch let error as ReportUnavailable {
            banner = error.message
        } catch {
            banner = "判分失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 上报兜底

    private func flushOutbox() async {
        guard let token = state.deviceToken, let api, let defaults = AppGroup.defaults else { return }
        // 没有归属就先不发。服务端按设备令牌记账，未绑定这台设备时事件会落成
        // 「没有孩子档案」的行，家长认领之后追不回来；留在队列里等绑定完成，
        // 服务端按 event_id 去重，晚发不会重复。
        guard state.deviceBound else { return }
        let items = OutboxStore.load(from: defaults)
        guard !items.isEmpty else { return }
        var sent: Set<String> = []
        for item in items.prefix(20) {
            // 入队时一条请求只装一个事件，所以这里按 1 核对回包计数。
            guard let reply = try? await api.postRaw(item.path, token: token, body: item.payload),
                  OutboxStore.acknowledged(events: 1, replyData: reply)
            else { continue }
            sent.insert(item.id)
        }
        if !sent.isEmpty { OutboxStore.remove(ids: sent, from: defaults) }
    }

    // MARK: - 诊断日志搬运

    /// 把四个进程写的诊断日志搬给服务端。
    ///
    /// 只在心跳里搬，不是偷懒：扩展进程发网络只能 fire-and-forget，而这一条通道
    /// 必须拿到回包里的 `accepted` 才知道从盘上删几行。删多了是丢现场，删少了是重传，
    /// 只有拿到计数才能选前者之外的路 —— 所以它只能活在一个等得到响应的进程里。
    private func flushLogs() async {
        guard let token = state.deviceToken, let api else { return }
        for batch in DiagLog.pendingBatches(totalLimit: DiagLog.batchLines) {
            var request = Quizgate_DeviceLogReportRequest()
            request.lines = batch.lines.map { line in
                var out = Quizgate_DeviceLogLine()
                out.occurredAtMs = line.occurredAtMs
                out.level = line.level.proto
                out.tag = line.tag
                out.message = line.message
                return out
            }
            guard !request.lines.isEmpty else { continue }
            guard let reply: Quizgate_DeviceLogReportReply = try? await api.post(
                "log", token: token, request: request, reply: Quizgate_DeviceLogReportReply.self
            ) else {
                // 连不上就停手：后面每个文件都会撞同一面墙，白跑一轮。
                return
            }
            DiagLog.acknowledge(batch, count: Int(reply.accepted))
        }
    }

    /// 心跳每 30 秒一次。无条件记一行会把 1200 行的本地上限和上传流量
    /// 全花在「一切正常」上，而真正要留的是「这一刻闸门在拦还是在放、为什么」。
    /// 所以只在决策变了、或家长改了规则时记。
    private func logHeartbeat(_ ruleChanged: Bool) {
        let token = decision.diagToken
        guard ruleChanged || token != lastLoggedDecision else { return }
        lastLoggedDecision = token
        // 字段一段段独立写，而不是一条 `+` 链拼到底：CI 上那条 8 节的链报的是
        // "the compiler is unable to type-check this expression in reasonable time"，
        // 拆开后每一格都是单独一次类型检查。顺序就是原来那条链的顺序。
        let fields: [(String, String)] = [
            ("decision", token),
            ("ruleChanged", String(ruleChanged)),
            ("playedMs", String(state.ledger.playedMs)),
            ("unlockUntil", String(state.ledger.unlockUntilMs ?? -1)),
            ("shieldApplied", String(state.shieldApplied)),
            ("activity", state.monitoringActivity ?? "nil"),
            ("dailyDone", String(state.dailyLimitReachedOnDay ?? -1)),
            ("outbox", String(OutboxStore.load().count)),
            // 这两格是"家长后台那只狐狸为什么不动"的第一现场：编号 0/nil 就不该画，
            // 而 playState 恒为 idle 说明判定那一侧没给出动作档，不是形象的问题。
            ("avatar", String(state.avatarId ?? -1)),
            ("playState", currentPlayState().rawValue),
        ]
        DiagLog.record("app", "心跳 " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "),
                       nowMs: state.nowMs())
    }

    // MARK: - 内部

    private func reconcileShield() {
        let current = decision
        var mutated = state
        // 返回值才是事实：reconcile 内部会先问 needsShieldWrite，一致时一个字节都不动。
        // 拿 wantsShield 去报事件会把「本来就已经拦着」也报成一次新的落盾。
        if ShieldWriter.reconcile(decision: current, state: &mutated) {
            state = mutated
            reportGateEvent(kind: current.wantsShield ? .shieldApplied : .shieldCleared,
                            detail: "\(current.shieldEvidence)（主 App 重算）")
            if case .cannotEnforce(let why) = current {
                banner = "闸门现在拦不住 App：\(label(why))"
            }
        }
        // 这一行刻意在 if 外面：盾牌那一格早就落着时 reconcile 一个字节都不写，
        // 但 VPN 这条通道必须照样跟着判定走 —— 否则「系统认为在拦、网其实通着」
        // 会一路保持到孩子把 App 杀掉重开。VpnCutoff 自己那道幂等闸负责把重复指令吃掉。
        syncVpnCutoff()
    }

    /// 把「闸门此刻想不想拦」连同「什么时候该换成想拦」一起交给隧道扩展。
    ///
    /// 判据是 decision.wantsShield，不是 state.shieldApplied：后者记的是 ManagedSettings
    /// 那一格写没写进去，属旧通道。走 VPN 这条路之后真把孩子拦住的是断网，
    /// 所以这道翻译必须挂在判定上；挂在旧通道的执行结果上，等于把新通道绑死在旧通道的天花板上。
    ///
    /// 但交出去的不止当前这一档，还有本轮的到点时刻：判定只在主 App 活着的时候算得出来，
    /// 而阈值到的那一刻我们多半已经不在场。`VpnIntentPlan.build` 把这两样一起翻成排期，
    /// 扩展进程拿着自己的钟就能把这一档推进到底。
    ///
    /// cannotEnforce 那一档仍然不建隧道：它的含义是「我们连该不该拦都还不知道」，
    /// 在一台规则都没落地的新装设备上先把一条 VPN 挂起来，是把诊断期过成事故。
    private func syncVpnCutoff() {
        let serverNow = state.nowMs()
        let localNow = Int64(Date().timeIntervalSince1970 * 1000)
        let intent = VpnIntentPlan.build(state: state, decision: decision, seq: VpnIntentStore.nextSeq(),
                                         nowMs: serverNow, localNowMs: localNow)
        cutoff.sync(intent: intent, nowMs: serverNow)
        // 一格一格先算成独立的 let，最后才拼句子：三元表达式里直接写多段 `+` 拼接，
        // 上一版 CI 报的是 "the compiler is unable to type-check this expression in reasonable time"，
        // 而那句话会把整个 target 编挂，指不到是哪一行。
        let want = intent.route(atLocal: localNow).label
        let left = String((intent.cutoffAtLocalMs - localNow) / 60_000)
        let armedNote = "这一档：" + want + "（到点还有 " + left + " 分钟）"
        let offNote = "这一档：闸门没开，隧道不常驻"
        vpnRouteNote = intent.armed ? armedNote : offNote
    }

    /// 手动试一次掐网/放行（调试，查完整段删）。
    ///
    /// 为什么要有这两颗按钮：本轮要问系统的是「放行档那份一个包都不吸的设置，系统认不认」，
    /// 而正常路径要等阈值攒满才第一次看到掐网档。真机上把这一等压成一次点击，读数当天就能拿到。
    ///
    /// 走 forceSync：上一轮起隧道失败之后那本幂等账会留在旧值上，不绕开的话这颗按钮什么都不做。
    func debugVpnCutoff(_ wantsCutoff: Bool) {
        let serverNow = state.nowMs()
        let localNow = Int64(Date().timeIntervalSince1970 * 1000)
        let intent = VpnIntentPlan.debug(cutoff: wantsCutoff, seq: VpnIntentStore.nextSeq(),
                                         nowMs: serverNow, localNowMs: localNow)
        cutoff.forceSync(intent: intent, nowMs: serverNow)
        let debugWant = intent.route(atLocal: localNow).label
        let debugNote = "调试档：" + debugWant + "（下一次心跳会按真排期改写）"
        vpnRouteNote = debugNote
    }

    // MARK: - 落盾诊断（侧载执行层取证，调试用，查完整段删）

    /// 强制从主 App 前台写一次盾并回读，绕过 reconcile 的幂等闸：
    /// state.shieldApplied 已为 true 时 reconcile 一个字节都不写，取不到写后回读的现场。
    func debugForceShield() {
        let applied = ShieldWriter.apply(selectionData: state.selectionData) == .applied
        state.shieldApplied = applied
        persist()
        DiagLog.record("shield", "主App强制落盾 applied=\(applied)", level: .warn)
        Task { await flushLogs() }
    }

    /// 清盾对照。和强制落盾成对：能落就能清，调试不会把设备永久锁死。
    func debugClearShield() {
        ShieldWriter.clear()
        state.shieldApplied = false
        persist()
        DiagLog.record("shield", "主App清盾", level: .warn)
        Task { await flushLogs() }
    }

    private func label(_ reason: CannotEnforceReason) -> String {
        switch reason {
        case .notAuthorized: return "还没拿到屏幕使用时间授权"
        case .noSelection: return "还没选要管的 App"
        case .noRule: return "还没从服务器拿到规则"
        case .stateCorrupt: return "本地状态读不出来"
        }
    }

    private func mapRule(_ snapshot: Quizgate_RuleSnapshot) -> RuleState {
        // watchedPackages / gameMode 的其余字段刻意不收：那是 Android 包名与延期审批，
        // iOS 消费不了。warningSeconds 是例外——它是"还剩多久到阈值"的判据，
        // 只依赖规则本身，不依赖前台是哪个 App，所以 iOS 也用得上。
        RuleState(
            thresholdMinutes: Int(snapshot.thresholdMinutes),
            dailyLimitMinutes: Int(snapshot.dailyLimitMinutes),
            graceMinutes: Int(snapshot.graceMinutes),
            enabled: snapshot.enabled,
            version: snapshot.version,
            warningSeconds: Int(snapshot.gameMode.warningSeconds)
        )
    }

    /// 家长后台那只狐狸和本机这只狐狸共用的那一档「孩子此刻在干嘛」。
    ///
    /// 判据只有三样：屏幕上有题、闸门想不想落盾、这一轮监控起了没有。
    /// Android 那套「哪个 App 在前台」在这里没有对应物——iOS 拿不到前台包名，
    /// 所以映射顺序与 Android 差一格，理由写在 AvatarPlayPolicy 里。
    func currentPlayState() -> AvatarPlayState {
        AvatarPlayPolicy.decide(state, decision: decision,
                                questionOnScreen: question != nil, nowMs: state.nowMs())
    }

    /// 心跳每次都带形象，所以这里先比一次再写：无脑写一遍 state 就是一轮落盘，
    /// 而这个值一年也变不了几次。
    ///
    /// 传进来的是 rawValue 而不是枚举本身：万一以后服务端加了第 8 档而这份生成物还不认，
    /// swift-protobuf 给出的是 UNRECOGNIZED，问它要 rawValue 拿到的仍是那个编号，不会崩。
    private func applyAvatar(_ number: Int) {
        guard number != state.avatarId else { return }
        state.avatarId = number
        persist()
        // 0 是 AVATAR_UNSPECIFIED，含义是「家长还没选过」而不是「没有形象」：
        // 这时首页必须退回昵称首字头像，不能默认弹一只狐狸。这一条要连 0 一起记，
        // 否则以后查「为什么这台设备没有狐狸」时没有源头可看。
        DiagLog.record("app", number == 0 ? "家长没选形象，首页退回昵称头像" : "家长换了形象，编号 \(number)",
                       nowMs: state.nowMs())
    }

    private func applyServerTime(_ serverMs: Int64) {        guard serverMs > 0 else { return }
        state.clockOffsetMs = serverMs - Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func persist() {
        if !StateStore.save(state) {
            banner = "本地状态写入失败，闸门可能记不住这一轮"
        }
        DarwinSignal.post()
    }
}