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
/// 抬到 15 还有个副作用：本文件按 step 铺事件阶梯，而 Monitor 侧按
/// `rule.thresholdMinutes` 累加时长。两者不一致时累计时长会按比例歪掉
/// （阈值 1 分钟、step 15 = 每 15 分钟只记 1 分钟）。floor 取 1 之后两者恒等。
final class MonitoringController {

    static let activityName = DeviceActivityName("quizgate.daily")
    /// 阈值 0 或负数在上一层已经当「规则没开」处理了，这里只防除零式的空阶梯。
    static let minimumStepMinutes = 1
    /// 事件数量自限。同时监控的活动总数上限是 20，这里只占 1 个活动，
    /// 但事件也不该无限铺，16 个阶梯足够覆盖 4 小时。
    static let maxEvents = 16

    private let center = DeviceActivityCenter()

    enum ConfigureResult: Equatable {
        case started(stepMinutes: Int, eventCount: Int)
        case noSelection
        case ruleDisabled
    }

    @discardableResult
    func reconfigure(rule: RuleState?, selectionData: Data?) throws -> ConfigureResult {
        // 先停。不停就改阈值会被系统拒，而且拒的方式不总是抛错。
        center.stopMonitoring([Self.activityName])

        guard let rule, rule.enabled, rule.thresholdMinutes > 0 else { return .ruleDisabled }
        guard let selection = SelectionArchive.decode(selectionData),
              !SelectionArchive.isEmpty(selection) else { return .noSelection }

        let step = max(rule.thresholdMinutes, Self.minimumStepMinutes)
        let cap = rule.dailyLimitMinutes > 0 ? rule.dailyLimitMinutes : step * 4

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )

        // 阶梯式事件：每 step 分钟一个。Monitor 侧每收到一个就累加 step，
        // 这样累计时长才对得上。事件名带序号，去重靠「活动名|事件名|天」。
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        var minutes = step
        var index = 0
        while minutes <= cap && index < Self.maxEvents {
            events[DeviceActivityEvent.Name("step-\(index)")] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(minute: minutes)
            )
            minutes += step
            index += 1
        }

        try center.startMonitoring(Self.activityName, during: schedule, events: events)
        return .started(stepMinutes: step, eventCount: events.count)
    }

    func stop() {
        center.stopMonitoring([Self.activityName])
    }
}