import Combine
import FamilyControls
import Foundation
import NetworkExtension
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
    // includeEntireCategory=true：iOS 选择器会把单选 App 悄悄合并成分类令牌（kingstinct #95），
    // 而分类令牌落盾会被系统拒收（实测回读 nil）。这个开关让选择器即使合并成分类，
    // 也把分类里的 App 令牌一并吐出来，好让我们走「按 App 落盾」这条系统认的主路径。
    @Published var selection = FamilyActivitySelection(includeEntireCategory: true)
    @Published var showSelectionPicker = false
    @Published var monitoringNote: String?
    /// 通知权限的原始状态，不是 Bool：「还没问过」还能自己弹一次窗，
    /// 「被拒过」在 App 里永远点不出来，两格要走的两颗按钮完全不同。
    @Published var promptStatus: UNAuthorizationStatus?

    /// 自测用 .individual（不需要 Family Sharing 折腾），上线用 .child。
    /// 做成开关是因为 .child 的系统弹窗要家长在同一家庭组里点，调试时很难反复触发。
    @Published var useChildAuthorization = true

    private let monitoring = MonitoringController()
    private var heartbeatTask: Task<Void, Never>?
    private var signal: DarwinSignal?

    /// 上一次已经写进诊断日志的那个决策形态。
    /// 只用来把「30 秒一次的心跳」压成「状态变了才记一行」，所以刻意不落盘。
    private var lastLoggedDecision: String?

    /// 上一次因为盾牌状态而给孩子发过提示没有。同上，只在翻转的那一次动手，
    /// 否则每 30 秒一次心跳就往通知中心塞一条。
    private var lastPromptedShield: Bool?

    /// VPN 探测当前该跑第几份配置；见 probeVpnArm 里那道量具闸的说明（调试，查完整段删）。
    private var vpnProbeSeq = 0

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
        ShieldPrompt.onOpenQuiz = { [weak self] in
            // 通知被点开 = 孩子终于走到了答题入口。这里只取题，不解盾：
            // 解盾必须答对，答对了才有那一份证据。
            Task { @MainActor in await self?.loadQuestion() }
        }
        Task { await refreshPromptStatus() }
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
    }

    private func startObserving() {
        let s = DarwinSignal()
        s.onSignal = { [weak self] in
            Task { @MainActor in
                self?.reload()
                self?.promptForShield()
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
            case .noSelection:
                state.monitoringActivity = nil
                state.monitoringStartedAtMs = nil
                persist()
                monitoringNote = "还没选要管的 App"
                DiagLog.record("monitor", "重配跳过：还没有可管的 App 选择", level: .warn, nowMs: startedAtMs)
            case .ruleDisabled:
                state.monitoringActivity = nil
                state.monitoringStartedAtMs = nil
                persist()
                monitoringNote = "家长关掉了闸门，或阈值是 0"
                DiagLog.record("monitor", "重配跳过：规则关闭或阈值为 0", nowMs: startedAtMs)
            }
        } catch {
            monitoringNote = "监控配置失败：\(error.localizedDescription)"
            state.recordFault(monitoringNote ?? "监控配置失败")
            persist()
            reportGateEvent(kind: .gateInterrupted, detail: monitoringNote ?? "监控配置失败")
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
        do {
            let reply: Quizgate_HeartbeatReply = try await api.post(
                "heartbeat", token: token, request: request, reply: Quizgate_HeartbeatReply.self
            )
            applyServerTime(reply.serverTimeMs)
            state.deviceBound = reply.deviceBound
            if reply.ruleChanged {
                state.rule = mapRule(reply.rule)
                reconfigureMonitoring()
            }
            state.lastSyncAtMs = state.nowMs()
            reconcileShield()
            persist()
            promptForShield()
            logHeartbeat(reply.ruleChanged)
            await flushOutbox()
            await flushLogs()
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
        var request = Quizgate_NextQuestionRequest()
        // 年级一律留 0，让服务端按 child_profile 决定（它那边 grade<=0 就回退到孩子真实年级）。
        // 设备里那个 childGrade 从来没有任何地方给它赋过值，永远是默认 3——带着 3 去抽题，
        // 5 年级的题库一条也命中不了，服务端只会回一个没有题的应答。设备猜不到，就别猜。
        request.knowledgePoint = state.ledger.lastKnowledgePoint ?? ""
        request.excludeQuestionID = state.ledger.lastQuestionId ?? ""
        do {
            let reply: Quizgate_NextQuestionReply = try await api.post(
                "next-question", token: token, request: request, reply: Quizgate_NextQuestionReply.self
            )
            applyServerTime(reply.serverTimeMs)
            state.rule = mapRule(reply.rule)
            persist()
            // 「服务端没题可给」和「给了一道题」是两个世界：没有这道判断时，空应答会被当成
            // 一道题渲染——空白题干、四个空选项，孩子点哪都算错。
            guard reply.hasQuestion else {
                banner = "这孩子的题库里没有核对过的题，请家长先录题"
                DiagLog.record("quiz", "取题空手而回：服务端没给题（请求 kp=" + request.knowledgePoint + "）",
                               level: .warn, nowMs: state.nowMs())
                return
            }
            DiagLog.record("quiz", "取到题 id=" + reply.question.questionID
                               + " kp=" + reply.question.knowledgePoint,
                           nowMs: state.nowMs())
            question = reply.question
            explanation = nil
            answeredCorrect = false
        } catch let error as ReportUnavailable {
            banner = error.message
        } catch {
            banner = "取题失败：\(error.localizedDescription)"
        }
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

    /// VPN 可行性探测（调试，查完整段删）。侧载包里注入的 Personal VPN entitlement
    /// 系统认不认，唯一判据就是 saveToPreferences 成不成。
    ///
    /// 上一枚包（7d0cbb9）交的是「什么都没设」的 IKEv2，系统回 NEVPNErrorDomain code=1
    /// 「Unsupported authenticationMethod」——那是配置校验层的说法，回答不了权限层：
    /// 校验到底排在 entitlement 检查之前还是之后，我没有任何官方原文可凭，只能自己劈变量。
    /// 一次点击连打三份配置，每份只动一个字段：
    /// A/B 任一存成功 ⟹ 权限层认这枚注入的 entitlement，直接开 App 代理原型；
    /// 三份全败但报错字段在变（authenticationMethod → identity → …）⟹ 还卡在配置层，
    /// 必须再编一枚「删掉 entitlement」的对照包才能把两种失败分开；
    /// C 是上一轮形状的原样复现，兼作「这枚包真在跑新代码」的对照。
    func debugProbeVpn() {
        // A：只关掉扩展认证。文档写明 authenticationMethod=.none 时只要
        // useExtendedAuthentication 为真就仍会协商扩展认证，而它的默认值我没拿到原文，
        // 所以先单独把这个开关拨到关，看报错是不是就消失了。
        let a = NEVPNProtocolIKEv2()
        a.serverAddress = "quizgate-probe.invalid"
        a.useExtendedAuthentication = false

        // B：把认证方式显式设成 IKEv2 认的值，并补上两个标识符。
        // 没有身份数据是故意的 —— 若报错从「认证方式」挪到「身份/证书」那一格，
        // 就说明校验器是逐字段走的，上一轮的报错纯属配置。
        let b = NEVPNProtocolIKEv2()
        b.serverAddress = "quizgate-probe.invalid"
        b.useExtendedAuthentication = false
        b.authenticationMethod = NEVPNIKEAuthenticationMethod.certificate
        b.localIdentifier = "quizgate-probe"
        b.remoteIdentifier = "quizgate-probe"

        // C：上一枚包的原样，做对照。
        let c = NEVPNProtocolIKEv2()
        c.serverAddress = "quizgate-probe.invalid"

        // 再点一次就从头再跑，方便连点两轮对拍。
        vpnProbeSeq = 0
        probeVpnArm(["A-扩展认证关", "B-显式证书认证", "C-上一轮原样"], [a, b, c], 0)
    }

    /// 逐份存、逐份记，跑完就停。三份共用 `NEVPNManager` 这一个槽位，所以必须串行：
    /// 并发提交的话后一份会盖掉前一份，日志就分不清是哪份配置的结果。
    ///
    /// 那道 seq 闸不是保险丝而是量具：上一轮一次点击落了 36 行同文案日志，
    /// 「手指连点」和「系统把同一个 completionHandler 投递了多次」两种解释我分不开。
    /// 后者对串行递归是致命的（每份配置的重复回调都会再往下开一份，指数放大），
    /// 所以这里只让「当前该跑的那一下」往下走，多余的回调原样记一行丢在日志里 ——
    /// 真投回来的次数就写在 tag=vpn 里，不用再猜。
    private func probeVpnArm(_ labels: [String], _ protos: [NEVPNProtocol], _ i: Int) {
        if i >= protos.count { return }
        guard i == vpnProbeSeq else {
            DiagLog.record("vpn", "arm=" + labels[i] + " 第" + String(i)
                               + "份重复回调，已丢弃（期望 seq=" + String(vpnProbeSeq) + "）",
                           level: .warn)
            return
        }
        vpnProbeSeq = i + 1
        let manager = NEVPNManager.shared()
        manager.`protocol` = protos[i]
        manager.isEnabled = false
        manager.saveToPreferences { err in
            let e = err as NSError?
            let line = e == nil
                ? "存 VPN 配置成功：系统认这枚 Personal VPN entitlement"
                : "存 VPN 配置失败 domain=" + e!.domain
                    + " code=" + String(e!.code)
                    + " desc=" + e!.localizedDescription
            DiagLog.record("vpn", "arm=" + labels[i] + " " + line,
                           level: e == nil ? .info : .error)
            Task { @MainActor in
                await self.flushLogs()
                self.probeVpnArm(labels, protos, i + 1)
            }
        }
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
        // watchedPackages / gameMode 刻意不收：那是 Android 包名，iOS 消费不了。
        RuleState(
            thresholdMinutes: Int(snapshot.thresholdMinutes),
            dailyLimitMinutes: Int(snapshot.dailyLimitMinutes),
            graceMinutes: Int(snapshot.graceMinutes),
            enabled: snapshot.enabled,
            version: snapshot.version
        )
    }

    private func applyServerTime(_ serverMs: Int64) {
        guard serverMs > 0 else { return }
        state.clockOffsetMs = serverMs - Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func persist() {
        if !StateStore.save(state) {
            banner = "本地状态写入失败，闸门可能记不住这一轮"
        }
        DarwinSignal.post()
    }
}