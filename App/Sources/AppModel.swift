import Combine
import FamilyControls
import Foundation
import QuizGateKit
import SwiftUI
import UIKit

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
    @Published var selection = FamilyActivitySelection()
    @Published var showSelectionPicker = false
    @Published var monitoringNote: String?

    /// 自测用 .individual（不需要 Family Sharing 折腾），上线用 .child。
    /// 做成开关是因为 .child 的系统弹窗要家长在同一家庭组里点，调试时很难反复触发。
    @Published var useChildAuthorization = true

    private let monitoring = MonitoringController()
    private var heartbeatTask: Task<Void, Never>?
    private var signal: DarwinSignal?

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
        startObserving()
        ensureMonitoringArmed()
        Task { await enrollIfNeeded() }
        startHeartbeat()
    }

    /// 前台补一次体检：本轮大概还活着就不动，只有确认过期/没记录才重配。
    ///
    /// 为什么不能无条件重配：每轮一个新活动名 = 系统计数器从头开始，
    /// 「打开 App 就重新计时」如果成立，孩子反复点开我们的 App 就能让阈值永远攒不满。
    /// 重配只该由三件事触发：家长改了规则、选完要管的 App、答对开新一轮。
    ///
    /// 判据用**轮次年龄**而不是系统的活动列表：getAllActiveActivities 在侧载环境
    /// 读得准不准我们没证过，一旦它误报「没挂上」而重配又照它走，误报就成了绕过口子。
    /// 本轮区间最长寿到当天 23:59，所以 20 小时是「它必然已经过去了」的上界。
    private func ensureMonitoringArmed() {
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

    private func reload() {
        switch StateStore.load() {
        case .ok(let loaded):
            state = loaded
        case .absent:
            state = SharedState()
            StateStore.save(state)
        case .corrupt(let reason):
            // 存坏了不重置：重置会抹掉 shieldApplied，等于替孩子开门。
            banner = "本地状态读不出来（\(reason)），盾牌保持原样，请连一次服务器修复"
        }
        if let restored = SelectionArchive.decode(state.selectionData) {
            selection = restored
        }
    }

    private func startObserving() {
        let s = DarwinSignal()
        s.onSignal = { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        s.start()
        signal = s
    }

    // MARK: - 登记与绑定

    func enrollIfNeeded() async {
        guard state.deviceToken == nil, let api else { return }
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
        } catch let error as ReportUnavailable {
            banner = error.message
        } catch {
            banner = "登记失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 授权与选 App（一次性本机 setup）

    func requestAuthorization() async {
        busy = true
        defer { busy = false }
        do {
            let member: FamilyControlsMember = useChildAuthorization ? .child : .individual
            try await AuthorizationCenter.shared.requestAuthorization(for: member)
            state.authorization = AuthorizationState(raw: "approved", checkedAtMs: state.nowMs())
            persist()
            banner = nil
        } catch {
            state.authorization = AuthorizationState(raw: "denied", checkedAtMs: state.nowMs())
            state.recordFault("授权被拒：\(error.localizedDescription)")
            persist()
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
                persist()
            case .noSelection:
                state.monitoringActivity = nil
                state.monitoringStartedAtMs = nil
                persist()
                monitoringNote = "还没选要管的 App"
            case .ruleDisabled:
                state.monitoringActivity = nil
                state.monitoringStartedAtMs = nil
                persist()
                monitoringNote = "家长关掉了闸门，或阈值是 0"
            }
        } catch {
            monitoringNote = "监控配置失败：\(error.localizedDescription)"
            state.recordFault(monitoringNote ?? "监控配置失败")
            persist()
            reportGateEvent(kind: .gateInterrupted, detail: monitoringNote ?? "监控配置失败")
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
            await flushOutbox()
        } catch let error as ReportUnavailable {
            if error.needsReenroll {
                state.deviceToken = nil
                state.bindCode = nil
                persist()
                await enrollIfNeeded()
            }
            // 连不上不改盾牌：保持现状比瞎猜安全。
        } catch {
            state.recordFault("心跳失败：\(error.localizedDescription)")
        }
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
                return
            }
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
        } catch let error as ReportUnavailable {
            banner = error.message
        } catch {
            banner = "判分失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 上报兜底

    private func flushOutbox() async {
        guard let token = state.deviceToken, let api, let defaults = AppGroup.defaults else { return }
        let items = OutboxStore.load(from: defaults)
        guard !items.isEmpty else { return }
        var sent: Set<String> = []
        for item in items.prefix(20) {
            guard let url = URL(string: "\(AppGroup.apiBase ?? "")/api/device/\(item.path)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = item.payload
            request.setValue(QuizGateAPI.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(QuizGateAPI.contentType, forHTTPHeaderField: "Accept")
            request.setValue(token, forHTTPHeaderField: QuizGateAPI.tokenHeader)
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    sent.insert(item.id)
                }
            } catch {
                continue
            }
        }
        if !sent.isEmpty { OutboxStore.remove(ids: sent, from: defaults) }
    }

    // MARK: - 内部

    private func reconcileShield() {
        let current = decision
        var mutated = state
        if ShieldWriter.reconcile(decision: current, state: &mutated) {
            state = mutated
            if case .cannotEnforce(let why) = current {
                banner = "闸门现在拦不住 App：\(label(why))"
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