import DeviceActivity
import Foundation
import QuizGateKit

/// 系统级看门狗。主 App 被孩子杀掉之后，只有这个进程还能落盾。
///
/// 设计前提（来自社区实测，不是文档承诺）：
/// - eventDidReachThreshold **可能不来**（高频未根治问题），所以它只是加速器，不是唯一依据；
///   真正的兜底是主 App 前台时定时拉后端重算。
/// - 它**也会重复来**，所以每个事件都要按 id 去重。
/// - 回调一返回进程随时结束，网络只能 fire-and-forget，重要上报进 Outbox 由主 App 补。
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        recompute(reason: "intervalDidStart(\(activity.rawValue))")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        recompute(reason: "intervalDidEnd(\(activity.rawValue))")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        // 日限额那条活动写的是「今天用完了」这个事实，不是时长。
        // 它不进去重集：标记本身就是幂等的（同一个日序号写两次同一个值），
        // 而去重集是有上限的滚动窗口，把日限额也塞进去会有一天被挤掉的空间。
        if activity.rawValue == MonitoringNames.dayActivity {
            StateStore.mutate { state in
                state.dailyLimitReachedOnDay = GatePolicy.dayIndex(state.nowMs())
            }
            DiagLog.record("monitor", "日限额活动回调 \(activity.rawValue)")
            recompute(reason: "eventDidReachThreshold(dailyLimit)")
            return
        }

        // 事件按「活动名 + 事件名 + 天」去重。活动名带本轮起点毫秒，
        // 所以答对开新一轮之后是全新的一批 id，不会再被上一轮的记录吃掉。
        var counted = false
        let result = StateStore.mutate { state in
            let eventId = "\(activity.rawValue)|\(event.rawValue)|\(GatePolicy.dayIndex(state.nowMs()))"
            let step = state.rule?.thresholdMinutes ?? 0
            counted = GatePolicy.shouldProcess(eventId: eventId, state: state)
            state = GatePolicy.accumulate(state, thresholdMinutes: step, eventId: eventId)
        }
        // 这一行是「回调到底有没有来」唯一的读数：记 event 名和它有没有被计入。
        // 不记这一句，「阈值没触发」和「触发了但被去重吃掉」在日志里长得一样。
        DiagLog.record("monitor",
                       "阈值回调 event=\(event.rawValue) activity=\(activity.rawValue) counted=\(counted)")
        guard case .ok = result else { return }
        recompute(reason: "eventDidReachThreshold(\(event.rawValue))")
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name,
                                                 activity: DeviceActivityName) {
        // 预警只记一笔，不改盾牌。iOS 没有抢屏能力，预警的唯一去向是让家长看见。
        DiagLog.record("monitor", "阈值预警 event=\(event.rawValue) activity=\(activity.rawValue)",
                       level: .warn)
        StateStore.mutate { $0.recordFault("阈值预警：\(event.rawValue)") }
    }

    /// 每个回调都从快照**重算全量**再幂等写盾，不做增量改字段。
    /// App Group 没有跨进程锁，增量写丢一次就永久歪了；全量重算丢一次下次能纠正。
    private func recompute(reason: String) {
        var decision: GateDecision = .cannotEnforce(.stateCorrupt)
        var didWriteShield = false
        let result = StateStore.mutate { state in
            decision = GatePolicy.decide(state, nowMs: state.nowMs())
            didWriteShield = ShieldWriter.reconcile(decision: decision, state: &state)
        }
        guard case .ok(let state) = result else {
            var why = "非 .ok 分支"
            if case .corrupt(let detail) = result { why = detail }
            DiagLog.record("monitor",
                           "重算中止，状态读不出来：" + why + "（触发方 " + reason + "）",
                           level: .error, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
            return
        }

        DarwinSignal.post()

        // 这一行是整本日志里最常被翻的一行：回调来了、决策是什么、盘上的盾牌是什么、
        // 这一次有没有真的动过 ManagedSettingsStore。四个字段缺一个，
        // 「时间到了没拦住」就有一个查不下去的角度。
        DiagLog.record("monitor",
                       reason + " → " + decision.diagToken
                           + " playedMs=" + String(state.ledger.playedMs)
                           + " ruleVersion=" + String(state.rule?.version ?? -1)
                           + " shieldApplied=" + String(state.shieldApplied)
                           + " wrote=" + String(didWriteShield)
                           + " bound=" + String(state.deviceBound)
                           + " token=" + (state.deviceToken == nil ? "none" : "have"),
                       level: didWriteShield ? .warn : .info,
                       nowMs: state.nowMs())

        // 「盾牌真的盖上了」这一句只有这个进程说得出。主 App 看不到前台，
        // ManagedSettingsStore 又不在它进程里跑，库里如果没有这一档，
        // 「时间到了孩子还能玩」就永远查不下去。
        // 只在 reconcile 真的动了 store 时报：反复重算不该刷家长的告警列表。
        if didWriteShield {
            report(kind: decision.wantsShield ? .shieldApplied : .shieldCleared,
                   detail: "\(decision.shieldEvidence)（\(reason)）",
                   occurredAtMs: state.nowMs(),
                   token: state.deviceToken)
        }

        // 落不了盾这件事必须让家长知道，等价于 Android 的「无障碍掉了」告警。
        if case .cannotEnforce(let why) = decision {
            report(kind: .gateInterrupted,
                   detail: "iOS 闸门无法执行：\(why.rawValue)（\(reason)）",
                   occurredAtMs: state.nowMs(),
                   token: state.deviceToken)
        }
    }

    /// 事件先落 Outbox，再顺手 fire-and-forget 一发。
    ///
    /// 两条都发不是浪费：进程可能在回调返回后立刻结束，只靠 fire-and-forget 会静默丢；
    /// 只落盘则家长最晚要等到主 App 下次前台才看得见。服务端按 event_id 去重，
    /// 所以重复送达只会算成 duplicated。
    private func report(kind: Quizgate_GateEventKind, detail: String,
                        occurredAtMs: Int64, token: String?) {
        var event = Quizgate_GateEvent()
        event.eventID = UUID().uuidString
        event.kind = kind
        event.occurredAtMs = occurredAtMs
        event.detail = detail
        var request = Quizgate_GateEventReportRequest()
        request.events = [event]
        guard let payload = try? request.serializedData() else { return }
        if let defaults = AppGroup.defaults {
            OutboxStore.enqueue(
                PendingReport(path: "gate-event", payload: payload,
                              createdAtMs: occurredAtMs),
                to: defaults
            )
        }
        guard let token, let base = AppGroup.apiBase else { return }
        QuizGateAPI(base: base).fireAndForget("gate-event", token: token, request: request)
    }
}