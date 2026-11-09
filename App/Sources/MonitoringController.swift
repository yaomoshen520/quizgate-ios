import DeviceActivity
import FamilyControls
import Foundation
import QuizGateKit

/// 配置系统级用量监控。
///
/// 一条硬约束（这个是真的）：监控进行中**不能改阈值**，必须 stop → 重配 → start。
/// 所以每次答对开新一轮都要走全流程。
///
/// 旧注释在这里写过「最小监控区间 15 分钟，来自 SDK 签名不是猜的」——那句没有出处。
/// 2026-11-09 把苹果 DeviceActivity 的符号页全扫过一遍（DeviceActivitySchedule、
/// DeviceActivityEvent 及其 threshold/init、Center.startMonitoring、Monitor 回调），
/// 没有任何一处提到分钟级下限；社区代码里 `warningTime: DateComponents(minute: 1)`
/// 是常见写法。真正的约束是**精度不是下限**：苹果自己的帮助文档说到的用量可能
/// 偏差 5-10 分钟，所以阈值设得再小，落盾时刻也会晚几分钟，这件事在 UI 上讲清楚。
///
/// 同日第二处更正（原来这里的阶梯是错的）：阈值事件是「单调跨过」语义，同一个活动名
/// 同一个事件名一天只来一次，而且系统盯的是**区间起点之后**的累计用量。以前每轮都用
/// 固定的 quizgate.daily + 00:00–23:59 每日区间，于是答对之后：我们的账本清零了，
/// 系统那边既没有新事件名可跨过、区间也没重开 —— 当天第一次答对之后就永不落盾。
/// 现在一轮一个新活动名 + 从现在开始的一次性区间，日限额单独用一个横跨全天的活动守。
final class MonitoringController {

    /// 当日总时长活动：固定名、每日重复，答对不重置。
    static let dayActivity = DeviceActivityName(MonitoringNames.dayActivity)
    static let dayLimitEvent = DeviceActivityEvent.Name(MonitoringNames.dayLimitEvent)

    /// 阈值 0 或负数在上一层已经当「规则没开」处理了，这里只防除零式的空阶梯。
    static let minimumStepMinutes = 1
    /// 一轮之内的阶梯档数。落盾只需要第 1 档，后面的档只是让首页倒计时能动起来，
    /// 所以这个数不再需要覆盖 dailyLimitMinutes（那是 dayActivity 的活），
    /// 也再也不会出现「阶梯烧完 → 当天永不落盾」——下一轮换名字重新开始。
    static let maxEvents = 16

    /// 区间起点往后再让 5 秒：intervalStart 落在过去的行为苹果没有承诺过，
    /// 不给它一个明确的未来时刻，就不赌它。
    static let intervalLeadSeconds = 5

    private let center = DeviceActivityCenter()

    enum ConfigureResult: Equatable {
        /// armed=false 表示 startMonitoring 没报错，但系统活动列表里查不到这一轮。
        ///
        /// 这一档必须存在而不是当成功：侧载（巨魔）装的包如果 entitlement 没被系统
        /// 认下来，苹果这边观测到的表现正是「调用全绿、事件永不到来」。不在这儿把它
        /// 挑出来，现场只剩「闸门看起来配好了却从来不拦」加家长后台一片安静。
        ///
        /// 刻意不抛错：抛错调用方就拿不到活动名，状态里没留下这一轮的记录，
        /// 下一次前台又会重配一次 = 又一遍计数器归零，误判本身就成了绕过口子。
        case started(stepMinutes: Int, eventCount: Int, activity: String, armed: Bool)
        case noSelection
        case ruleDisabled
    }

    /// - Parameter previousActivity: 上一轮的活动名，来自 SharedState.monitoringActivity。
    ///   不 stop 掉它，每答对一次就永久占掉「同时最多 20 个活动」里的一格。
    /// - Parameter nowMs: 服务器基准时刻，只用来生成活动名（唯一键），不参与判定。
    @discardableResult
    func reconfigure(rule: RuleState?, selectionData: Data?,
                     previousActivity: String?, nowMs: Int64) throws -> ConfigureResult {
        // 先停。不停就改阈值会被系统拒，而且拒的方式不总是抛错。
        var stopping: [DeviceActivityName] = [Self.dayActivity]
        if let previousActivity { stopping.append(DeviceActivityName(previousActivity)) }
        center.stopMonitoring(stopping)

        guard let rule, rule.enabled, rule.thresholdMinutes > 0 else { return .ruleDisabled }
        guard let selection = SelectionArchive.decode(selectionData),
              !SelectionArchive.isEmpty(selection) else { return .noSelection }

        let step = max(rule.thresholdMinutes, Self.minimumStepMinutes)
        let start = Date().addingTimeInterval(TimeInterval(Self.intervalLeadSeconds))
        let activity = DeviceActivityName(MonitoringNames.cycleActivity(startedAtMs: nowMs))

        // 本轮：从现在开始、到今晚结束的一次性区间。repeats=false 是有意的——
        // 重复的每日区间正是旧版那个「答对之后系统那边永不重开」的根因。
        let cycleSchedule = DeviceActivitySchedule(
            intervalStart: Calendar.current.dateComponents([.hour, .minute, .second], from: start),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: false
        )

        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for index in 0..<Self.maxEvents {
            events[DeviceActivityEvent.Name(MonitoringNames.cycleEvent(index: index))] =
                DeviceActivityEvent(
                    applications: selection.applicationTokens,
                    categories: selection.categoryTokens,
                    webDomains: selection.webDomainTokens,
                    threshold: DateComponents(minute: step * (index + 1))
                )
        }
        try center.startMonitoring(activity, during: cycleSchedule, events: events)

        // 日限额：另一条活动，跨整天、每日重复。它失败不该带走本轮监控，
        // 所以 try? —— 本轮拦不住是闸门掉了，日限额拦不住只是多玩了一会儿，两档严重程度。
        if rule.dailyLimitMinutes > 0 {
            let daySchedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true
            )
            try? center.startMonitoring(Self.dayActivity, during: daySchedule, events: [
                Self.dayLimitEvent: DeviceActivityEvent(
                    applications: selection.applicationTokens,
                    categories: selection.categoryTokens,
                    webDomains: selection.webDomainTokens,
                    threshold: DateComponents(minute: rule.dailyLimitMinutes)
                )
            ])
        }

        // 回读验一次。这是「静默失败」唯一能被看见的地方，别省。
        let armed = center.getAllActiveActivities().contains(activity)
        return .started(stepMinutes: step, eventCount: events.count,
                        activity: activity.rawValue, armed: armed)
    }
}
