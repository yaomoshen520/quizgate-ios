import Foundation

public enum CannotEnforceReason: String, Equatable, Sendable, CaseIterable {
    case notAuthorized
    case noSelection
    case noRule
    case stateCorrupt
}

public enum ShieldReason: String, Equatable, Sendable, CaseIterable {
    case dailyLimitReached
    case thresholdReached
}

public enum AllowReason: String, Equatable, Sendable, CaseIterable {
    case disabledByParent
    case quizPassed
    case underThreshold
}

/// 三态而不是「拦/放」两态。
///
/// Android 侧失效时可以 fail-closed（抢屏抢不到就卡住不放行）。iOS 侧不行：
/// 授权被拒或没选 App 时，我们**物理上没有能力落盾**，这时说「allow」是在撒谎，
/// 说「shield」又做不到。所以单列一档 cannotEnforce，它的唯一正确去向是
/// 上报成闸门事件让家长看见 —— 和 Android 的「无障碍掉了」告警是同一档东西。
public enum GateDecision: Equatable, Sendable {
    case shield(ShieldReason)
    case allow(AllowReason)
    case cannotEnforce(CannotEnforceReason)

    public var wantsShield: Bool {
        if case .shield = self { return true }
        return false
    }

    /// 落盾/解盾那两档 gate-event 的一句话正文。
    /// 主 App 和 Monitor 扩展共用这一份措辞：家长后台要按字符串判「现在是拦着还是放着」，
    /// 两处各写一套就成了同一个状态两种说法。
    public var shieldEvidence: String {
        switch self {
        case .shield(.dailyLimitReached): return "今日时长已用完，盾牌已落下"
        case .shield(.thresholdReached): return "连续使用已到阈值，盾牌已落下"
        case .allow(.quizPassed): return "答对了题，盾牌已解除"
        case .allow(.disabledByParent): return "家长关掉闸门，盾牌已解除"
        case .allow(.underThreshold): return "还没到阈值，盾牌已解除"
        case .cannotEnforce(let why): return "闸门无法执行：\(why.rawValue)"
        }
    }

    /// 日志里用的紧凑形态（`shield.thresholdReached` / `cannotEnforce.noRule`）。
    /// 和 shieldEvidence 刻意分成两份：那一份是给人读的句子，这一份要能被 grep 归类，
    /// 混用同一句中文的话，「远程翻日志」就变成了按措辞匹配。
    public var diagToken: String {
        switch self {
        case .shield(let reason): return "shield.\(reason.rawValue)"
        case .allow(let reason): return "allow.\(reason.rawValue)"
        case .cannotEnforce(let reason): return "cannotEnforce.\(reason.rawValue)"
        }
    }
}

/// 纯函数策略引擎。不 import FamilyControls / ManagedSettings / DeviceActivity，
/// 不读盘、不发网络、不碰单例 —— 所以能在模拟器和 CI 上真跑单测。
///
/// 语义逐条对齐 Android SessionTracker，两处刻意不同并已注明原因。
public enum GatePolicy {

    /// - Parameter nowMs: 已换算到服务器时间基准的当前时刻（SharedState.nowMs()）。
    ///   显式传入而不是内部取 Date()，否则「孩子改系统时钟」这条没法测。
    public static func decide(_ state: SharedState, nowMs: Int64) -> GateDecision {
        guard let authorization = state.authorization, authorization.isApproved else {
            return .cannotEnforce(.notAuthorized)
        }
        guard let selection = state.selectionData, !selection.isEmpty else {
            return .cannotEnforce(.noSelection)
        }
        guard let rule = state.rule else {
            return .cannotEnforce(.noRule)
        }
        // 对齐 Android SpikeSettings.cycleRule()：thresholdMinutes <= 0 视为不跟随服务端规则。
        guard rule.enabled, rule.thresholdMinutes > 0 else {
            return .allow(.disabledByParent)
        }
        if let until = state.ledger.unlockUntilMs, nowMs < until {
            return .allow(.quizPassed)
        }
        // 日限额走系统那个横跨全天的活动（quizgate.day）报回来的标记，
        // 不再用 ledger.playedMs 推：playedMs 每轮清零，拿它当「今天一共玩了多久」
        // 是错的——答对一次就把当天的累计抹平了，日限额永远到不了。
        // 刻意的语义（沿用改之前的顺序，不是这次新定的）：日限额已在 unlock 之后判，
        // 所以「今天用完了」仍然允许刚答对的那一道题买回一个阈值长度的窗口。
        if rule.dailyLimitMinutes > 0, state.dailyLimitReachedOnDay == Self.dayIndex(nowMs) {
            return .shield(.dailyLimitReached)
        }
        let played = state.ledger.playedMs
        if played >= Int64(rule.thresholdMinutes) * 60_000 {
            return .shield(.thresholdReached)
        }
        return .allow(.underThreshold)
    }

    /// 把毫秒切成「天」的序号。UTC 日界，和事件去重键用同一粒度，
    /// 免得两处一个按 UTC 一个按本地时区，日限额在凌晨那几小时时灵时不灵。
    public static func dayIndex(_ ms: Int64) -> Int64 { ms / 86_400_000 }

    /// 答对之后开新一轮。对齐 Android：答对是**本轮计时清零**，不是「告诉你答案」。
    ///
    /// 这里同时做两件事：账本清零 + 给一个放行窗口。窗口不是新的产品语义，
    /// 而是防竞态 —— 清零之后要 stop→重配→start 监控，系统重新计数有延迟，
    /// 没有这个窗口就会在重启监控的一瞬间按旧计数再落一次盾。
    ///
    /// 刻意**不实现 graceMinutes**：Android 的宽限是「离开监管 App 超过 N 分钟就清零」，
    /// 前提是知道前台是哪个 App。iOS 没有这个能力，所以这一项在 iOS 上无对应物，
    /// 不是漏做。家长后台那一项对 iOS 设备应当置灰。
    public static func startNewCycle(afterCorrectAt nowMs: Int64, rule: RuleState) -> Ledger {
        var ledger = Ledger()
        ledger.unlockUntilMs = nowMs + Int64(max(rule.thresholdMinutes, 0)) * 60_000
        return ledger
    }

    /// 阈值回调会重复来（同一个事件 id 可能触发多次），也会漏来。
    /// 重复靠这个去重；漏来靠主 App 前台时定时拉后端重算兜底，不指望补发。
    public static func shouldProcess(eventId: String, state: SharedState) -> Bool {
        !eventId.isEmpty && !state.hasProcessed(eventId)
    }

    /// 把聚合阈值事件换算成账本时长。
    ///
    /// DeviceActivity 只告诉我们「这组 App 在这个区间里用满了 N 分钟」，
    /// 不告诉我们当前累计了多少。所以只能按事件阶梯累加，**精度上限就是阈值粒度**。
    /// 这也是为什么 iOS 首页的倒计时必须标成「约」，不能像 Android 那样显示到秒。
    public static func accumulate(_ state: SharedState, thresholdMinutes: Int, eventId: String) -> SharedState {
        var next = state
        guard shouldProcess(eventId: eventId, state: state), thresholdMinutes > 0 else { return next }
        next.markEventProcessed(eventId)
        next.ledger.playedMs += Int64(thresholdMinutes) * 60_000
        return next
    }

    /// 幂等落盾判定：只有「想要的」和「已落的」不一致时才需要写 ManagedSettingsStore。
    /// 每个回调都重算全量再走这里，所以丢一次更新也能被下一次纠正。
    public static func needsShieldWrite(decision: GateDecision, currentlyApplied: Bool) -> Bool {
        decision.wantsShield != currentlyApplied
    }
}