import Foundation

/// 孩子此刻在干嘛。编号与 proto 的 `PlayState` 一一对应（quizgate.proto:97），
/// 名字刻意不叫 `PlayState`：生成物 `Kit/Sources/Generated/` 里已经有 `Quizgate_PlayState`，
/// 两个同名类型在一个模块里会让每处引用都要写全名，而写全名的地方正是最容易漏改的地方。
public enum AvatarPlayState: String, Equatable, Sendable, CaseIterable {
    case quiz
    case pendingParent
    case warning
    case playing
    case paused
    case idle

    public var proto: Quizgate_PlayState {
        switch self {
        case .quiz: return .quiz
        case .pendingParent: return .pendingParent
        case .warning: return .warning
        case .playing: return .playing
        case .paused: return .paused
        case .idle: return .idle
        }
    }

    /// 随心跳上报给家长的那句话。Android 那一份是 `SessionTracker.gameState`，
    /// 文案必须逐字相同——家长后台同一列里混着两台设备的上报，措辞不一样就成了两个功能。
    public var gameStateText: String {
        switch self {
        case .quiz: return "答题中"
        case .pendingParent: return "等待家长审批，可继续玩"
        case .warning: return "倒计时"
        case .playing: return "游戏中"
        case .paused: return "已暂停，返回后继续"
        case .idle: return "未开始"
        }
    }
}

/// iOS 侧的档位判定。
///
/// **六档里有两档在 iOS 恒不可达，这是能力边界不是漏做**：
/// - `pendingParent`：iOS 没有"申请延长、等家长批"这一格（那是无障碍浮窗上的按钮）。
/// - `paused`：Android 那一档的意思是"一轮还开着，但孩子已经不在被监管的那个 App 前台"。
///   iOS 读不到别家 App 是不是在前台（DeviceActivity 只回"用满了 N 分钟"这种聚合事件），
///   所以分不出"离开了"和"还在玩"。硬要报 paused 就是编一个 iOS 不知道的事实。
///
/// 判定次序刻意与 Android 那条 when 链**差一格**：Android 是 QUIZ → PENDING_PARENT →
/// WARNING → PLAYING(在游戏前台) → PAUSED(一轮还开着) → IDLE；iOS 把"放行窗口"并入 PLAYING，
/// 因为答对之后那一段时间孩子确实可以继续用，报成 paused 会让家长看到"已暂停"而孩子正在玩。
public enum AvatarPlayPolicy {

    /// - Parameters:
    ///   - questionOnScreen: 题是不是正摆在屏幕上（主 App 那个 sheet）。
    ///   - nowMs: 已换算到服务器基准的当前时刻（`SharedState.nowMs()`）。
    public static func decide(_ state: SharedState,
                              decision: GateDecision,
                              questionOnScreen: Bool,
                              nowMs: Int64) -> AvatarPlayState {
        // 落盾 = 该答题了。iOS 没有 Android 那个"题已发出、浮窗在等"的中间态：
        // 掐网与那一声提示是同一秒发生的，孩子面对的就已经是"去答题"。
        if questionOnScreen || decision.wantsShield { return .quiz }

        // 闸门没在岗时不许报"在玩"：那是我们不知道，不是孩子没玩。
        guard decision == .allow(.underThreshold) || decision == .allow(.quizPassed) else { return .idle }
        guard state.monitoringStartedAtMs != nil else { return .idle }

        if isWarning(state: state, nowMs: nowMs) { return .warning }
        return .playing
    }

    /// 快到了。门槛用的是**服务端自己那个 `warning_seconds`**，不是我们另编一个数：
    /// 家长在后台调了这一格，两端要一起变，否则同一份规则在两台机上提醒的时机不同。
    ///
    /// 精度上限要说清楚：iOS 的 `playedMs` 是按 DeviceActivity 的阈值事件阶梯累加的
    /// （见 GatePolicy.accumulate），所以"剩余时间"是跳变的，这一档只在跨过某一格时亮，
    /// 不像 Android 那样能逐秒逼近。这不是 bug，是 iOS 拿不到逐秒读数。
    static func isWarning(state: SharedState, nowMs: Int64) -> Bool {
        guard let rule = state.rule, rule.enabled else { return false }
        let seconds = rule.warningSeconds ?? 0
        guard seconds > 0 else { return false }
        let remaining = Int64(rule.thresholdMinutes) * 60_000 - state.ledger.playedMs
        return remaining > 0 && remaining <= Int64(seconds) * 1_000
    }
}
