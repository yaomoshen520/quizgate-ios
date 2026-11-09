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
        // 事件按「活动名 + 事件名 + 天」去重。schedule 是每日重复的，
        // 天粒度足以区分两轮，又不需要额外往共享状态里塞区间起点。
        let result = StateStore.mutate { state in
            let day = state.nowMs() / 86_400_000
            let eventId = "\(activity.rawValue)|\(event.rawValue)|\(day)"
            let step = state.rule?.thresholdMinutes ?? 0
            state = GatePolicy.accumulate(state, thresholdMinutes: step, eventId: eventId)
        }
        guard case .ok = result else { return }
        recompute(reason: "eventDidReachThreshold(\(event.rawValue))")
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name,
                                                 activity: DeviceActivityName) {
        // 预警只记一笔，不改盾牌。iOS 没有抢屏能力，预警的唯一去向是让家长看见。
        StateStore.mutate { $0.recordFault("阈值预警：\(event.rawValue)") }
    }

    /// 每个回调都从快照**重算全量**再幂等写盾，不做增量改字段。
    /// App Group 没有跨进程锁，增量写丢一次就永久歪了；全量重算丢一次下次能纠正。
    private func recompute(reason: String) {
        var decision: GateDecision = .cannotEnforce(.stateCorrupt)
        let result = StateStore.mutate { state in
            decision = GatePolicy.decide(state, nowMs: state.nowMs())
            ShieldWriter.reconcile(decision: decision, state: &state)
        }
        guard case .ok(let state) = result else { return }

        DarwinSignal.post()

        // 落不了盾这件事必须让家长知道，等价于 Android 的「无障碍掉了」告警。
        // 这条走 fire-and-forget：发不出去就算了，主 App 的 Outbox 会补。
        if case .cannotEnforce(let why) = decision, let token = state.deviceToken {
            var event = Quizgate_GateEvent()
            event.eventID = UUID().uuidString
            event.kind = .gateInterrupted
            event.occurredAtMs = state.nowMs()
            event.detail = "iOS 闸门无法执行：\(why.rawValue)（\(reason)）"
            var request = Quizgate_GateEventReportRequest()
            request.events = [event]
            guard let base = AppGroup.apiBase else { return }
            QuizGateAPI(base: base).fireAndForget("gate-event", token: token, request: request)
        }
    }
}